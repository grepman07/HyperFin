import fs from 'fs';
import os from 'os';
import path from 'path';
import zlib from 'zlib';
import { TelemetryS3Uploader } from '../src/telemetry/s3Uploader';

/**
 * In-memory mock of the S3Client.send surface used by TelemetryS3Uploader.
 * The uploader only calls `send(new PutObjectCommand(...))`, so we intercept
 * the send method and capture the commands.
 */
type CapturedPut = {
  Bucket: string;
  Key: string;
  Body: Buffer;
  ContentEncoding?: string;
  ContentType?: string;
  Metadata?: Record<string, string>;
};

function patchUploader(
  uploader: TelemetryS3Uploader,
  captured: CapturedPut[],
  options: { throwOn?: string } = {}
): void {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  (uploader as any).client = {
    send: async (cmd: { input: CapturedPut }) => {
      const input = cmd.input;
      if (options.throwOn && input.Key.includes(options.throwOn)) {
        throw new Error('s3 put failed');
      }
      captured.push(input);
      return {};
    },
  };
}

describe('TelemetryS3Uploader', () => {
  let baseDir: string;

  beforeEach(() => {
    baseDir = fs.mkdtempSync(path.join(os.tmpdir(), 's3-uploader-test-'));
  });

  afterEach(() => {
    fs.rmSync(baseDir, { recursive: true, force: true });
  });

  test('uploadAll gzips and puts each jsonl file with deterministic key', async () => {
    const fileA = 'telemetry-2026-04-08.jsonl';
    const fileB = 'telemetry-2026-04-09.jsonl';
    const contentA = '{"id":"a"}\n{"id":"b"}\n';
    const contentB = '{"id":"c"}\n';
    fs.writeFileSync(path.join(baseDir, fileA), contentA);
    fs.writeFileSync(path.join(baseDir, fileB), contentB);

    const uploader = new TelemetryS3Uploader({
      bucket: 'test-bucket',
      region: 'us-east-1',
      accessKeyId: 'AK',
      secretAccessKey: 'SK',
      prefix: 'prod/telemetry',
      baseDir,
    });
    const captured: CapturedPut[] = [];
    patchUploader(uploader, captured);

    const result = await uploader.uploadAll();
    expect(result).toEqual({ uploaded: 2, skipped: 0, failed: 0 });
    expect(captured.length).toBe(2);

    const keys = captured.map((c) => c.Key).sort();
    expect(keys).toEqual([
      'prod/telemetry/telemetry-2026-04-08.jsonl.gz',
      'prod/telemetry/telemetry-2026-04-09.jsonl.gz',
    ]);

    for (const put of captured) {
      expect(put.Bucket).toBe('test-bucket');
      expect(put.ContentEncoding).toBe('gzip');
      // Body should be valid gzip round-tripping back to the source content
      const plain = zlib.gunzipSync(put.Body).toString('utf8');
      if (put.Key.endsWith('08.jsonl.gz')) expect(plain).toBe(contentA);
      if (put.Key.endsWith('09.jsonl.gz')) expect(plain).toBe(contentB);
    }
  });

  test('uploadAll skips zero-byte files', async () => {
    fs.writeFileSync(path.join(baseDir, 'telemetry-2026-04-08.jsonl'), '');
    fs.writeFileSync(path.join(baseDir, 'telemetry-2026-04-09.jsonl'), '{"id":"x"}\n');

    const uploader = new TelemetryS3Uploader({
      bucket: 'b',
      region: 'us-east-1',
      accessKeyId: 'AK',
      secretAccessKey: 'SK',
      baseDir,
    });
    const captured: CapturedPut[] = [];
    patchUploader(uploader, captured);

    const result = await uploader.uploadAll();
    expect(result).toEqual({ uploaded: 1, skipped: 1, failed: 0 });
    expect(captured.length).toBe(1);
  });

  test('uploadAll ignores non-telemetry files', async () => {
    fs.writeFileSync(path.join(baseDir, 'telemetry-2026-04-08.jsonl'), '{"id":"a"}\n');
    fs.writeFileSync(path.join(baseDir, 'README.md'), '# hi');
    fs.writeFileSync(path.join(baseDir, 'other.jsonl'), '{"x":1}');

    const uploader = new TelemetryS3Uploader({
      bucket: 'b',
      region: 'us-east-1',
      accessKeyId: 'AK',
      secretAccessKey: 'SK',
      baseDir,
    });
    const captured: CapturedPut[] = [];
    patchUploader(uploader, captured);

    const result = await uploader.uploadAll();
    expect(result.uploaded).toBe(1);
    expect(captured[0].Key).toBe('telemetry-2026-04-08.jsonl.gz');
  });

  test('uploadAll counts failures without aborting the loop', async () => {
    fs.writeFileSync(path.join(baseDir, 'telemetry-2026-04-08.jsonl'), '{"id":"a"}\n');
    fs.writeFileSync(path.join(baseDir, 'telemetry-2026-04-09.jsonl'), '{"id":"b"}\n');

    const uploader = new TelemetryS3Uploader({
      bucket: 'b',
      region: 'us-east-1',
      accessKeyId: 'AK',
      secretAccessKey: 'SK',
      baseDir,
    });
    const captured: CapturedPut[] = [];
    patchUploader(uploader, captured, { throwOn: '2026-04-08' });

    const result = await uploader.uploadAll();
    expect(result.uploaded).toBe(1);
    expect(result.failed).toBe(1);
    expect(captured.length).toBe(1);
    expect(captured[0].Key).toContain('2026-04-09');
  });

  test('uploadAll dedupes concurrent invocations via inFlight guard', async () => {
    fs.writeFileSync(path.join(baseDir, 'telemetry-2026-04-08.jsonl'), '{"id":"a"}\n');

    const uploader = new TelemetryS3Uploader({
      bucket: 'b',
      region: 'us-east-1',
      accessKeyId: 'AK',
      secretAccessKey: 'SK',
      baseDir,
    });
    const captured: CapturedPut[] = [];
    patchUploader(uploader, captured);

    const [first, second] = await Promise.all([
      uploader.uploadAll(),
      uploader.uploadAll(),
    ]);
    // Exactly one of the two calls should have done work; the other returns zeros.
    const totalUploaded = first.uploaded + second.uploaded;
    expect(totalUploaded).toBe(1);
    expect(captured.length).toBe(1);
  });

  test('empty prefix produces root-level keys', async () => {
    fs.writeFileSync(path.join(baseDir, 'telemetry-2026-04-08.jsonl'), '{"id":"a"}\n');
    const uploader = new TelemetryS3Uploader({
      bucket: 'b',
      region: 'us-east-1',
      accessKeyId: 'AK',
      secretAccessKey: 'SK',
      baseDir,
      // prefix omitted
    });
    const captured: CapturedPut[] = [];
    patchUploader(uploader, captured);
    await uploader.uploadAll();
    expect(captured[0].Key).toBe('telemetry-2026-04-08.jsonl.gz');
  });

  test('custom endpoint (e.g. R2) constructs an S3 client with that endpoint', async () => {
    // Verify the constructor accepts the R2-style endpoint without throwing.
    // We can't easily inspect S3Client internals, but we can confirm the
    // uploader is fully usable after construction with an endpoint.
    fs.writeFileSync(path.join(baseDir, 'telemetry-2026-04-08.jsonl'), '{"id":"a"}\n');
    const uploader = new TelemetryS3Uploader({
      bucket: 'r2-bucket',
      region: 'auto',
      accessKeyId: 'AK',
      secretAccessKey: 'SK',
      endpoint: 'https://abc123.r2.cloudflarestorage.com',
      baseDir,
    });
    const captured: CapturedPut[] = [];
    patchUploader(uploader, captured);
    const result = await uploader.uploadAll();
    expect(result.uploaded).toBe(1);
    expect(captured[0].Bucket).toBe('r2-bucket');
  });
});
