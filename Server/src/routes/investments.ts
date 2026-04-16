import { Router, Request, Response } from 'express';
import rateLimit from 'express-rate-limit';
import { query } from '../services/database';
import { decryptToken } from '../services/tokenEncryption';
import { audit, clientIp } from '../services/auditLog';
import { getPlaidClient, isMockMode } from '../services/plaidClient';

export const investmentsRouter = Router();

// ---------------------------------------------------------------------------
// Rate limiters — per-user. Mirror /v1/plaid/transactions (30/min).
// ---------------------------------------------------------------------------

const limiter = rateLimit({
  windowMs: 60_000,
  max: 30,
  keyGenerator: (req: Request) => req.user?.userId ?? 'anonymous',
  standardHeaders: true,
  legacyHeaders: false,
  message: { error: 'Too many requests. Try again in a minute.' },
});

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/**
 * Errors from institutions that don't support investments/liabilities should
 * degrade gracefully — the client calls these endpoints for every linked item
 * regardless of product coverage. Returning 200 with empty data lets the iOS
 * layer short-circuit instead of forcing it to parse error codes.
 */
function isBenignPlaidError(e: any): boolean {
  const code = e?.response?.data?.error_code;
  return (
    code === 'PRODUCTS_NOT_SUPPORTED' ||
    code === 'PRODUCT_NOT_READY' ||
    code === 'NO_ACCOUNTS'
  );
}

async function upsertSecurities(
  secs: Array<{
    security_id: string;
    ticker_symbol: string | null;
    name: string | null;
    type: string | null;
    iso_currency_code: string | null;
    close_price: number | null;
    close_price_as_of: string | null;
  }>
): Promise<void> {
  for (const s of secs) {
    await query(
      `INSERT INTO securities
         (security_id, ticker_symbol, name, type, iso_currency_code, close_price, close_price_as_of, updated_at)
       VALUES ($1,$2,$3,$4,$5,$6,$7, NOW())
       ON CONFLICT (security_id) DO UPDATE SET
         ticker_symbol = EXCLUDED.ticker_symbol,
         name = EXCLUDED.name,
         type = EXCLUDED.type,
         iso_currency_code = EXCLUDED.iso_currency_code,
         close_price = EXCLUDED.close_price,
         close_price_as_of = EXCLUDED.close_price_as_of,
         updated_at = NOW()`,
      [
        s.security_id,
        s.ticker_symbol,
        s.name,
        s.type,
        s.iso_currency_code,
        s.close_price,
        s.close_price_as_of,
      ]
    );
  }
}

// ---------------------------------------------------------------------------
// GET /v1/investments/holdings
// ---------------------------------------------------------------------------

