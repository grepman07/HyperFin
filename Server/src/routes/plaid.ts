import { Router, Request, Response } from 'express';
import { Configuration, PlaidApi, PlaidEnvironments, Products, CountryCode } from 'plaid';

export const plaidRouter = Router();

// --- Plaid Client Setup (real or mock) ---

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

// In-memory token store (MVP — resets on server restart)
const tokenStore = new Map<string, { accessToken: string; itemId: string; institutionName: string }>();
const MVP_USER_ID = 'mvp-user-1';

// --- POST /v1/plaid/link-token ---

plaidRouter.post('/link-token', async (_req: Request, res: Response) => {
  try {
    if (USE_REAL_PLAID && plaidClient) {
      const response = await plaidClient.linkTokenCreate({
        user: { client_user_id: MVP_USER_ID },
        client_name: 'HyperFin',
        products: [Products.Transactions],
        country_codes: [CountryCode.Us],
        language: 'en',
        webhook: `${process.env.SERVER_URL || 'http://localhost:3000'}/v1/plaid/webhooks`,
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

// --- POST /v1/plaid/exchange ---

plaidRouter.post('/exchange', async (req: Request, res: Response) => {
  try {
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

      // Get institution name
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

      tokenStore.set(MVP_USER_ID, { accessToken, itemId, institutionName });

      res.json({ itemId, institutionName });
    } else {
      // Mock mode
      const itemId = `mock-item-${Date.now()}`;
      tokenStore.set(MVP_USER_ID, {
        accessToken: 'mock-access-token',
        itemId,
        institutionName: 'Chase',
      });

      res.json({ itemId, institutionName: 'Chase' });
    }
  } catch (error: any) {
    console.error('Failed to exchange token:', error?.response?.data || error.message);
    res.status(500).json({ error: 'Failed to exchange token' });
  }
});

// --- GET /v1/plaid/transactions ---

plaidRouter.get('/transactions', async (req: Request, res: Response) => {
  try {
    const stored = tokenStore.get(MVP_USER_ID);
    if (!stored) {
      res.status(404).json({ error: 'No linked account. Complete Plaid Link first.' });
      return;
    }

    if (USE_REAL_PLAID && plaidClient) {
      const cursor = (req.query.since as string) || undefined;
      const response = await plaidClient.transactionsSync({
        access_token: stored.accessToken,
        cursor: cursor || undefined,
      });

      const transactions = response.data.added.map((t) => ({
        transactionId: t.transaction_id,
        accountId: t.account_id,
        amount: t.amount,
        date: t.date,
        merchantName: t.merchant_name || null,
        name: t.name,
        category: t.personal_finance_category ? [t.personal_finance_category.primary] : t.category || [],
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

// --- Mock Data Generator ---

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
      if (Math.random() > 0.15) continue; // ~15% daily chance
      const amount = t.min === t.max ? t.min : +(t.min + Math.random() * (t.max - t.min)).toFixed(2);
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

    // Add paychecks (1st and 15th)
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
