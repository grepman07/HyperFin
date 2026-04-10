import path from 'path';
import express from 'express';
import cors from 'cors';
import helmet from 'helmet';
import dotenv from 'dotenv';
import { authRouter } from './routes/auth';
import { plaidRouter } from './routes/plaid';
import { configRouter } from './routes/config';
import { webhookRouter } from './routes/webhooks';
import { telemetryRouter } from './routes/telemetry';
import { cloudChatRouter } from './routes/cloudChat';
import { adminRouter } from './routes/admin';
import { uploaderFromEnv } from './telemetry/s3Uploader';

dotenv.config();

const app = express();
const PORT = process.env.PORT || 3000;

// Security middleware
app.use(helmet());
app.use(cors({ origin: process.env.ALLOWED_ORIGINS?.split(',') || '*' }));
// 256kb limit (default is 100kb, which is tight for assembled chat prompts
// that include tool result JSON + conversation history).
app.use(express.json({ limit: '256kb' }));

// Health check
app.get('/health', (_req, res) => {
  res.json({ status: 'ok', service: 'hyperfin-server', version: '1.0.0' });
});

// API routes
app.use('/v1/auth', authRouter);
app.use('/v1/plaid', plaidRouter);
app.use('/v1/config', configRouter);
app.use('/v1/plaid/webhooks', webhookRouter);
app.use('/v1/telemetry', telemetryRouter);
app.use('/v1/chat', cloudChatRouter);
app.use('/v1/admin', adminRouter);

// Error handler
app.use((err: Error, _req: express.Request, res: express.Response, _next: express.NextFunction) => {
  console.error('Unhandled error:', err.message);
  res.status(500).json({ error: 'Internal server error' });
});

// S3 telemetry uploader — durable storage for training data.
// The container filesystem is ephemeral on DO App Platform, so this hourly
// tick is the only thing standing between a redeploy and lost rows. Returns
// null and warns if AWS_* env vars are missing — useful for local dev.
const TELEMETRY_DIR =
  process.env.TELEMETRY_DIR || path.join(process.cwd(), 'telemetry-data');
const s3Uploader = uploaderFromEnv(TELEMETRY_DIR);
s3Uploader?.start();

const server = app.listen(PORT, () => {
  console.log(`HyperFin server running on port ${PORT}`);
  console.log('This server handles ONLY: auth, Plaid relay, config, webhooks');
  console.log('Zero financial data processing. Zero AI inference.');
});

// Graceful shutdown — flush the JSONL buffer to S3 before the container
// disappears. DO App Platform sends SIGTERM and waits ~10s before SIGKILL,
// which is enough headroom for a single PUT per file in normal operation.
async function shutdown(signal: string) {
  console.log(`[shutdown] received ${signal}, flushing telemetry to S3...`);
  try {
    await s3Uploader?.shutdown();
  } catch (err) {
    console.error('[shutdown] s3 flush error:', err);
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

export default app;
