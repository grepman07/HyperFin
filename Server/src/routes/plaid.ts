import { Router, Request, Response } from 'express';
import { Configuration, PlaidApi, PlaidEnvironments, Products, CountryCode } from 'plaid';
import rateLimit from 'express-rate-limit';
import { query } from '../services/database';
import { encryptToken, decryptToken } from '../services/tokenEncryption';
import { audit, clientIp } from '../services/auditLog';

export const plaidRouter = Router();

// ---------------------------------------------------------------------------
// Rate limiters — per-user (extracted from JWT by requireAuth upstream)
// ---------------------------------------------------------------------------

const exchangeLimiter = rateLimit({
  windowMs: 60_000,
  max: 10,
  keyGenerator: (req: Request) => req.user?.userId ?? 'anonymous',
  standardHeaders: true,
  legacyHeaders: false,
  message: { error: 'Too many requests. Try again in a minute.' },
});

const transactionLimiter = rateLimit({
  windowMs: 60_000,
  max: 30,
  keyGenerator: (req: Request) => req.user?.userId ?? 'anonymous',
  standardHeaders: true,
  legacyHeaders: false,
  message: { error: 'Too many requests. Try again in a minute.' },
});

// ---------------------------------------------------------------------------
// Plaid Client Setup (real or mock)
// ---------------------------------------------------------------------------

const USE_REAL_PLAID = !!(process.env.PLAID_CLIENT_ID && process.env.PLAID_SECRET);

let plaidClient: PlaidApi | null = null;

if (USE_REAL_PLAID) {
  const configuration = new Configuration({
    basePath: PlaidEnvironments[process.env.PLAID_ENV || 'sandbox'],
    baseOptions: {
      headers: {
        'PLAID-CLIENT-ID': process.env.PLAID_CLIENT_ID!,
        'PLAID-SECRET': process.env.PLAID_SECRET!,
      },
    },
  });
  plaidClient = new PlaidApi(configuration);
  console.log(`Plaid: Real mode (${process.env.PLAID_ENV || 'sandbox'})`);
} else {
  console.log('Plaid: Mock mode (no PLAID_CLIENT_ID set)');
}

// ---------------------------------------------------------------------------
// POST /v1/plaid/link-token
// Requires: requireAuth middleware (applied in index.ts)
// ---------------------------------------------------------------------------

plaidRouter.post('/link-token', async (req: Request, res: Response) => {
  try {
    const userId = req.user!.userId;

    if (USE_REAL_PLAID && plaidClient) {
      const response = await plaidClient.linkTokenCreate({
        user: { client_user_id: userId },
        client_name: 'HyperFin',
        products: [Products.Transactions],
        country_codes: [CountryCode.Us],
        language: 'en',
        webhook: `${process.env.SERVER_URL || 'http://localhost:3000'}/v1/plaid/webhooks`,
      });

      await audit({
        userId,
        action: 'plaid_link_token_created',
        resourceType: 'plaid',
        ip: clientIp(req),
      });

      res.json({
        linkToken: response.data.link_token,
        expiration: response.data.expiration,
      });
    } else {
      // Mock mode — return a fake link token
      res.json({
        linkToken: `link-sandbox-mock-${Date.now()}`,
        expiration: new Date(Date.now() + 4 * 60 * 60 * 1000).toISOString(),
      });
    }
  } catch (error: any) {
    console.error('Failed to create link token:', error?.response?.data || error.message);
    res.status(500).json({ error: 'Failed to create link token' });
  }
});

// ---------------------------------------------------------------------------
// POST /v1/plaid/exchange
// Exchanges a public token for an access token, encrypts it, stores in DB.
// The access token NEVER leaves the server — only itemId + institutionName
// are returned to the client.
// ---------------------------------------------------------------------------

