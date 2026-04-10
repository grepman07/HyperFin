# Training Data Export Pipeline

Opt-in anonymized telemetry rows from the HyperFin iOS client land in the
server's local JSONL files first, then get mirrored to **Cloudflare R2**
on an hourly tick so the training corpus survives container redeploys
(DigitalOcean App Platform's container filesystem is ephemeral).

R2 was picked because the free tier (10 GB storage, 1M writes/month, zero
egress) covers HyperFin's expected scale indefinitely. The implementation
uses the standard S3 API, so swapping to Backblaze B2, AWS S3, or DO Spaces
later is just an env-var change — no code rewrite.

## Data flow

```
iOS client
  └─ POST /v1/telemetry/events
       └─ JsonlTelemetrySink.write()
            └─ writes telemetry-YYYY-MM-DD.jsonl  (hot path — fast, no network)

every hour (TelemetryS3Uploader.start):
  └─ read every telemetry-*.jsonl in TELEMETRY_DIR
       └─ gzip each file
            └─ PUT s3://{S3_BUCKET}/{S3_PREFIX}telemetry-YYYY-MM-DD.jsonl.gz
                 └─ overwrites yesterday's upload of the same day's file

SIGTERM on redeploy:
  └─ flush one final upload before the process exits

admin download:
  GET /v1/admin/telemetry/export?source=local|s3&from=YYYY-MM-DD&to=YYYY-MM-DD
       Authorization: Bearer ${ADMIN_BEARER_TOKEN}
       └─ streams concatenated JSONL (gzipped)
```

## Properties

- **Durable storage**: once the first hourly tick runs, data survives
  container churn. Worst-case loss window is the current hour plus anything
  between the last tick and a non-graceful kill.
- **Opt-in only**: the iOS client only sends telemetry when the user flips
  the "Share anonymized training data" toggle. The server never synthesizes
  data.
- **Anonymized in the client**: names, emails, and account numbers are
  stripped by `Anonymizer.anonymize` on-device before the event ever leaves
  the phone. R2 stores exactly what the server received.
- **Forever retention**: no lifecycle rules are configured. Add an R2 object
  lifecycle rule later if you want to expire after N days.
- **Right to delete**: when a user opts out, the client calls
  `POST /v1/telemetry/delete` with their installId. The server rewrites
  every local JSONL file without those rows. The next hourly tick uploads
  the purged version to R2, which overwrites the previous day's key.

## Cloudflare R2 setup (one-time)

### 1. Create a Cloudflare account

If you don't already have one, sign up at https://dash.cloudflare.com/sign-up.
The free tier requires email verification but **no credit card**.

### 2. Enable R2 and create a bucket

1. In the Cloudflare dashboard, go to **R2** in the left sidebar.
2. Click **Create bucket**.
3. Bucket name: `hyperfin-training-data` (or whatever you like — remember it
   for the env var).
4. Location: leave as **Automatic** (R2 picks the closest region).
5. Click **Create bucket**.

> R2 free tier limits: 10 GB storage, 1M Class A operations (writes) per
> month, 10M Class B operations (reads) per month, **unlimited egress**.
> HyperFin's expected usage is well under all of these.

### 3. Find your account-specific R2 endpoint

In **R2 → Overview**, you'll see an **Account ID** (e.g.
`abc123def4567890abcdef1234567890`). Your S3 endpoint is:

```
https://<account-id>.r2.cloudflarestorage.com
```

Save this URL — it goes in `S3_ENDPOINT`.

### 4. Create an R2 API token

1. **R2 → Manage R2 API Tokens → Create API token**.
2. Token name: `hyperfin-server`.
3. Permissions: **Object Read & Write**.
4. Specify bucket: select **Apply to specific buckets** and choose
   `hyperfin-training-data`. This scopes the token to a single bucket so a
   leak only affects that one resource.
5. TTL: leave as **Forever** (or set a rotation schedule if you prefer).
6. Click **Create API Token**.

The next page shows three values **once and only once**:
- **Access Key ID** → goes in `S3_ACCESS_KEY_ID`
- **Secret Access Key** → goes in `S3_SECRET_ACCESS_KEY`
- **Endpoint** (the same URL you saw in step 3) — sanity-check it matches.

Copy them now. Cloudflare will not show the secret again — if you lose it,
just delete the token and create a new one.

### 5. Inject secrets into the DO App

`doctl apps update` only takes a full `--spec` file — there is no per-env
flag. The cleanest path is the Digital Ocean dashboard, because it stores
secret values encrypted and you never write them to a file on disk.

**Dashboard path (recommended):**

1. Go to https://cloud.digitalocean.com/apps → click `hyperfin-server`.
2. **Settings** tab → scroll to **App-Level Environment Variables** → **Edit**.
3. For each required secret, click **Add Variable** (or edit the existing
   placeholder if you already pushed `.do/app.yaml`):
   - `S3_BUCKET` → `hyperfin-training-data`
   - `S3_ACCESS_KEY_ID` → your R2 access key
   - `S3_SECRET_ACCESS_KEY` → your R2 secret (check **Encrypt**)
   - `S3_ENDPOINT` → `https://<account-id>.r2.cloudflarestorage.com`
   - `ADMIN_BEARER_TOKEN` → output of `openssl rand -hex 32` (check **Encrypt**)
4. Click **Save**. DO will redeploy automatically.