investmentsRouter.get('/holdings', limiter, async (req: Request, res: Response) => {
  try {
    const userId = req.user!.userId;

    const itemResult = await query(
      'SELECT access_token_enc, item_id FROM plaid_items WHERE user_id = $1 ORDER BY created_at DESC LIMIT 1',
      [userId]
    );

    if (itemResult.rows.length === 0) {
      res.status(404).json({ error: 'No linked account. Complete Plaid Link first.' });
      return;
    }

    const item = itemResult.rows[0];
    const plaidClient = getPlaidClient();

    if (!isMockMode() && plaidClient) {
      const accessToken = decryptToken(item.access_token_enc);

      let holdings: any[] = [];
      let securities: any[] = [];
      let accounts: any[] = [];
      try {
        const response = await plaidClient.investmentsHoldingsGet({
          access_token: accessToken,
        });
        holdings = response.data.holdings;
        securities = response.data.securities;
        accounts = response.data.accounts;
      } catch (err) {
        if (isBenignPlaidError(err)) {
          await audit({
            userId,
            action: 'investments.holdings.fetch',
            resourceType: 'plaid_item',
            resourceId: item.item_id,
            ip: clientIp(req),
            detail: { supported: false },
          });
          res.json({ holdings: [], securities: [], accounts: [] });
          return;
        }
        throw err;
      }

      // Persist securities first (FK target), then holdings
      await upsertSecurities(
        securities.map((s: any) => ({
          security_id: s.security_id,
          ticker_symbol: s.ticker_symbol ?? null,
          name: s.name ?? null,
          type: s.type ?? null,
          iso_currency_code: s.iso_currency_code ?? null,
          close_price: s.close_price ?? null,
          close_price_as_of: s.close_price_as_of ?? null,
        }))
      );

      for (const h of holdings) {
        await query(
          `INSERT INTO holdings
             (item_id, account_id, security_id, quantity, institution_price, institution_value, cost_basis, iso_currency_code, updated_at)
           VALUES ($1,$2,$3,$4,$5,$6,$7,$8, NOW())
           ON CONFLICT (account_id, security_id) DO UPDATE SET
             quantity = EXCLUDED.quantity,
             institution_price = EXCLUDED.institution_price,
             institution_value = EXCLUDED.institution_value,
             cost_basis = EXCLUDED.cost_basis,
             iso_currency_code = EXCLUDED.iso_currency_code,
             updated_at = NOW()`,
          [
            item.item_id,
            h.account_id,
            h.security_id,
            h.quantity,
            h.institution_price ?? null,
            h.institution_value ?? null,
            h.cost_basis ?? null,
            h.iso_currency_code ?? null,
          ]
        );
      }

      await audit({
        userId,
        action: 'investments.holdings.fetch',
        resourceType: 'plaid_item',
        resourceId: item.item_id,
        ip: clientIp(req),
        detail: { holdingsCount: holdings.length },
      });

      res.json({
        holdings: holdings.map((h: any) => ({
          accountId: h.account_id,
          securityId: h.security_id,
          quantity: h.quantity,
          institutionPrice: h.institution_price ?? null,
          institutionValue: h.institution_value ?? null,
          costBasis: h.cost_basis ?? null,
          currencyCode: h.iso_currency_code ?? 'USD',
        })),
        securities: securities.map((s: any) => ({
          securityId: s.security_id,
          tickerSymbol: s.ticker_symbol ?? null,
          name: s.name ?? null,
          type: s.type ?? null,
          closePrice: s.close_price ?? null,
          currencyCode: s.iso_currency_code ?? 'USD',
        })),
        accounts: accounts.map((a: any) => ({
          accountId: a.account_id,
          name: a.name,
          type: a.type,
          subtype: a.subtype ?? null,
        })),
      });
    } else {
      res.json(generateMockHoldings());
    }
  } catch (error: any) {
    console.error('Failed to fetch holdings:', error?.response?.data || error.message);
    res.status(500).json({ error: 'Failed to fetch holdings' });
  }
});

// ---------------------------------------------------------------------------
// GET /v1/investments/transactions?start_date=YYYY-MM-DD&end_date=YYYY-MM-DD
//
// Unlike /transactions/sync, this API is date-range paginated. We loop
// offset/count pages until exhausted and persist each row, then record the
// window end on plaid_items.investments_last_synced_date for incremental
// syncs on the next call.
// ---------------------------------------------------------------------------

