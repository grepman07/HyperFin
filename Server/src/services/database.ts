import { Pool, QueryResult } from 'pg';

// ---------------------------------------------------------------------------
// Connection pool — lazily created on first `query()` or `initializeDatabase()`.
// SSL is required by default (DigitalOcean Managed PostgreSQL enforces it).
// ---------------------------------------------------------------------------

let pool: Pool | null = null;

export function getPool(): Pool {
  if (!pool) {
    const rawConnectionString = process.env.DATABASE_URL;
    if (!rawConnectionString) {
      throw new Error('DATABASE_URL environment variable is not set');
    }
    // DO's Dev/Managed Postgres uses self-signed certs in the chain. We strip
    // any `sslmode=...` query param so pg-connection-string doesn't build a
    // conflicting ssl config, then pass an explicit `ssl` object that disables
    // CA verification. Connections stay encrypted (TLS still required) —
    // only the certificate-chain check is relaxed, which is appropriate for
    // a DO-internal DB link.
    const connectionString = rawConnectionString.replace(/[?&]sslmode=[^&]*/g, '');
    // Only enable SSL when running in production or when the connection string
    // explicitly requests it. Local Postgres (via docker-compose) doesn't
    // speak SSL and will reject the connection if we force it.
    const isProduction = process.env.NODE_ENV === 'production';
    const urlRequestsSSL = rawConnectionString.includes('sslmode=require');
    const sslConfig = (isProduction || urlRequestsSSL)
      ? { rejectUnauthorized: false }
      : false;
    pool = new Pool({
      connectionString,
      max: 10,
      idleTimeoutMillis: 30_000,
      connectionTimeoutMillis: 5_000,
      ssl: sslConfig,
      // Postgres 16 locked down the `public` schema — non-superusers can't
      // CREATE there. We put everything in an app-owned `hyperfin` schema
      // instead (created below in SCHEMA_SQL as the first statement). Setting
      // search_path on every new connection means all unqualified table refs
      // resolve to our schema without needing to qualify in SQL.
      options: '-c search_path=hyperfin,public',
    });
    pool.on('error', (err) => {
      console.error('[database] unexpected pool error:', err.message);
    });
  }
  return pool;
}

/**
 * Run a parameterised query against the pool.
 *
 * All SQL in the app goes through here so we have a single choke point for
 * logging, metrics, and error normalisation.
 */
export async function query(text: string, params?: unknown[]): Promise<QueryResult> {
  const p = getPool();
  return p.query(text, params);
}

// ---------------------------------------------------------------------------
// Schema bootstrap — runs on every cold start. All statements are idempotent
// (`CREATE TABLE IF NOT EXISTS`, `CREATE INDEX IF NOT EXISTS`) so they're safe
// to re-run after restarts, redeployments, or horizontal scale-out.
// ---------------------------------------------------------------------------