> `S3_REGION=auto` and `S3_PREFIX=prod/telemetry/` are already baked into
> `.do/app.yaml` as plain values, so they'll appear automatically after the
> first `doctl apps update <APP_ID> --spec .do/app.yaml`.

**CLI path (if you insist on avoiding the dashboard):**

```bash
# Pull the live spec, edit it in a tmp file, push it back.
doctl apps spec get <APP_ID> > /tmp/spec.yaml
# Open /tmp/spec.yaml in your editor, find each SECRET-typed env, and add
# `value: "..."` under it with the actual secret.
doctl apps update <APP_ID> --spec /tmp/spec.yaml
rm /tmp/spec.yaml   # don't leave secrets on disk
```

> Save the `ADMIN_BEARER_TOKEN` value in your password manager — it's not
> retrievable from DO once set, and you'll need it every time you call the
> admin download endpoints.

### 6. Deploy and verify

```bash
doctl apps create-deployment <APP_ID>
doctl apps list-deployments <APP_ID>
```

After the deploy, check the runtime logs for the uploader's startup line:

```
[s3-uploader] started — interval=3600000ms bucket=hyperfin-training-data prefix=prod/telemetry/
[s3-uploader] initial upload: N uploaded, M skipped, 0 failed
```

If you see instead:

```
[s3-uploader] disabled — set S3_BUCKET, S3_ACCESS_KEY_ID, S3_SECRET_ACCESS_KEY to enable
```

then at least one of those three env vars isn't set.

## Admin download usage

Export all local rows (fast — whatever the current container has on disk):

```bash
curl -H "Authorization: Bearer $ADMIN_BEARER_TOKEN" \
  "https://api.hyperfin.app/v1/admin/telemetry/export?source=local" \
  -o training-local.jsonl.gz
gunzip training-local.jsonl.gz
```

Export all R2 history (authoritative, slower — reads every object in the
prefix):

```bash
curl -H "Authorization: Bearer $ADMIN_BEARER_TOKEN" \
  "https://api.hyperfin.app/v1/admin/telemetry/export?source=s3" \
  -o training-r2.jsonl.gz
```

> The query param is `source=s3` regardless of provider — the parameter
> means "the durable bucket" rather than naming AWS specifically.

Filter by date range (inclusive, YYYY-MM-DD):

```bash
curl -H "Authorization: Bearer $ADMIN_BEARER_TOKEN" \
  "https://api.hyperfin.app/v1/admin/telemetry/export?source=s3&from=2026-04-01&to=2026-04-30" \
  -o training-april.jsonl.gz
```

List what's available without downloading:

```bash
curl -H "Authorization: Bearer $ADMIN_BEARER_TOKEN" \
  "https://api.hyperfin.app/v1/admin/telemetry/files?source=s3" | jq
```

## Cost expectations on R2

For HyperFin's scale, **everything fits inside the free tier**:

| Resource | Free tier | HyperFin estimate (10k rows/day) | % of limit |
|---|---|---|---|
| Storage | 10 GB | ~1 GB / year | < 1% / year |
| Class A ops (writes) | 1M / mo | ~720 / mo (hourly × ~3 files × 30 days) | 0.07% |
| Class B ops (reads) | 10M / mo | < 1k for occasional admin pulls | < 0.01% |
| Egress | unlimited | unlimited downloads | n/a |

If usage somehow grows past the free tier, paid R2 is:

- **Storage**: $0.015 / GB-month (cheaper than S3's $0.023)
- **Class A ops**: $4.50 / million
- **Class B ops**: $0.36 / million
- **Egress**: still $0 — this is R2's headline feature

## Switching providers later

The same code works with any S3-compatible provider. Just change env vars
(no redeploy needed for env-only changes — DO will restart the service):

| Provider | `S3_ENDPOINT` | `S3_REGION` |
|---|---|---|
| Cloudflare R2 (default) | `https://<account>.r2.cloudflarestorage.com` | `auto` |
| Backblaze B2 | `https://s3.<region>.backblazeb2.com` | e.g. `us-west-002` |
| AWS S3 | leave unset | e.g. `us-east-1` |
| DigitalOcean Spaces | `https://<region>.digitaloceanspaces.com` | e.g. `nyc3` |

## Troubleshooting

- **Upload fails with `AccessDenied` / `403`**: the R2 token is scoped to a
  different bucket, or `S3_BUCKET` doesn't match the actual bucket name.
- **Upload fails with `NoSuchBucket`**: typo in `S3_BUCKET`, or the bucket
  was deleted.
- **Upload fails with `InvalidEndpoint` / DNS errors**: `S3_ENDPOINT` is
  malformed. Should look exactly like
  `https://<32-char-account-id>.r2.cloudflarestorage.com` — no trailing
  slash, no bucket name in the URL.
- **`[s3-uploader] tick: 0 uploaded, 0 skipped, 0 failed`**: the JSONL
  directory is empty, or no clients have opted in to telemetry yet. Check
  `TELEMETRY_DIR` and the telemetry opt-in state in the app.
- **Admin endpoint returns 503**: `ADMIN_BEARER_TOKEN` is unset. The route
  refuses to run without it so a missing env var can never become an open
  download.
- **Admin endpoint returns 401**: the bearer token in the `Authorization`
  header doesn't match `ADMIN_BEARER_TOKEN`. The comparison is constant-time
  so you can't tell whether the header was missing, wrong length, or wrong
  bytes from the response alone.
