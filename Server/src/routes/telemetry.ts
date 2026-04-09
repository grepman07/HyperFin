import { Router, Request, Response } from 'express';
import { z } from 'zod';
import { defaultTelemetrySink, TelemetrySink, TelemetryEventRow } from '../telemetry/telemetrySink';

// Schema mirrors TelemetryEvent.swift. Keeps fields tight so malformed or
// oversize payloads are rejected at the edge.
const telemetryEventSchema = z.object({
  id: z.string().uuid(),
  installId: z.string().min(1).max(64),
  sessionId: z.string().uuid(),
  timestamp: z.string().datetime({ offset: true }).or(z.string().datetime()),
  queryAnon: z.string().max(2000),
  responseAnon: z.string().max(4000),
  intent: z.enum([
    'spending',
    'budget',
    'balance',
    'trend',
    'anomaly',
    'transaction_search',
    'advice',
    'greeting',
    'unknown',
  ]),
  category: z.string().max(64).nullable().optional(),
  period: z.string().max(32).nullable().optional(),
  latencyMs: z.number().int().nonnegative().max(600000),
  modelVersion: z.string().max(64),
  appVersion: z.string().max(32),
  feedback: z.enum(['positive', 'negative']).nullable().optional(),
});

const uploadRequestSchema = z.object({
  events: z.array(telemetryEventSchema).min(1).max(100),
});

const deleteRequestSchema = z.object({
  installId: z.string().min(1).max(64),
});

const MAX_PAYLOAD_BYTES = 1024 * 1024; // 1 MB

export function buildTelemetryRouter(sink: TelemetrySink = defaultTelemetrySink): Router {
  const router = Router();

  router.post('/events', async (req: Request, res: Response) => {
    // Payload size guard — Express has already parsed the body, so check length
    const contentLength = Number(req.headers['content-length'] || 0);
    if (contentLength > MAX_PAYLOAD_BYTES) {
      return res.status(413).json({ error: 'payload too large' });
    }

    const parsed = uploadRequestSchema.safeParse(req.body);
    if (!parsed.success) {
      return res.status(400).json({ error: 'invalid payload', details: parsed.error.flatten() });
    }

    const now = new Date().toISOString();
    const rows: TelemetryEventRow[] = parsed.data.events.map((e) => ({
      id: e.id,
      installId: e.installId,
      sessionId: e.sessionId,
      timestamp: e.timestamp,
      queryAnon: e.queryAnon,
      responseAnon: e.responseAnon,
      intent: e.intent,
      category: e.category ?? null,
      period: e.period ?? null,
      latencyMs: e.latencyMs,
      modelVersion: e.modelVersion,
      appVersion: e.appVersion,
      feedback: e.feedback ?? null,
      receivedAt: now,
    }));

    try {
      await sink.write(rows);
    } catch (err) {
      console.error('telemetry sink write failed', err);
      return res.status(500).json({ error: 'sink write failed' });
    }

    return res.status(202).json({ accepted: rows.length });
  });

  router.post('/delete', async (req: Request, res: Response) => {
    const parsed = deleteRequestSchema.safeParse(req.body);
    if (!parsed.success) {
      return res.status(400).json({ error: 'invalid payload' });
    }
    try {
      const removed = await sink.deleteByInstallId(parsed.data.installId);
      return res.status(202).json({ accepted: removed });
    } catch (err) {
      console.error('telemetry sink delete failed', err);
      return res.status(500).json({ error: 'sink delete failed' });
    }
  });

  return router;
}

export const telemetryRouter = buildTelemetryRouter();
