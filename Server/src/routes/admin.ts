import { Router, Request, Response, NextFunction } from 'express';
import fs from 'fs';
import path from 'path';
import zlib from 'zlib';
import { z } from 'zod';
import {
  S3Client,
  ListObjectsV2Command,
  GetObjectCommand,
} from '@aws-sdk/client-s3';

/**
 * Admin endpoints for downloading anonymized training data.
 *
 * Auth: Bearer token from `ADMIN_BEARER_TOKEN` env var. The token is
 * compared with `timingSafeEqual` to avoid byte-by-byte timing leaks.
 *
 * Endpoints:
 *   GET /v1/admin/telemetry/export?source=local|s3&from=YYYY-MM-DD&to=YYYY-MM-DD
 *     Streams concatenated JSONL (gzipped) for the requested date range.
 *     - source=local (default): reads the live JSONL files in TELEMETRY_DIR.
 *       Fast, includes any rows added since the last S3 upload, but limited
 *       to whatever the current container has on disk.
 *     - source=s3: reads the S3 bucket. Authoritative full history. Slower.
 *     - from/to: optional ISO dates (YYYY-MM-DD), inclusive on both ends.
 *
 *   GET /v1/admin/telemetry/files?source=local|s3
 *     Lists available files (filename + size + last modified).
 */

const querySchema = z.object({
  source: z.enum(['local', 's3']).default('local'),
  from: z
    .string()
    .regex(/^\d{4}-\d{2}-\d{2}$/)
    .optional(),
  to: z
    .string()
    .regex(/^\d{4}-\d{2}-\d{2}$/)
    .optional(),
});

function timingSafeStringEqual(a: string, b: string): boolean {
  // crypto.timingSafeEqual requires equal-length buffers; pad to the longer
  // length so callers can't probe length via timing differences.
  const max = Math.max(a.length, b.length);
  const aBuf = Buffer.alloc(max, 0);
  const bBuf = Buffer.alloc(max, 0);
  aBuf.write(a);
  bBuf.write(b);
  // Lazy require so the function works without importing at module top.
  // eslint-disable-next-line @typescript-eslint/no-var-requires
  const { timingSafeEqual } = require('crypto');
  return a.length === b.length && timingSafeEqual(aBuf, bBuf);
}

function authMiddleware(req: Request, res: Response, next: NextFunction): void {
  const expected = process.env.ADMIN_BEARER_TOKEN;
  if (!expected) {
    res.status(503).json({ error: 'admin endpoints disabled (no ADMIN_BEARER_TOKEN)' });
    return;
  }
  const header = req.headers.authorization || '';
  const match = header.match(/^Bearer\s+(.+)$/);
  if (!match || !timingSafeStringEqual(match[1], expected)) {
    res.status(401).json({ error: 'unauthorized' });
    return;
  }
  next();
}

/**
 * Filter a `telemetry-YYYY-MM-DD(.jsonl|.jsonl.gz)` filename by an inclusive
 * date range. Returns true if the date in the filename falls within range
 * (or if no range is specified).
 */
function withinRange(
  filename: string,
  from: string | undefined,
  to: string | undefined
): boolean {
  const m = filename.match(/telemetry-(\d{4}-\d{2}-\d{2})\.jsonl(\.gz)?$/);
  if (!m) return false;
  const date = m[1];
  if (from && date < from) return false;
  if (to && date > to) return false;
  return true;
}

function buildS3Client(): S3Client | null {
  const region = process.env.S3_REGION || 'auto';
  const accessKeyId = process.env.S3_ACCESS_KEY_ID;
  const secretAccessKey = process.env.S3_SECRET_ACCESS_KEY;
  const endpoint = process.env.S3_ENDPOINT;
  if (!accessKeyId || !secretAccessKey) return null;
  return new S3Client({
    region,
    endpoint,
    forcePathStyle: !!endpoint,
    credentials: { accessKeyId, secretAccessKey },
  });
}

function s3Prefix(): string {
  const raw = process.env.S3_PREFIX ?? '';
  const normalized = raw.replace(/^\/+/, '').replace(/\/?$/, '/');
  return normalized === '/' ? '' : normalized;
}