const SCHEMA_SQL = `
-- Own schema -- Postgres 16 revoked default CREATE on public for non-owners,
-- so we create a schema the app DB user owns. search_path is set at pool
-- connect time (see getPool) so all unqualified references land here.
CREATE SCHEMA IF NOT EXISTS hyperfin AUTHORIZATION CURRENT_USER;
SET search_path TO hyperfin, public;

-- Users -------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS users (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  email VARCHAR(255) UNIQUE NOT NULL,
  password_hash VARCHAR(255) NOT NULL,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Plaid items — access tokens encrypted with PLAID_TOKEN_ENCRYPTION_KEY ---
CREATE TABLE IF NOT EXISTS plaid_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  access_token_enc TEXT NOT NULL,
  item_id VARCHAR(255) NOT NULL,
  institution_name VARCHAR(255),
  cursor TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_plaid_items_user ON plaid_items(user_id);
CREATE INDEX IF NOT EXISTS idx_plaid_items_item ON plaid_items(item_id);

-- Device tokens (for push notifications) ----------------------------------
CREATE TABLE IF NOT EXISTS device_tokens (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  apns_token VARCHAR(255) NOT NULL,
  platform VARCHAR(10) DEFAULT 'ios',
  created_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_device_tokens_user ON device_tokens(user_id);

-- Securities master — one row per unique security (stock/fund/etc). --------
-- Shared across all users/items; security_id is global in Plaid's model.
CREATE TABLE IF NOT EXISTS securities (
  security_id TEXT PRIMARY KEY,
  ticker_symbol TEXT,
  name TEXT,
  type TEXT,
  iso_currency_code TEXT,
  close_price NUMERIC,
  close_price_as_of DATE,
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Holdings — current position per (account, security). Refreshed on each
-- investmentsHoldingsGet; UNIQUE(account_id, security_id) lets us upsert.
CREATE TABLE IF NOT EXISTS holdings (
  id SERIAL PRIMARY KEY,
  item_id TEXT NOT NULL,
  account_id TEXT NOT NULL,
  security_id TEXT NOT NULL REFERENCES securities(security_id),
  quantity NUMERIC NOT NULL,
  institution_price NUMERIC,
  institution_value NUMERIC,
  cost_basis NUMERIC,
  iso_currency_code TEXT,
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(account_id, security_id)
);
CREATE INDEX IF NOT EXISTS idx_holdings_item ON holdings(item_id);

-- Investment transactions — buys, sells, dividends, fees, cash moves. Unlike
-- /transactions/sync this API is date-range paginated; we track the last
-- synced date on plaid_items (see ALTER below) instead of a cursor.
CREATE TABLE IF NOT EXISTS investment_transactions (
  investment_transaction_id TEXT PRIMARY KEY,
  item_id TEXT NOT NULL,
  account_id TEXT NOT NULL,
  security_id TEXT REFERENCES securities(security_id),
  date DATE NOT NULL,
  name TEXT,
  type TEXT,
  subtype TEXT,
  quantity NUMERIC,
  price NUMERIC,
  fees NUMERIC,
  amount NUMERIC,
  iso_currency_code TEXT
);
CREATE INDEX IF NOT EXISTS idx_invtx_item_date ON investment_transactions(item_id, date DESC);

-- Liabilities — credit cards, mortgages, student loans. Shapes diverge too
-- much between kinds to normalise, so we keep a "kind" discriminator plus a
-- jsonb blob. We never filter inside the payload server-side.
CREATE TABLE IF NOT EXISTS liabilities (
  id SERIAL PRIMARY KEY,
  item_id TEXT NOT NULL,
  account_id TEXT NOT NULL,
  kind TEXT NOT NULL CHECK (kind IN ('credit','mortgage','student')),
  data JSONB NOT NULL,
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(account_id, kind)
);
CREATE INDEX IF NOT EXISTS idx_liabilities_item ON liabilities(item_id);

-- Track last successful investment-txn sync window end per item so we can
-- do incremental pulls (date-range paginated, not cursor based).
ALTER TABLE plaid_items ADD COLUMN IF NOT EXISTS investments_last_synced_date DATE;

-- Audit log — immutable append-only ----------------------------------------
CREATE TABLE IF NOT EXISTS audit_log (
  id BIGSERIAL PRIMARY KEY,
  ts TIMESTAMPTZ DEFAULT NOW(),
  user_id UUID,
  action VARCHAR(100) NOT NULL,
  resource_type VARCHAR(50),
  resource_id VARCHAR(255),
  ip_addr INET,
  detail JSONB
);
CREATE INDEX IF NOT EXISTS idx_audit_ts ON audit_log(ts);
CREATE INDEX IF NOT EXISTS idx_audit_user ON audit_log(user_id);
`;

export async function initializeDatabase(): Promise<void> {
  try {
    await query(SCHEMA_SQL);
    console.log('[database] schema initialised');
  } catch (err) {
    console.error('[database] schema init failed:', err);
    throw err;
  }
}

/** Graceful pool shutdown (called from SIGTERM handler). */
export async function shutdownDatabase(): Promise<void> {
  if (pool) {
    await pool.end();
    pool = null;
    console.log('[database] pool closed');
  }
}
