import fs from 'fs';
import os from 'os';
import path from 'path';
import { JsonlTelemetrySink, TelemetryEventRow } from '../src/telemetry/telemetrySink';

function makeEvent(overrides: Partial<TelemetryEventRow> = {}): TelemetryEventRow {
  return {
    id: '11111111-1111-1111-1111-111111111111',
    installId: 'install-abc',
    sessionId: '22222222-2222-2222-2222-222222222222',
    timestamp: '2026-04-08T12:00:00Z',
    queryAnon: 'How much did [NAME] spend?',
    responseAnon: 'You spent $142.50',
    intent: 'spending',
    category: 'Food & Dining',
    period: 'this_month',
    latencyMs: 200,
    modelVersion: 'test-model',
    appVersion: '1.0.0',
    feedback: null,
    receivedAt: '2026-04-08T12:00:01Z',
    ...overrides,
  };
}

describe('JsonlTelemetrySink', () => {
  let dir: string;
  let sink: JsonlTelemetrySink;

  beforeEach(() => {
    dir = fs.mkdtempSync(path.join(os.tmpdir(), 'telemetry-test-'));
    sink = new JsonlTelemetrySink(dir);
  });

  afterEach(() => {
    fs.rmSync(dir, { recursive: true, force: true });
  });

  test('write appends events as JSONL lines', async () => {
    await sink.write([makeEvent({ id: 'a'.repeat(36) }), makeEvent({ id: 'b'.repeat(36) })]);
    const files = fs.readdirSync(dir).filter((f) => f.endsWith('.jsonl'));
    expect(files.length).toBe(1);
    const content = fs.readFileSync(path.join(dir, files[0]), 'utf8');
    const lines = content.trim().split('\n');
    expect(lines.length).toBe(2);
    const first = JSON.parse(lines[0]);
    expect(first.queryAnon).toBe('How much did [NAME] spend?');
  });

  test('write handles empty batch', async () => {
    await sink.write([]);
    // No file should be written, but sink dir still exists
    expect(fs.existsSync(dir)).toBe(true);
  });

  test('deleteByInstallId removes only matching rows', async () => {
    await sink.write([
      makeEvent({ id: '1'.repeat(36), installId: 'alice' }),
      makeEvent({ id: '2'.repeat(36), installId: 'bob' }),
      makeEvent({ id: '3'.repeat(36), installId: 'alice' }),
    ]);

    const removed = await sink.deleteByInstallId('alice');
    expect(removed).toBe(2);

    const files = fs.readdirSync(dir).filter((f) => f.endsWith('.jsonl'));
    const content = fs.readFileSync(path.join(dir, files[0]), 'utf8');
    const lines = content.trim().split('\n').filter(Boolean);
    expect(lines.length).toBe(1);
    expect(JSON.parse(lines[0]).installId).toBe('bob');
  });

  test('deleteByInstallId is idempotent when nothing matches', async () => {
    await sink.write([makeEvent()]);
    const removed = await sink.deleteByInstallId('nonexistent');
    expect(removed).toBe(0);
  });
});