investmentsRouter.get('/transactions', limiter, async (req: Request, res: Response) => {
  try {
    const userId = req.user!.userId;

    const itemResult = await query(
      `SELECT access_token_enc, item_id, investments_last_synced_date
         FROM plaid_items WHERE user_id = $1 ORDER BY created_at DESC LIMIT 1`,
      [userId]
    );

    if (itemResult.rows.length === 0) {
      res.status(404).json({ error: 'No linked account. Complete Plaid Link first.' });
      return;
    }

    const item = itemResult.rows[0];
    const plaidClient = getPlaidClient();

    // Default window: last-synced-date → today; fallback to 24 months.
    const today = new Date();
    const defaultStart = new Date(today);
    defaultStart.setMonth(defaultStart.getMonth() - 24);

    const endDate =
      (req.query.end_date as string) || today.toISOString().slice(0, 10);
    const startDate =
      (req.query.start_date as string) ||
      (item.investments_last_synced_date
        ? new Date(item.investments_last_synced_date).toISOString().slice(0, 10)
        : defaultStart.toISOString().slice(0, 10));

    if (!isMockMode() && plaidClient) {
      const accessToken = decryptToken(item.access_token_enc);

      const allTxns: any[] = [];
      const securitiesById = new Map<string, any>();
      let accounts: any[] = [];
      const PAGE_SIZE = 250;
      let offset = 0;

      try {
        // Paginate through the full window.
        while (true) {
          const response = await plaidClient.investmentsTransactionsGet({
            access_token: accessToken,
            start_date: startDate,
            end_date: endDate,
            options: { count: PAGE_SIZE, offset },
          });
          allTxns.push(...response.data.investment_transactions);
          for (const s of response.data.securities) {
            securitiesById.set(s.security_id, s);
          }
          accounts = response.data.accounts;
          const total = response.data.total_investment_transactions;
          offset += response.data.investment_transactions.length;
          if (offset >= total || response.data.investment_transactions.length === 0) break;
        }
      } catch (err) {
        if (isBenignPlaidError(err)) {
          await audit({
            userId,
            action: 'investments.transactions.fetch',
            resourceType: 'plaid_item',
            resourceId: item.item_id,
            ip: clientIp(req),
            detail: { supported: false },
          });
          res.json({ transactions: [], securities: [], accounts: [] });
          return;
        }
        throw err;
      }

      await upsertSecurities(
        [...securitiesById.values()].map((s: any) => ({
          security_id: s.security_id,
          ticker_symbol: s.ticker_symbol ?? null,
          name: s.name ?? null,
          type: s.type ?? null,
          iso_currency_code: s.iso_currency_code ?? null,
          close_price: s.close_price ?? null,
          close_price_as_of: s.close_price_as_of ?? null,
        }))
      );

      for (const t of allTxns) {
        await query(
          `INSERT INTO investment_transactions
             (investment_transaction_id, item_id, account_id, security_id, date, name, type, subtype, quantity, price, fees, amount, iso_currency_code)
           VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13)
           ON CONFLICT (investment_transaction_id) DO NOTHING`,
          [
            t.investment_transaction_id,
            item.item_id,
            t.account_id,
            t.security_id ?? null,
            t.date,
            t.name ?? null,
            t.type ?? null,
            t.subtype ?? null,
            t.quantity ?? null,
            t.price ?? null,
            t.fees ?? null,
            t.amount ?? null,
            t.iso_currency_code ?? null,
          ]
        );
      }

      await query(
        `UPDATE plaid_items SET investments_last_synced_date = $1
           WHERE item_id = $2 AND user_id = $3`,
        [endDate, item.item_id, userId]
      );

      await audit({
        userId,
        action: 'investments.transactions.fetch',
        resourceType: 'plaid_item',
        resourceId: item.item_id,
        ip: clientIp(req),
        detail: { count: allTxns.length, startDate, endDate },
      });

      res.json({
        transactions: allTxns.map((t: any) => ({
          investmentTransactionId: t.investment_transaction_id,
          accountId: t.account_id,
          securityId: t.security_id ?? null,
          date: t.date,
          name: t.name ?? null,
          type: t.type ?? null,
          subtype: t.subtype ?? null,
          quantity: t.quantity ?? null,
          price: t.price ?? null,
          fees: t.fees ?? null,
          amount: t.amount ?? null,
          currencyCode: t.iso_currency_code ?? 'USD',
        })),
        securities: [...securitiesById.values()].map((s: any) => ({
          securityId: s.security_id,
          tickerSymbol: s.ticker_symbol ?? null,
          name: s.name ?? null,
          type: s.type ?? null,
          closePrice: s.close_price ?? null,
          currencyCode: s.iso_currency_code ?? 'USD',
        })),
        accounts: accounts.map((a: any) => ({
          accountId: a.account_id,
          name: a.name,
          type: a.type,
          subtype: a.subtype ?? null,
        })),
      });
    } else {
      res.json(generateMockInvestmentTransactions());
    }
  } catch (error: any) {
    console.error(
      'Failed to fetch investment transactions:',
      error?.response?.data || error.message
    );
    res.status(500).json({ error: 'Failed to fetch investment transactions' });
  }
});

// ---------------------------------------------------------------------------
// Mock data — used when Plaid credentials aren't set.
// ---------------------------------------------------------------------------

