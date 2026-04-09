import { Router, Request, Response } from 'express';
import { z } from 'zod';
import rateLimit from 'express-rate-limit';
import Anthropic from '@anthropic-ai/sdk';

// Schema mirrors CloudChatRequest.swift in HFIntelligence/CloudInferenceEngine.
// The prompt is the fully-assembled Qwen-format prompt (system + history +
// tool result JSON) — the server does NOT inspect or mutate it, only forwards
// it to Claude as a single user message. Max size caps the attack surface.
const bodySchema = z.object({
  prompt: z.string().min(1).max(16000),
  maxTokens: z.number().int().min(16).max(1024).default(512),
  temperature: z.number().min(0).max(1).default(0.6),
});

// 20 req/minute per install id. Prevents a compromised client from burning
// the shared Anthropic credit line.
const limiter = rateLimit({
  windowMs: 60_000,
  max: 20,
  keyGenerator: (req: Request): string => {
    const id = req.headers['x-install-id'];
    return typeof id === 'string' && id.length > 0 ? id : 'anonymous';
  },
  standardHeaders: true,
  legacyHeaders: false,
});

const ANTHROPIC_MODEL = 'claude-haiku-4-5';

export interface AnthropicStreamClient {
  stream(params: {
    model: string;
    max_tokens: number;
    temperature: number;
    messages: { role: 'user'; content: string }[];
  }): AsyncIterable<unknown>;
}

/**
 * Build the cloud chat router. Accepts an injected Anthropic-compatible
 * client so tests can swap in a mock. In production the default client uses
 * the `ANTHROPIC_API_KEY` environment variable.
 */
export function buildCloudChatRouter(client?: AnthropicStreamClient): Router {
  const router = Router();

  // Lazy-init the real client so missing env vars don't crash module import
  // (important for jest/tsx which imports everything up front).
  const resolveClient = (): AnthropicStreamClient => {
    if (client) return client;
    const apiKey = process.env.ANTHROPIC_API_KEY;
    if (!apiKey) {
      throw new Error('ANTHROPIC_API_KEY is not configured');
    }
    const anthropic = new Anthropic({ apiKey });
    return {
      stream: (params) =>
        // Cast is safe: Anthropic.messages.stream returns an AsyncIterable of
        // MessageStreamEvent, and we re-narrow per-event at the callsite.
        anthropic.messages.stream(params) as unknown as AsyncIterable<unknown>,
    };
  };

  router.post('/stream', limiter, async (req: Request, res: Response) => {
    const installId = req.headers['x-install-id'];
    if (typeof installId !== 'string' || installId.length === 0) {
      return res.status(400).json({ error: 'missing x-install-id' });
    }

    const parsed = bodySchema.safeParse(req.body);
    if (!parsed.success) {
      return res.status(400).json({ error: 'invalid payload', details: parsed.error.flatten() });
    }

    // SSE response headers — must be set BEFORE the first write.
    res.setHeader('Content-Type', 'text/event-stream');
    res.setHeader('Cache-Control', 'no-cache, no-transform');
    res.setHeader('Connection', 'keep-alive');
    res.setHeader('X-Accel-Buffering', 'no'); // disable proxy buffering
    res.flushHeaders?.();

    let streamClient: AnthropicStreamClient;
    try {
      streamClient = resolveClient();
    } catch (err) {
      console.error('[cloud-chat] client init failed', err);
      res.write(`data: ${JSON.stringify({ error: 'server misconfigured' })}\n\n`);
      return res.end();
    }

    try {
      const anthropicStream = streamClient.stream({
        model: ANTHROPIC_MODEL,
        max_tokens: parsed.data.maxTokens,
        temperature: parsed.data.temperature,
        messages: [{ role: 'user', content: parsed.data.prompt }],
      });

      for await (const event of anthropicStream as AsyncIterable<{ type: string; delta?: { type: string; text?: string } }>) {
        if (
          event.type === 'content_block_delta' &&
          event.delta?.type === 'text_delta' &&
          typeof event.delta.text === 'string' &&
          event.delta.text.length > 0
        ) {
          res.write(`data: ${JSON.stringify({ delta: event.delta.text })}\n\n`);
        }
      }

      res.write('data: [DONE]\n\n');
      res.end();
    } catch (err) {
      console.error('[cloud-chat] stream error', err);
      // We've already started the SSE stream, so write an error frame rather
      // than trying to set a new status code.
      res.write(`data: ${JSON.stringify({ error: 'upstream failed' })}\n\n`);
      res.end();
    }
  });

  return router;
}

export const cloudChatRouter = buildCloudChatRouter();
