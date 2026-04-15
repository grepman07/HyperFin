import path from 'path';
import express from 'express';
import cors from 'cors';
import helmet from 'helmet';
import dotenv from 'dotenv';
import rateLimit from 'express-rate-limit';
import { authRouter } from './routes/auth';
import { plaidRouter } from './routes/plaid';
import { investmentsRouter } from './routes/investments';
import { liabilitiesRouter } from './routes/liabilities';
import { configRouter } from './routes/config';
import { webhookRouter } from './routes/webhooks';
import { telemetryRouter } from './routes/telemetry';
import { cloudChatRouter } from './routes/cloudChat';
import { adminRouter } from './routes/admin';
import { uploaderFromEnv } from './telemetry/s3Uploader';
import { initializeDatabase, shutdownDatabase } from './services/database';
import { requireAuth } from './middleware/auth';

dotenv.config();

const app = express();
const PORT = process.env.PORT || 3000;

// Security middleware
app.use(helmet());
app.use(cors({ origin: process.env.ALLOWED_ORIGINS?.split(',') || '*' }));

// Trust DigitalOcean's load balancer so req.ip returns the real client IP
app.set('trust proxy', 1);

// 256kb limit (default is 100kb, which is tight for assembled chat prompts
// that include tool result JSON + conversation history).
app.use(express.json({ limit: '256kb' }));

// Rate limit on auth endpoints — 20 req/min per IP
const authLimiter = rateLimit({
  windowMs: 60_000,
  max: 20,
  standardHeaders: true,
  legacyHeaders: false,
  message: { error: 'Too many auth requests. Try again in a minute.' },
});

// Health check (unauthenticated)
app.get('/health', (_req, res) => {
  res.json({ status: 'ok', service: 'hyperfin-server', version: '1.0.0' });
});

// API routes
app.use('/v1/auth', authLimiter, authRouter);          // Unauthenticated (login/register)
app.use('/v1/plaid', requireAuth, plaidRouter);         // Authenticated — JWT required
app.use('/v1/investments', requireAuth, investmentsRouter); // Authenticated — Plaid investments
app.use('/v1/liabilities', requireAuth, liabilitiesRouter); // Authenticated — Plaid liabilities
app.use('/v1/config', configRouter);                    // Unauthenticated — public config
app.use('/v1/plaid/webhooks', webhookRouter);           // Plaid-signed (webhook verification)
app.use('/v1/telemetry', telemetryRouter);              // Install-ID based (no JWT)
app.use('/v1/chat', cloudChatRouter);                   // Install-ID + rate limit
app.use('/v1/admin', adminRouter);                      // Admin bearer token

// Error handler
app.use((err: Error, _req: express.Request, res: express.Response, _next: express.NextFunction) => {
  console.error('Unhandled error:', err.message);
  res.status(500).json({ error: 'Internal server error' });
});

// S3 telemetry uploader — durable storage for training data.
const TELEMETRY_DIR =
  process.env.TELEMETRY_DIR || path.join(process.cwd(), 'telemetry-data');
const s3Uploader = uploaderFromEnv(TELEMETRY_DIR);
s3Uploader?.start();

// ---------------------------------------------------------------------------
// Startup — initialise database then listen
// ---------------------------------------------------------------------------

async function start() {
  // Initialise PostgreSQL schema (idempotent — safe to re-run on every deploy)
  if (process.env.DATABASE_URL) {
    try {
      await initializeDatabase();
    } catch (err) {
      console.error('[startup] database init failed — continuing without DB:', err);
      // Don't crash the server — auth and Plaid routes will fail gracefully
      // with 500s, but health check, config, telemetry, and chat still work.
    }
  } else {
    console.warn('[startup] DATABASE_URL not set — auth and Plaid features disabled');
  }

  const server = app.listen(PORT, () => {
    console.log(`HyperFin server running on port ${PORT}`);

    // Startup diagnostics — makes sandbox setup debugging easier
    const plaidMode = (process.env.PLAID_CLIENT_ID && process.env.PLAID_SECRET)
      ? `sandbox (real credentials, env=${process.env.PLAID_ENV || 'sandbox'})`
      : 'mock (no PLAID_CLIENT_ID / PLAID_SECRET)';
    const dbUrl = process.env.DATABASE_URL
      ? process.env.DATABASE_URL.replace(/:([^@]+)@/, ':***@')
      : '(not set)';
    const encKey = process.env.PLAID_TOKEN_ENCRYPTION_KEY ? '✓ configured' : '✗ missing';
    const webhookUrl = process.env.SERVER_URL || 'http://localhost:3000';

    console.log(`[startup] Plaid mode:       ${plaidMode}`);
    console.log(`[startup] Database:         ${dbUrl}`);
    console.log(`[startup] Token encryption: ${encKey}`);
    console.log(`[startup] Webhook URL:      ${webhookUrl}/v1/plaid/webhooks`);
    console.log(`[startup] Node env:         ${process.env.NODE_ENV || 'development'}`);
  });

  // Graceful shutdown
  async function shutdown(signal: string) {
    console.log(`[shutdown] received ${signal}`);
    try {
      await s3Uploader?.shutdown();
    } catch (err) {
      console.error('[shutdown] s3 flush error:', err);
    }
    try {
      await shutdownDatabase();
    } catch (err) {
      console.error('[shutdown] database close error:', err);
    }
    server.close(() => {
      console.log('[shutdown] http server closed, exiting');
      process.exit(0);
    });
    // Hard exit safety net if close() hangs
    setTimeout(() => process.exit(0), 8000).unref();
  }

  process.on('SIGTERM', () => void shutdown('SIGTERM'));
  process.on('SIGINT', () => void shutdown('SIGINT'));
}

start().catch((err) => {
  console.error('[startup] fatal error:', err);
  process.exit(1);
});

export default app;