function generateMockHoldings() {
  const securities = [
    {
      securityId: 'sec-aapl',
      tickerSymbol: 'AAPL',
      name: 'Apple Inc.',
      type: 'equity',
      closePrice: 192.35,
      currencyCode: 'USD',
    },
    {
      securityId: 'sec-voo',
      tickerSymbol: 'VOO',
      name: 'Vanguard S&P 500 ETF',
      type: 'etf',
      closePrice: 487.21,
      currencyCode: 'USD',
    },
    {
      securityId: 'sec-vtsax',
      tickerSymbol: 'VTSAX',
      name: 'Vanguard Total Stock Market Admiral',
      type: 'mutual fund',
      closePrice: 132.88,
      currencyCode: 'USD',
    },
  ];
  const accounts = [
    {
      accountId: 'mock-brokerage-001',
      name: 'Plaid Brokerage',
      type: 'investment',
      subtype: 'brokerage',
    },
    {
      accountId: 'mock-ira-001',
      name: 'Plaid Roth IRA',
      type: 'investment',
      subtype: 'roth',
    },
  ];
  const holdings = [
    {
      accountId: 'mock-brokerage-001',
      securityId: 'sec-aapl',
      quantity: 32,
      institutionPrice: 192.35,
      institutionValue: 6155.2,
      costBasis: 4820,
      currencyCode: 'USD',
    },
    {
      accountId: 'mock-brokerage-001',
      securityId: 'sec-voo',
      quantity: 14,
      institutionPrice: 487.21,
      institutionValue: 6820.94,
      costBasis: 5900,
      currencyCode: 'USD',
    },
    {
      accountId: 'mock-ira-001',
      securityId: 'sec-vtsax',
      quantity: 215.4,
      institutionPrice: 132.88,
      institutionValue: 28622.35,
      costBasis: 24100,
      currencyCode: 'USD',
    },
  ];
  return { holdings, securities, accounts };
}

function generateMockInvestmentTransactions() {
  const today = new Date();
  const iso = (d: Date) => d.toISOString().slice(0, 10);
  const day = (offset: number) => {
    const d = new Date(today);
    d.setDate(d.getDate() - offset);
    return iso(d);
  };
  const transactions = [
    {
      investmentTransactionId: 'mock-itx-1',
      accountId: 'mock-brokerage-001',
      securityId: 'sec-aapl',
      date: day(2),
      name: 'BUY AAPL',
      type: 'buy',
      subtype: 'buy',
      quantity: 4,
      price: 190.0,
      fees: 0,
      amount: 760.0,
      currencyCode: 'USD',
    },
    {
      investmentTransactionId: 'mock-itx-2',
      accountId: 'mock-brokerage-001',
      securityId: 'sec-voo',
      date: day(10),
      name: 'BUY VOO',
      type: 'buy',
      subtype: 'buy',
      quantity: 2,
      price: 481.12,
      fees: 0,
      amount: 962.24,
      currencyCode: 'USD',
    },
    {
      investmentTransactionId: 'mock-itx-3',
      accountId: 'mock-brokerage-001',
      securityId: 'sec-aapl',
      date: day(31),
      name: 'DIV AAPL',
      type: 'cash',
      subtype: 'dividend',
      quantity: 0,
      price: 0,
      fees: 0,
      amount: -7.68,
      currencyCode: 'USD',
    },
    {
      investmentTransactionId: 'mock-itx-4',
      accountId: 'mock-ira-001',
      securityId: 'sec-vtsax',
      date: day(45),
      name: 'BUY VTSAX',
      type: 'buy',
      subtype: 'buy',
      quantity: 15,
      price: 131.5,
      fees: 0,
      amount: 1972.5,
      currencyCode: 'USD',
    },
  ];
  const securities = [
    {
      securityId: 'sec-aapl',
      tickerSymbol: 'AAPL',
      name: 'Apple Inc.',
      type: 'equity',
      closePrice: 192.35,
      currencyCode: 'USD',
    },
    {
      securityId: 'sec-voo',
      tickerSymbol: 'VOO',
      name: 'Vanguard S&P 500 ETF',
      type: 'etf',
      closePrice: 487.21,
      currencyCode: 'USD',
    },
    {
      securityId: 'sec-vtsax',
      tickerSymbol: 'VTSAX',
      name: 'Vanguard Total Stock Market Admiral',
      type: 'mutual fund',
      closePrice: 132.88,
      currencyCode: 'USD',
    },
  ];
  const accounts = [
    {
      accountId: 'mock-brokerage-001',
      name: 'Plaid Brokerage',
      type: 'investment',
      subtype: 'brokerage',
    },
    {
      accountId: 'mock-ira-001',
      name: 'Plaid Roth IRA',
      type: 'investment',
      subtype: 'roth',
    },
  ];
  return { transactions, securities, accounts };
}
