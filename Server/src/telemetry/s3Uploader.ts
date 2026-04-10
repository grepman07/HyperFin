import fs from 'fs';
import path from 'path';
import zlib from 'zlib';
import { promisify } from 'util';
import { S3Client, PutObjectCommand } from '@aws-sdk/client-s3';

const gzip = promisify(zlib.gzip);

/**
 * Uploads local JSONL telemetry files to an S3-compatible bucket on a schedule.
 *
 * Vendor-neutral: works with Cloudflare R2 (default), Backblaze B2, AWS S3,
 * DigitalOcean Spaces — anything that speaks the S3 API. Set `endpoint` to
 * point at the provider's regional URL; leave it unset for AWS S3.
 *
 * Design:
 * - Reads every `telemetry-YYYY-MM-DD.jsonl` in the base dir each tick.
 * - Gzips each file and PUTs to `{prefix}telemetry-YYYY-MM-DD.jsonl.gz`.
 * - Uses deterministic keys so the hourly tick OVERWRITES the previous
 *   upload of the same day's file — last write wins. At day rollover the
 *   file becomes immutable and the next tick uploads the final version.
 * - Preserves local JSONL as the hot write path (no deletion on upload).
 *   Purges via `JsonlTelemetrySink.deleteByInstallId` will be picked up on
 *   the next hourly tick and re-uploaded with the deleted rows absent.
 */
export interface S3UploaderConfig {
  bucket: string;
  region: string; // R2 expects "auto"; AWS/Spaces expect the real region
  accessKeyId: string;
  secretAccessKey: string;
  endpoint?: string; // e.g. "https://<account>.r2.cloudflarestorage.com" for R2
  prefix?: string; // e.g. "prod/telemetry/" — trailing slash optional
  baseDir: string; // local JSONL directory
}

export class TelemetryS3Uploader {
  private client: S3Client;
  private prefix: string;
  private baseDir: string;
  private bucket: string;
  private intervalHandle: NodeJS.Timeout | null = null;
  private inFlight = false;

  constructor(config: S3UploaderConfig) {
    this.client = new S3Client({
      region: config.region,
      endpoint: config.endpoint,
      // R2 / B2 / Spaces require path-style addressing; AWS S3 accepts both.
      // Forcing path-style works everywhere.
      forcePathStyle: !!config.endpoint,
      credentials: {
        accessKeyId: config.accessKeyId,
        secretAccessKey: config.secretAccessKey,
      },
    });
    this.bucket = config.bucket;
    this.baseDir = config.baseDir;
    // Normalize prefix: no leading slash, trailing slash present
    const rawPrefix = config.prefix ?? '';
    this.prefix = rawPrefix.replace(/^\/+/, '').replace(/\/?$/, '/');
    if (this.prefix === '/') this.prefix = '';
  }

  /**
   * Upload every JSONL file currently in the base dir. Safe to call
   * concurrently — a guard drops overlapping invocations.
   */
  async uploadAll(): Promise<{ uploaded: number; skipped: number; failed: number }> {
    if (this.inFlight) {
      return { uploaded: 0, skipped: 0, failed: 0 };
    }
    this.inFlight = true;
    const result = { uploaded: 0, skipped: 0, failed: 0 };
    try {
      const files = await fs.promises.readdir(this.baseDir).catch(() => [] as string[]);
      const targets = files.filter(
        (f) => f.startsWith('telemetry-') && f.endsWith('.jsonl')
      );
      for (const file of targets) {
        try {
          const fullPath = path.join(this.baseDir, file);
          const stat = await fs.promises.stat(fullPath);
          if (stat.size === 0) {
            result.skipped += 1;
            continue;
          }
          const raw = await fs.promises.readFile(fullPath);
          const gzipped = await gzip(raw);
          const key = `${this.prefix}${file}.gz`;
          await this.client.send(
            new PutObjectCommand({
              Bucket: this.bucket,
              Key: key,
              Body: gzipped,
              ContentType: 'application/x-ndjson',
              ContentEncoding: 'gzip',
              // Both R2 and modern S3 buckets encrypt at rest by default —
              // no per-object SSE header needed (and R2 rejects unknown
              // SSE values, so omitting it keeps the call portable).
              Metadata: {
                'source-file': file,
                'row-bytes': String(raw.byteLength),
                'uploaded-at': new Date().toISOString(),
              },
            })
          );
          result.uploaded += 1;
        } catch (err) {
          result.failed += 1;
          console.error(
            `[s3-uploader] failed to upload ${file}:`,
            (err as Error).message
          );
        }
      }
    } finally {
      this.inFlight = false;
    }
    return result;
  }

