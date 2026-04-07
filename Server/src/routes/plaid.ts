import { Router, Request, Response } from 'express';

export const plaidRouter = Router();

// POST /v1/plaid/link-token
// Creates a Plaid Link token for the iOS client
plaidRouter.post('/link-token', async (_req: Request, res: Response) => {
  try {
    // TODO: Initialize Plaid client and create link token
    // const plaidClient = new PlaidApi(configuration);
    // const response = await plaidClient.linkTokenCreate({
    //   user: { client_user_id: userId },
    //   client_name: 'HyperFin',
    //   products: [Products.Transactions],
    //   country_codes: [CountryCode.Us],
    //   language: 'en',
    //   webhook: `${process.env.SERVER_URL}/v1/plaid/webhooks`,
    // });

    res.json({
      linkToken: 'placeholder_link_token',
      expiration: new Date(Date.now() + 4 * 60 * 60 * 1000).toISOString(),
    });
  } catch (error) {
    console.error('Failed to create link token:', error);
    res.status(500).json({ error: 'Failed to create link token' });
  }
});

// POST /v1/plaid/exchange
// Exchanges public_token for access_token (stored server-side, encrypted)
plaidRouter.post('/exchange', async (req: Request, res: Response) => {
  try {
    const { publicToken } = req.body;
    if (!publicToken) {
      res.status(400).json({ error: 'publicToken required' });
      return;
    }

    // TODO: Exchange with Plaid
    // const response = await plaidClient.itemPublicTokenExchange({ public_token: publicToken });
    // const accessToken = response.data.access_token;
    // const itemId = response.data.item_id;
    //
    // Store encrypted access_token in plaid_items table
    // await db.query('INSERT INTO plaid_items ...', [userId, encrypt(accessToken), itemId]);

    res.json({
      itemId: 'placeholder_item_id',
      institutionName: 'Sample Bank',
    });
  } catch (error) {
    console.error('Failed to exchange token:', error);
    res.status(500).json({ error: 'Failed to exchange token' });
  }
});

// GET /v1/plaid/transactions
// Relays transactions from Plaid to device — NEVER persists financial data
plaidRouter.get('/transactions', async (req: Request, res: Response) => {
  try {
    const since = req.query.since as string | undefined;

    // TODO: Fetch from Plaid using stored access_token
    // const accessToken = await getAccessTokenForUser(userId);
    // const response = await plaidClient.transactionsSync({
    //   access_token: decrypt(accessToken),
    //   cursor: since,
    // });
    //
    // IMPORTANT: Financial data passes through as a relay only.
    // It is NEVER stored in the database.

    res.json({
      transactions: [],
      accounts: [],
      hasMore: false,
    });
  } catch (error) {
    console.error('Failed to fetch transactions:', error);
    res.status(500).json({ error: 'Failed to fetch transactions' });
  }
});