export function buildAdminRouter(): Router {
  const router = Router();

  router.use(authMiddleware);

  // List available files in either source.
  router.get('/telemetry/files', async (req: Request, res: Response) => {
    const parsed = querySchema.safeParse(req.query);
    if (!parsed.success) {
      return res.status(400).json({ error: 'invalid query', details: parsed.error.flatten() });
    }
    const { source } = parsed.data;

    if (source === 'local') {
      const baseDir =
        process.env.TELEMETRY_DIR || path.join(process.cwd(), 'telemetry-data');
      try {
        const files = await fs.promises.readdir(baseDir).catch(() => [] as string[]);
        const targets = files.filter((f) => f.startsWith('telemetry-') && f.endsWith('.jsonl'));
        const detailed = await Promise.all(
          targets.map(async (f) => {
            const stat = await fs.promises.stat(path.join(baseDir, f));
            return { name: f, size: stat.size, lastModified: stat.mtime.toISOString() };
          })
        );
        return res.json({ source, baseDir, files: detailed });
      } catch (err) {
        return res.status(500).json({ error: 'failed to list local files', message: (err as Error).message });
      }
    }

    // s3
    const client = buildS3Client();
    const bucket = process.env.S3_BUCKET;
    if (!client || !bucket) {
      return res.status(503).json({ error: 's3 not configured' });
    }
    try {
      const result = await client.send(
        new ListObjectsV2Command({
          Bucket: bucket,
          Prefix: s3Prefix(),
        })
      );
      const files = (result.Contents ?? []).map((obj) => ({
        name: obj.Key ?? '',
        size: obj.Size ?? 0,
        lastModified: obj.LastModified?.toISOString() ?? '',
      }));
      return res.json({ source, bucket, prefix: s3Prefix(), files });
    } catch (err) {
      return res.status(500).json({ error: 'failed to list s3 objects', message: (err as Error).message });
    }
  });

  // Stream concatenated JSONL (gzipped) for the requested range.
  router.get('/telemetry/export', async (req: Request, res: Response) => {
    const parsed = querySchema.safeParse(req.query);
    if (!parsed.success) {
      return res.status(400).json({ error: 'invalid query', details: parsed.error.flatten() });
    }
    const { source, from, to } = parsed.data;

    res.setHeader('Content-Type', 'application/x-ndjson');
    res.setHeader('Content-Encoding', 'gzip');
    const filename = `telemetry-export-${from || 'start'}-to-${to || 'now'}.jsonl.gz`;
    res.setHeader('Content-Disposition', `attachment; filename="${filename}"`);

    const gz = zlib.createGzip();
    gz.pipe(res);

    try {
      if (source === 'local') {
        const baseDir =
          process.env.TELEMETRY_DIR || path.join(process.cwd(), 'telemetry-data');
        const files = (await fs.promises.readdir(baseDir).catch(() => [] as string[]))
          .filter((f) => withinRange(f, from, to))
          .sort();
        for (const file of files) {
          const content = await fs.promises.readFile(path.join(baseDir, file));
          gz.write(content);
          if (!content.toString('utf8').endsWith('\n')) gz.write('\n');
        }
      } else {
        // s3
        const client = buildS3Client();
        const bucket = process.env.S3_BUCKET;
        if (!client || !bucket) {
          gz.end();
          return;
        }
        const list = await client.send(
          new ListObjectsV2Command({ Bucket: bucket, Prefix: s3Prefix() })
        );
        const keys = (list.Contents ?? [])
          .map((o) => o.Key ?? '')
          .filter((k) => {
            const base = k.split('/').pop() ?? '';
            return withinRange(base, from, to);
          })
          .sort();
        for (const key of keys) {
          const obj = await client.send(new GetObjectCommand({ Bucket: bucket, Key: key }));
          if (!obj.Body) continue;
          const bytes = Buffer.from(await obj.Body.transformToByteArray());
          // Stored objects are gzipped — gunzip first, then re-gzip into
          // the response stream so the client gets a single gzip frame.
          let plain: Buffer;
          try {
            plain = zlib.gunzipSync(bytes);
          } catch {
            plain = bytes; // tolerate non-gzipped historical objects
          }
          gz.write(plain);
          if (!plain.toString('utf8').endsWith('\n')) gz.write('\n');
        }
      }
      gz.end();
    } catch (err) {
      console.error('[admin/export] error:', err);
      // Headers already sent; we can only end the stream.
      gz.end();
    }
  });

  return router;
}

export const adminRouter = buildAdminRouter();