plaidRouter.post('/exchange', exchangeLimiter, async (req: Request, res: Response) => {
  try {
    const userId = req.user!.userId;
    const { publicToken } = req.body;

    if (!publicToken) {
      res.status(400).json({ error: 'publicToken required' });
      return;
    }

    if (USE_REAL_PLAID && plaidClient) {
      const exchangeResponse = await plaidClient.itemPublicTokenExchange({
        public_token: publicToken,
      });
      const accessToken = exchangeResponse.data.access_token;
      const itemId = exchangeResponse.data.item_id;

      // Resolve institution name
      let institutionName = 'Unknown Bank';
      try {
        const itemResponse = await plaidClient.itemGet({ access_token: accessToken });
        const instId = itemResponse.data.item.institution_id;
        if (instId) {
          const instResponse = await plaidClient.institutionsGetById({
            institution_id: instId,
            country_codes: [CountryCode.Us],
          });
          institutionName = instResponse.data.institution.name;
        }
      } catch (e) {
        console.warn('Could not resolve institution name:', e);
      }

      // Encrypt the access token before persisting
      const encryptedToken = encryptToken(accessToken);

      await query(
        `INSERT INTO plaid_items (user_id, access_token_enc, item_id, institution_name)
         VALUES ($1, $2, $3, $4)
         ON CONFLICT DO NOTHING`,
        [userId, encryptedToken, itemId, institutionName]
      );

      await audit({
        userId,
        action: 'plaid_token_exchanged',
        resourceType: 'plaid_item',
        resourceId: itemId,
        ip: clientIp(req),
        detail: { institution: institutionName },
      });

      res.json({ itemId, institutionName });
    } else {
      // Mock mode — simulate exchange
      const itemId = `mock-item-${Date.now()}`;

      // Even in mock mode, encrypt and persist so the flow is realistic
      const encryptedToken = encryptToken('mock-access-token');
      await query(
        `INSERT INTO plaid_items (user_id, access_token_enc, item_id, institution_name)
         VALUES ($1, $2, $3, $4)`,
        [userId, encryptedToken, itemId, 'Chase']
      );

      res.json({ itemId, institutionName: 'Chase' });
    }
  } catch (error: any) {
    console.error('Failed to exchange token:', error?.response?.data || error.message);
    res.status(500).json({ error: 'Failed to exchange token' });
  }
});

// ---------------------------------------------------------------------------
// GET /v1/plaid/transactions
// Decrypts the user's access token on-the-fly, calls Plaid, returns data.
// The decrypted token is never persisted or logged.
// ---------------------------------------------------------------------------

plaidRouter.get('/transactions', transactionLimiter, async (req: Request, res: Response) => {
  try {
    const userId = req.user!.userId;

    // Look up user's Plaid items
    const itemResult = await query(
      'SELECT access_token_enc, item_id, cursor FROM plaid_items WHERE user_id = $1 LIMIT 1',
      [userId]
    );

    if (itemResult.rows.length === 0) {
      res.status(404).json({ error: 'No linked account. Complete Plaid Link first.' });
      return;
    }

    const item = itemResult.rows[0];

    if (USE_REAL_PLAID && plaidClient) {
      // Decrypt access token in memory — never logged or persisted in plaintext
      const accessToken = decryptToken(item.access_token_enc);

      const syncCursor = (req.query.since as string) || item.cursor || undefined;
      const response = await plaidClient.transactionsSync({
        access_token: accessToken,
        cursor: syncCursor || undefined,
      });

      // Persist the new cursor for incremental sync
      if (response.data.next_cursor) {
        await query(
          'UPDATE plaid_items SET cursor = $1 WHERE item_id = $2 AND user_id = $3',
          [response.data.next_cursor, item.item_id, userId]
        );
      }

      const transactions = response.data.added.map((t) => ({
        transactionId: t.transaction_id,
        accountId: t.account_id,
        amount: t.amount,
        date: t.date,
        merchantName: t.merchant_name || null,
        name: t.name,
        category: t.personal_finance_category
          ? [t.personal_finance_category.primary]
          : t.category || [],
        pending: t.pending,
      }));

      const accounts = response.data.accounts.map((a) => ({
        accountId: a.account_id,
        name: a.name,
        type: a.type,
        subtype: a.subtype || null,
        balances: {
          current: a.balances.current,
          available: a.balances.available,
          currencyCode: a.balances.iso_currency_code || 'USD',
        },
      }));

      await audit({
        userId,
        action: 'plaid_transactions_fetched',
        resourceType: 'plaid_item',
        resourceId: item.item_id,
        ip: clientIp(req),
        detail: { transactionCount: transactions.length },
      });

      res.json({ transactions, accounts, hasMore: response.data.has_more });
    } else {
      // Mock mode — return realistic sandbox data
      res.json(generateMockTransactionResponse());
    }
  } catch (error: any) {
    console.error('Failed to fetch transactions:', error?.response?.data || error.message);
    res.status(500).json({ error: 'Failed to fetch transactions' });
  }
});