  /**
   * Start the hourly tick. Fires an immediate upload on start so a freshly
   * booted container flushes anything left in the ephemeral filesystem
   * before the next scheduled run.
   */
  start(intervalMs = 60 * 60 * 1000): void {
    if (this.intervalHandle) return;
    // Kick off an initial upload (non-blocking)
    this.uploadAll()
      .then((r) =>
        console.log(
          `[s3-uploader] initial upload: ${r.uploaded} uploaded, ${r.skipped} skipped, ${r.failed} failed`
        )
      )
      .catch((err) => console.error('[s3-uploader] initial upload error:', err));

    this.intervalHandle = setInterval(() => {
      this.uploadAll()
        .then((r) => {
          if (r.uploaded || r.failed) {
            console.log(
              `[s3-uploader] tick: ${r.uploaded} uploaded, ${r.skipped} skipped, ${r.failed} failed`
            );
          }
        })
        .catch((err) => console.error('[s3-uploader] tick error:', err));
    }, intervalMs);
    // Do not keep the event loop alive solely for this timer —
    // the HTTP server already does.
    this.intervalHandle.unref?.();
    console.log(
      `[s3-uploader] started — interval=${intervalMs}ms bucket=${this.bucket} prefix=${this.prefix || '(root)'}`
    );
  }

  stop(): void {
    if (this.intervalHandle) {
      clearInterval(this.intervalHandle);
      this.intervalHandle = null;
    }
  }

  /**
   * Run one final upload pass and stop the timer. Intended for SIGTERM.
   */
  async shutdown(): Promise<void> {
    this.stop();
    try {
      const r = await this.uploadAll();
      console.log(
        `[s3-uploader] shutdown flush: ${r.uploaded} uploaded, ${r.skipped} skipped, ${r.failed} failed`
      );
    } catch (err) {
      console.error('[s3-uploader] shutdown flush error:', err);
    }
  }
}

/**
 * Build an uploader from environment variables, or return null if any
 * required variable is missing. Logs a warning on missing config so
 * deployments surface misconfiguration loudly.
 *
 * Required env vars (all S3-API providers):
 *   S3_BUCKET, S3_ACCESS_KEY_ID, S3_SECRET_ACCESS_KEY
 * Optional:
 *   S3_REGION   — defaults to "auto" (correct for Cloudflare R2)
 *   S3_ENDPOINT — required for R2 / B2 / Spaces; omit for AWS S3
 *   S3_PREFIX   — object key prefix, e.g. "prod/telemetry/"
 */
export function uploaderFromEnv(baseDir: string): TelemetryS3Uploader | null {
  const bucket = process.env.S3_BUCKET;
  const region = process.env.S3_REGION || 'auto';
  const accessKeyId = process.env.S3_ACCESS_KEY_ID;
  const secretAccessKey = process.env.S3_SECRET_ACCESS_KEY;
  const endpoint = process.env.S3_ENDPOINT;
  const prefix = process.env.S3_PREFIX;

  if (!bucket || !accessKeyId || !secretAccessKey) {
    console.warn(
      '[s3-uploader] disabled — set S3_BUCKET, S3_ACCESS_KEY_ID, S3_SECRET_ACCESS_KEY to enable'
    );
    return null;
  }

  return new TelemetryS3Uploader({
    bucket,
    region,
    accessKeyId,
    secretAccessKey,
    endpoint,
    prefix,
    baseDir,
  });
}
