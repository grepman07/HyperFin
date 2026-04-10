import fs from 'fs';
import os from 'os';
import path from 'path';
import express from 'express';
import request from 'supertest';

/**
 * These tests cover the local-source paths of the admin router. The S3 paths
 * are covered by the s3Uploader tests plus the integration behavior of the
 * AWS SDK. We deliberately scope this suite to local-source behavior so it
 * runs offline without any mocking gymnastics.
 */

function buildApp(telemetryDir: string, token: string): express.Express {
  process.env.TELEMETRY_DIR = telemetryDir;
  process.env.ADMIN_BEARER_TOKEN = token;
  // Import lazily so env vars are honored
  // eslint-disable-next-line @typescript-eslint/no-var-requires
  const { buildAdminRouter } = require('../src/routes/admin');
  const app = express();
  app.use('/v1/admin', buildAdminRouter());
  return app;
}

describe('admin route (local source)', () => {
  let dir: string;
  const token = 'test-token-secret';

  beforeEach(() => {
    dir = fs.mkdtempSync(path.join(os.tmpdir(), 'admin-test-'));
    // Seed a few JSONL files
    fs.writeFileSync(
      path.join(dir, 'telemetry-2026-04-07.jsonl'),
      '{"id":"a","installId":"alice"}\n'
    );
    fs.writeFileSync(
      path.join(dir, 'telemetry-2026-04-08.jsonl'),
      '{"id":"b","installId":"bob"}\n{"id":"c","installId":"carol"}\n'
    );
    fs.writeFileSync(
      path.join(dir, 'telemetry-2026-04-09.jsonl'),
      '{"id":"d","installId":"dave"}\n'
    );
  });

  afterEach(() => {
    fs.rmSync(dir, { recursive: true, force: true });
    delete process.env.TELEMETRY_DIR;
    delete process.env.ADMIN_BEARER_TOKEN;
  });

  test('rejects unauthenticated requests with 401', async () => {
    const app = buildApp(dir, token);
    const res = await request(app).get('/v1/admin/telemetry/files');
    expect(res.status).toBe(401);
  });

  test('rejects wrong-token requests with 401', async () => {
    const app = buildApp(dir, token);
    const res = await request(app)
      .get('/v1/admin/telemetry/files')
      .set('Authorization', 'Bearer wrong');
    expect(res.status).toBe(401);
  });

  test('returns 503 when ADMIN_BEARER_TOKEN not set', async () => {
    delete process.env.ADMIN_BEARER_TOKEN;
    process.env.TELEMETRY_DIR = dir;
    // eslint-disable-next-line @typescript-eslint/no-var-requires
    const { buildAdminRouter } = require('../src/routes/admin');
    const app = express();
    app.use('/v1/admin', buildAdminRouter());
    const res = await request(app)
      .get('/v1/admin/telemetry/files')
      .set('Authorization', 'Bearer anything');
    expect(res.status).toBe(503);
  });

  test('lists local files with authenticated request', async () => {
    const app = buildApp(dir, token);
    const res = await request(app)
      .get('/v1/admin/telemetry/files?source=local')
      .set('Authorization', `Bearer ${token}`);
    expect(res.status).toBe(200);
    expect(res.body.source).toBe('local');
    expect(Array.isArray(res.body.files)).toBe(true);
    expect(res.body.files.length).toBe(3);
    const names = res.body.files.map((f: { name: string }) => f.name).sort();
    expect(names).toEqual([
      'telemetry-2026-04-07.jsonl',
      'telemetry-2026-04-08.jsonl',
      'telemetry-2026-04-09.jsonl',
    ]);
  });

  test('export streams gzipped concatenated jsonl for full range', async () => {
    const app = buildApp(dir, token);
    // Supertest/superagent auto-decompresses gzip when Content-Encoding is gzip,
    // so res.text is the already-decoded body. We still verify the headers tell
    // the client a gzip frame is on the wire.
    const res = await request(app)
      .get('/v1/admin/telemetry/export?source=local')
      .set('Authorization', `Bearer ${token}`);
    expect(res.status).toBe(200);
    expect(res.headers['content-type']).toContain('application/x-ndjson');
    expect(res.headers['content-encoding']).toBe('gzip');
    const lines = res.text.split('\n').filter(Boolean);
    expect(lines.length).toBe(4);
    const ids = lines.map((l) => JSON.parse(l).id).sort();
    expect(ids).toEqual(['a', 'b', 'c', 'd']);
  });

  test('export respects from/to date range', async () => {
    const app = buildApp(dir, token);
    const res = await request(app)
      .get('/v1/admin/telemetry/export?source=local&from=2026-04-08&to=2026-04-08')
      .set('Authorization', `Bearer ${token}`);
    expect(res.status).toBe(200);
    const lines = res.text.split('\n').filter(Boolean);
    expect(lines.length).toBe(2);
    const ids = lines.map((l) => JSON.parse(l).id).sort();
    expect(ids).toEqual(['b', 'c']);
  });

  test('export rejects invalid date format with 400', async () => {
    const app = buildApp(dir, token);
    const res = await request(app)
      .get('/v1/admin/telemetry/export?from=2026-4-8')
      .set('Authorization', `Bearer ${token}`);
    expect(res.status).toBe(400);
  });
});
