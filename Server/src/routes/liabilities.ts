import { Router, Request, Response } from 'express';
import rateLimit from 'express-rate-limit';
import { query } from '../services/database';
import { decryptToken } from '../services/tokenEncryption';
import { audit, clientIp } from '../services/auditLog';
import { getPlaidClient, isMockMode } from '../services/plaidClient';

export const liabilitiesRouter = Router();

const limiter = rateLimit({
  windowMs: 60_000,
  max: 30,
  keyGenerator: (req: Request) => req.user?.userId ?? 'anonymous',
  standardHeaders: true,
  legacyHeaders: false,
  message: { error: 'Too many requests. Try again in a minute.' },
});

function isBenignPlaidError(e: any): boolean {
  const code = e?.response?.data?.error_code;
  return (
    code === 'PRODUCTS_NOT_SUPPORTED' ||
    code === 'PRODUCT_NOT_READY' ||
    code === 'NO_LIABILITY_ACCOUNTS' ||
    code === 'NO_ACCOUNTS'
  );
}

// ---------------------------------------------------------------------------
// GET /v1/liabilities
//
// Returns credit / mortgage / student loan data in one call. Plaid returns
// each kind as a separate array keyed by liability type; we persist one row
// per (account, kind) with the raw payload in jsonb since shapes diverge
// heavily and we never filter on the inside fields server-side.
//
// Audit detail NEVER includes the payload — mortgage/student data contains
// loan account numbers. Only action + item_id + counts are logged.
// ---------------------------------------------------------------------------

liabilitiesRouter.get('/', limiter, async (req: Request, res: Response) => {
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

      let credit: any[] = [];
      let mortgage: any[] = [];
      let student: any[] = [];
      let accounts: any[] = [];

      try {
        const response = await plaidClient.liabilitiesGet({ access_token: accessToken });
        credit = response.data.liabilities.credit ?? [];
        mortgage = response.data.liabilities.mortgage ?? [];
        student = response.data.liabilities.student ?? [];
        accounts = response.data.accounts;
      } catch (err) {
        if (isBenignPlaidError(err)) {
          await audit({
            userId,
            action: 'liabilities.fetch',
            resourceType: 'plaid_item',
            resourceId: item.item_id,
            ip: clientIp(req),
            detail: { supported: false },
          });
          res.json({ credit: [], mortgage: [], student: [], accounts: [] });
          return;
        }
        throw err;
      }

      // Upsert all three kinds into the unified `liabilities` table.
      const persist = async (
        rows: any[],
        kind: 'credit' | 'mortgage' | 'student'
      ) => {
        for (const row of rows) {
          await query(
            `INSERT INTO liabilities (item_id, account_id, kind, data, updated_at)
             VALUES ($1, $2, $3, $4, NOW())
             ON CONFLICT (account_id, kind) DO UPDATE SET
               data = EXCLUDED.data,
               updated_at = NOW()`,
            [item.item_id, row.account_id, kind, JSON.stringify(row)]
          );
        }
      };
      await persist(credit, 'credit');
      await persist(mortgage, 'mortgage');
      await persist(student, 'student');

      await audit({
        userId,
        action: 'liabilities.fetch',
        resourceType: 'plaid_item',
        resourceId: item.item_id,
        ip: clientIp(req),
        detail: {
          credit: credit.length,
          mortgage: mortgage.length,
          student: student.length,
        },
      });

      res.json({
        credit,
        mortgage,
        student,
        accounts: accounts.map((a: any) => ({
          accountId: a.account_id,
          name: a.name,
          type: a.type,
          subtype: a.subtype ?? null,
        })),
      });
    } else {
      res.json(generateMockLiabilities());
    }
  } catch (error: any) {
    console.error('Failed to fetch liabilities:', error?.response?.data || error.message);
    res.status(500).json({ error: 'Failed to fetch liabilities' });
  }
});

// ---------------------------------------------------------------------------
// Mock data — covers all three kinds so tests don't pass with thin coverage.
// ---------------------------------------------------------------------------

function generateMockLiabilities() {
  const accounts = [
    {
      accountId: 'mock-credit-001',
      name: 'Plaid Credit Card',
      type: 'credit',
      subtype: 'credit card',
    },
    {
      accountId: 'mock-mortgage-001',
      name: 'Plaid Mortgage',
      type: 'loan',
      subtype: 'mortgage',
    },
    {
      accountId: 'mock-student-001',
      name: 'Plaid Student Loan',
      type: 'loan',
      subtype: 'student',
    },
  ];
  const credit = [
    {
      account_id: 'mock-credit-001',
      aprs: [
        {
          apr_percentage: 22.49,
          apr_type: 'purchase_apr',
          balance_subject_to_apr: 1823.47,
        },
      ],
      is_overdue: false,
      last_payment_amount: 250.0,
      last_payment_date: '2026-03-15',
      last_statement_issue_date: '2026-03-31',
      last_statement_balance: 1623.47,
      minimum_payment_amount: 35.0,
      next_payment_due_date: '2026-04-25',
    },
  ];
  const mortgage = [
    {
      account_id: 'mock-mortgage-001',
      account_number: '3120194412',
      current_late_fee: 0,
      escrow_balance: 4120.52,
      has_pmi: false,
      has_prepayment_penalty: false,
      interest_rate: { percentage: 3.25, type: 'fixed' },
      last_payment_amount: 2180.5,
      last_payment_date: '2026-04-01',
      loan_term: '30 year',
      loan_type_description: 'conventional',
      maturity_date: '2048-04-01',
      next_monthly_payment: 2180.5,
      next_payment_due_date: '2026-05-01',
      origination_date: '2018-04-01',
      origination_principal_amount: 425000,
      past_due_amount: 0,
      property_address: {
        city: 'San Francisco',
        country: 'US',
        postal_code: '94110',
        region: 'CA',
        street: '2250 Mission St',
      },
      ytd_interest_paid: 4210.88,
      ytd_principal_paid: 2540.12,
    },
  ];
  const student = [
    {
      account_id: 'mock-student-001',
      account_number: 'S83901238',
      disbursement_dates: ['2014-08-15'],
      expected_payoff_date: '2030-08-15',
      guarantor: 'DEPT OF ED',
      interest_rate_percentage: 5.25,
      is_overdue: false,
      last_payment_amount: 312.0,
      last_payment_date: '2026-04-01',
      last_statement_issue_date: '2026-04-01',
      loan_name: 'Unsubsidized Stafford',
      loan_status: {
        end_date: '2030-08-15',
        type: 'repayment',
      },
      minimum_payment_amount: 312.0,
      next_payment_due_date: '2026-05-01',
      origination_date: '2014-08-15',
      origination_principal_amount: 28500,
      outstanding_interest_amount: 122.3,
      payment_reference_number: 'PRN998877',
      servicer_address: {
        city: 'Lincoln',
        country: 'US',
        postal_code: '68501',
        region: 'NE',
        street: '121 S 13th St',
      },
      ytd_interest_paid: 420.12,
      ytd_principal_paid: 1820.66,
    },
  ];
  return { credit, mortgage, student, accounts };
}
