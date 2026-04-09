import express from 'express';
import request from 'supertest';
import { buildCloudChatRouter, AnthropicStreamClient } from '../src/routes/cloudChat';

/**
 * Fake Anthropic stream client that yields a scripted sequence of events so
 * tests don't need network access or a real API key.
 */
function makeMockClient(events: unknown[]): AnthropicStreamClient {
  return {
    stream: async function* () {
      for (const e of events) {
        yield e;
      }
    },
  };
}

function buildAppWithMock(client: AnthropicStreamClient): express.Express {
  const app = express();
  app.use(express.json({ limit: '256kb' }));
  app.use('/v1/chat', buildCloudChatRouter(client));
  return app;
}

const validBody = {
  prompt: 'Hello world',
  maxTokens: 64,
  temperature: 0.5,
};

describe('cloudChat route', () => {
  test('returns 400 when x-install-id header is missing', async () => {
    const app = buildAppWithMock(makeMockClient([]));
    const res = await request(app).post('/v1/chat/stream').send(validBody);
    expect(res.status).toBe(400);
    expect(res.body.error).toBe('missing x-install-id');
  });

  test('returns 400 on invalid payload shape', async () => {
    const app = buildAppWithMock(makeMockClient([]));
    const res = await request(app)
      .post('/v1/chat/stream')
      .set('x-install-id', 'install-abc')
      .send({ prompt: '' }); // empty prompt fails min(1)
    expect(res.status).toBe(400);
    expect(res.body.error).toBe('invalid payload');
  });

  test('returns 400 on oversized prompt', async () => {
    const app = buildAppWithMock(makeMockClient([]));
    const res = await request(app)
      .post('/v1/chat/stream')
      .set('x-install-id', 'install-abc')
      .send({ ...validBody, prompt: 'x'.repeat(16001) });
    expect(res.status).toBe(400);
  });

  test('streams SSE text_delta events and terminates with [DONE]', async () => {
    const client = makeMockClient([
      { type: 'content_block_delta', delta: { type: 'text_delta', text: 'Hello' } },
      { type: 'content_block_delta', delta: { type: 'text_delta', text: ' world' } },
      { type: 'message_stop' }, // non-text event should be ignored
    ]);
    const app = buildAppWithMock(client);
    const res = await request(app)
      .post('/v1/chat/stream')
      .set('x-install-id', 'install-abc')
      .send(validBody);

    expect(res.status).toBe(200);
    expect(res.headers['content-type']).toMatch(/text\/event-stream/);
    const text = res.text;
    expect(text).toContain('data: {"delta":"Hello"}');
    expect(text).toContain('data: {"delta":" world"}');
    expect(text).toContain('data: [DONE]');
  });

  test('writes an error frame when the upstream stream throws', async () => {
    const client: AnthropicStreamClient = {
      stream: async function* () {
        yield { type: 'content_block_delta', delta: { type: 'text_delta', text: 'partial' } };
        throw new Error('upstream blew up');
      },
    };
    const app = buildAppWithMock(client);
    const res = await request(app)
      .post('/v1/chat/stream')
      .set('x-install-id', 'install-abc')
      .send(validBody);

    // Because SSE already started, we still return 200 but the body ends with
    // an error frame rather than [DONE].
    expect(res.status).toBe(200);
    expect(res.text).toContain('data: {"delta":"partial"}');
    expect(res.text).toContain('"error":"upstream failed"');
    expect(res.text).not.toContain('[DONE]');
  });
});
