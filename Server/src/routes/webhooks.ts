import { Router, Request, Response } from 'express';

export const webhookRouter = Router();

// POST /v1/plaid/webhooks
// Receives Plaid webhooks and triggers silent push notifications to iOS devices
webhookRouter.post('/', async (req: Request, res: Response) => {
  try {
    const { webhook_type, webhook_code, item_id } = req.body;

    console.log(`Plaid webhook received: ${webhook_type}/${webhook_code} for item ${item_id}`);

    switch (webhook_type) {
      case 'TRANSACTIONS': {
        // New transactions available — send silent push to user's device
        // TODO: Look up device_tokens for the user who owns this item_id
        // await sendSilentPush(deviceToken, { webhook_type, item_id });
        console.log(`Transaction update for item ${item_id} — sending silent push`);
        break;
      }

      case 'ITEM': {
        if (webhook_code === 'ERROR') {
          // Plaid item needs re-authentication
          // TODO: Send push notification asking user to re-link
          console.log(`Item error for ${item_id} — needs re-authentication`);
        }
        break;
      }

      default:
        console.log(`Unhandled webhook type: ${webhook_type}`);
    }

    // Always acknowledge quickly — Plaid expects 200 within 10 seconds
    res.status(200).json({ received: true });
  } catch (error) {
    console.error('Webhook processing error:', error);
    // Still return 200 to prevent Plaid from retrying
    res.status(200).json({ received: true });
  }
});
