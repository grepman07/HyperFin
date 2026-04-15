import { Router, Request, Response } from 'express';
import crypto from 'crypto';
import { importJWK, jwtVerify, decodeProtectedHeader, JWK } from 'jose';
import { Configuration, PlaidApi, PlaidEnvironments } from 'plaid';
import { query } from '../services/database';
import { audit, clientIp } from '../services/auditLog';

export const webhookRouter = Router();

// ---------------------------------------------------------------------------
// Plaid Webhook Verification
//
// Plaid signs every webhook with a JWK-based JWT in the `Plaid-Verification`
// header. We verify authenticity, check replay window (5 min), and compare
// the SHA-256 of the raw body against the claim in the JWT.
//
// Reference: https://plaid.com/docs/api/webhooks/webhook-verification/
// ---------------------------------------------------------------------------

// Cache JWKs by key ID to avoid hitting Plaid on every webhook
const jwkCache = new Map<string, { jwk: JWK; fetchedAt: number }>();
const JWK_CACHE_TTL_MS = 24 * 60 * 60 * 1000; // 24 hours
const REPLAY_WINDOW_S = 300; // 5 minutes

/**
 * Build a minimal Plaid client solely for `/webhook_verification_key/get`.
 * Returns null if Plaid credentials aren't configured (mock mode).
 */
function getPlaidClientForVerification(): PlaidApi | null {
  if (!process.env.PLAID_CLIENT_ID || !process.env.PLAID_SECRET) return null;
  const config = new Configuration({
    basePath: PlaidEnvironments[process.env.PLAID_ENV || 'sandbox'],
    baseOptions: {
      headers: {
        'PLAID-CLIENT-ID': process.env.PLAID_CLIENT_ID!,
        'PLAID-SECRET': process.env.PLAID_SECRET!,
      },
    },
  });
  return new PlaidApi(config);
}

async function fetchJwk(kid: string): Promise<JWK | null> {
  // Check cache first
  const cached = jwkCache.get(kid);
  if (cached && Date.now() - cached.fetchedAt < JWK_CACHE_TTL_MS) {
    return cached.jwk;
  }

  const client = getPlaidClientForVerification();
  if (!client) return null;

  try {
    const response = await client.webhookVerificationKeyGet({ key_id: kid });
    const jwk = response.data.key as unknown as JWK;
    jwkCache.set(kid, { jwk, fetchedAt: Date.now() });
    return jwk;
  } catch (err) {
    console.error('[webhook] failed to fetch JWK:', err);
    return null;
  }
}

/**
 * Verify the Plaid-Verification JWT header against the raw request body.
 * Returns true if authentic and within the replay window.
 */
async function verifyPlaidWebhook(
  verificationHeader: string,
  rawBody: string
): Promise<boolean> {
  try {
    // 1. Decode the JWT header to get the key ID
    const header = decodeProtectedHeader(verificationHeader);
    if (!header.kid) {
      console.error('[webhook] JWT missing kid');
      return false;
    }

    // 2. Fetch the JWK from Plaid (cached)
    const jwk = await fetchJwk(header.kid);
    if (!jwk) {
      console.error('[webhook] could not fetch JWK for kid:', header.kid);
      return false;
    }

    // 3. Import the JWK and verify the JWT signature
    const key = await importJWK(jwk);
    const { payload } = await jwtVerify(verificationHeader, key);

    // 4. Check replay window (iat must be within 5 minutes)
    const iat = payload.iat;
    if (!iat || Math.abs(Date.now() / 1000 - iat) > REPLAY_WINDOW_S) {
      console.error('[webhook] JWT outside replay window');
      return false;
    }

    // 5. Verify body integrity via SHA-256
    const expectedHash = (payload as any).request_body_sha256;
    if (!expectedHash) {
      console.error('[webhook] JWT missing request_body_sha256');
      return false;
    }

    const actualHash = crypto
      .createHash('sha256')
      .update(rawBody)
      .digest('hex');

    if (actualHash !== expectedHash) {
      console.error('[webhook] body hash mismatch');
      return false;
    }

    return true;
  } catch (err) {
    console.error('[webhook] verification error:', err);
    return false;
  }
}

// ---------------------------------------------------------------------------
// POST /v1/plaid/webhooks
//
// This endpoint is called by Plaid (not by the iOS app) so it does NOT use
// requireAuth. Instead it verifies the Plaid-Verification JWT signature.
// ---------------------------------------------------------------------------

webhookRouter.post('/', async (req: Request, res: Response) => {
  try {
    const rawBody = JSON.stringify(req.body);
    const verificationHeader = req.headers['plaid-verification'] as string | undefined;

    // In production, always verify. Skip only in mock/dev mode.
    const shouldVerify =
      process.env.NODE_ENV === 'production' ||
      (process.env.PLAID_CLIENT_ID && process.env.PLAID_SECRET);

    if (shouldVerify) {
      if (!verificationHeader) {
        console.error('[webhook] missing Plaid-Verification header');
        res.status(401).json({ error: 'Missing verification header' });
        return;
      }

      const valid = await verifyPlaidWebhook(verificationHeader, rawBody);
      if (!valid) {
        res.status(401).json({ error: 'Invalid webhook signature' });
        return;
      }
    }

    const { webhook_type, webhook_code, item_id } = req.body;

    console.log(
      `Plaid webhook received: ${webhook_type}/${webhook_code} for item ${item_id}`
    );

    // Look up the user who owns this item for audit logging
    let userId: string | null = null;
    if (item_id) {
      const itemResult = await query(
        'SELECT user_id FROM plaid_items WHERE item_id = $1 LIMIT 1',
        [item_id]
      );
      if (itemResult.rows.length > 0) {
        userId = itemResult.rows[0].user_id;
      }
    }

    switch (webhook_type) {
      case 'TRANSACTIONS': {
        console.log(
          `Transaction update for item ${item_id} — would send silent push`
        );
        // TODO: Look up device_tokens for userId, send silent push via APNs
        break;
      }

      case 'HOLDINGS': {
        // HOLDINGS/DEFAULT_UPDATE fires when Plaid has new holdings data for
        // an investment item. For now we just audit — the iOS client pulls
        // on demand. A background refresh can land as a follow-up.
        console.log(`Holdings update for item ${item_id}`);
        break;
      }

      case 'INVESTMENTS_TRANSACTIONS': {
        // INVESTMENTS_TRANSACTIONS/DEFAULT_UPDATE — audit only for now. A
        // future worker would re-sync from investments_last_synced_date.
        console.log(`Investment txns update for item ${item_id}`);
        break;
      }

      case 'LIABILITIES': {
        // LIABILITIES/DEFAULT_UPDATE — audit only for now.
        console.log(`Liabilities update for item ${item_id}`);
        break;
      }

      case 'ITEM': {
        if (webhook_code === 'ERROR') {
          console.log(
            `Item error for ${item_id} — needs re-authentication`
          );
          // TODO: Send push notification asking user to re-link
        }
        break;
      }

      default:
        console.log(`Unhandled webhook type: ${webhook_type}`);
    }

    await audit({
      userId,
      action: 'plaid_webhook_received',
      resourceType: 'webhook',
      resourceId: item_id,
      ip: clientIp(req),
      detail: { webhook_type, webhook_code },
    });

    // Always acknowledge quickly — Plaid expects 200 within 10 seconds
    res.status(200).json({ received: true });
  } catch (error) {
    console.error('Webhook processing error:', error);
    // Still return 200 to prevent Plaid from retrying
    res.status(200).json({ received: true });
  }
});