// ---------------------------------------------------------------------------
// Mock Data Generator (kept for development without Plaid credentials)
// ---------------------------------------------------------------------------

function generateMockTransactionResponse() {
  const accounts = [
    {
      accountId: 'mock-checking-001',
      name: 'Plaid Checking',
      type: 'depository',
      subtype: 'checking',
      balances: { current: 4287.53, available: 4187.53, currencyCode: 'USD' },
    },
    {
      accountId: 'mock-savings-001',
      name: 'Plaid Savings',
      type: 'depository',
      subtype: 'savings',
      balances: { current: 12450.0, available: 12450.0, currencyCode: 'USD' },
    },
    {
      accountId: 'mock-credit-001',
      name: 'Plaid Credit Card',
      type: 'credit',
      subtype: 'credit card',
      balances: { current: 1823.47, available: 6176.53, currencyCode: 'USD' },
    },
  ];

  const templates = [
    { merchant: 'Starbucks', min: 4.5, max: 8.75, account: 'mock-credit-001', cat: 'Food and Drink' },
    { merchant: 'Chipotle', min: 10.5, max: 16, account: 'mock-credit-001', cat: 'Food and Drink' },
    { merchant: 'DoorDash', min: 18, max: 45, account: 'mock-credit-001', cat: 'Food and Drink' },
    { merchant: 'Trader Joe\'s', min: 45, max: 120, account: 'mock-checking-001', cat: 'Shops' },
    { merchant: 'Whole Foods', min: 30, max: 90, account: 'mock-credit-001', cat: 'Shops' },
    { merchant: 'Uber', min: 8, max: 35, account: 'mock-credit-001', cat: 'Travel' },
    { merchant: 'Shell', min: 35, max: 65, account: 'mock-checking-001', cat: 'Travel' },
    { merchant: 'Amazon', min: 12, max: 150, account: 'mock-credit-001', cat: 'Shops' },
    { merchant: 'Netflix', min: 15.49, max: 15.49, account: 'mock-credit-001', cat: 'Service' },
    { merchant: 'Spotify', min: 10.99, max: 10.99, account: 'mock-credit-001', cat: 'Service' },
    { merchant: 'Verizon', min: 85, max: 85, account: 'mock-checking-001', cat: 'Service' },
    { merchant: 'Con Edison', min: 95, max: 145, account: 'mock-checking-001', cat: 'Service' },
    { merchant: 'Equinox', min: 110, max: 110, account: 'mock-checking-001', cat: 'Recreation' },
    { merchant: 'AMC Theatres', min: 15, max: 40, account: 'mock-credit-001', cat: 'Recreation' },
    { merchant: 'Target', min: 20, max: 80, account: 'mock-credit-001', cat: 'Shops' },
  ];

  const transactions: any[] = [];
  const now = new Date();

  for (let daysAgo = 0; daysAgo < 90; daysAgo++) {
    const date = new Date(now);
    date.setDate(date.getDate() - daysAgo);
    const dateStr = date.toISOString().split('T')[0];

    for (const t of templates) {
      if (Math.random() > 0.15) continue;
      const amount =
        t.min === t.max
          ? t.min
          : +(t.min + Math.random() * (t.max - t.min)).toFixed(2);
      transactions.push({
        transactionId: `mock-txn-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`,
        accountId: t.account,
        amount,
        date: dateStr,
        merchantName: t.merchant,
        name: t.merchant,
        category: [t.cat],
        pending: false,
      });
    }

    // Paychecks on 1st and 15th
    if (date.getDate() === 1 || date.getDate() === 15) {
      transactions.push({
        transactionId: `mock-txn-pay-${dateStr}`,
        accountId: 'mock-checking-001',
        amount: -3750,
        date: dateStr,
        merchantName: 'Employer Direct Deposit',
        name: 'Payroll',
        category: ['Transfer'],
        pending: false,
      });
    }

    // Rent on the 1st
    if (date.getDate() === 1) {
      transactions.push({
        transactionId: `mock-txn-rent-${dateStr}`,
        accountId: 'mock-checking-001',
        amount: 2200,
        date: dateStr,
        merchantName: 'Rent Payment',
        name: 'Rent Payment',
        category: ['Service'],
        pending: false,
      });
    }
  }

  return { transactions, accounts, hasMore: false };
}
