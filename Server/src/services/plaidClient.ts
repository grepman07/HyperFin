import { Configuration, PlaidApi, PlaidEnvironments } from 'plaid';

/**
 * Shared Plaid client factory.
 *
 * All routes that need to talk to Plaid import from here rather than
 * constructing their own client — single choke point for config/env handling,
 * and we only ever hold one PlaidApi instance per process.
 *
 * "Mock mode" is active when either PLAID_CLIENT_ID or PLAID_SECRET is unset.
 * In mock mode, callers are expected to short-circuit and return canned
 * fixtures instead of hitting Plaid — `getPlaidClient()` returns null so a
 * forgotten branch fails loudly rather than silently contacting Plaid with
 * missing credentials.
 */

let cached: PlaidApi | null = null;
let initialised = false;

function isMockModeInternal(): boolean {
  return !(process.env.PLAID_CLIENT_ID && process.env.PLAID_SECRET);
}

/** True when we should use canned fixtures instead of hitting Plaid. */
export function isMockMode(): boolean {
  return isMockModeInternal();
}

/**
 * Returns the singleton PlaidApi instance, or null when running in mock mode.
 * Callers must check mock mode first and branch — this function will not
 * throw in mock mode, it just returns null.
 */
export function getPlaidClient(): PlaidApi | null {
  if (initialised) return cached;
  initialised = true;

  if (isMockModeInternal()) {
    console.log('[plaid] Mock mode (no PLAID_CLIENT_ID / PLAID_SECRET set)');
    cached = null;
    return null;
  }

  const configuration = new Configuration({
    basePath: PlaidEnvironments[process.env.PLAID_ENV || 'sandbox'],
    baseOptions: {
      headers: {
        'PLAID-CLIENT-ID': process.env.PLAID_CLIENT_ID!,
        'PLAID-SECRET': process.env.PLAID_SECRET!,
      },
    },
  });
  cached = new PlaidApi(configuration);
  console.log(`[plaid] Real mode (${process.env.PLAID_ENV || 'sandbox'})`);
  return cached;
}

/**
 * Test-only: reset the cached client so tests that mutate process.env between
 * describe blocks pick up the new config on next call. Not exported from the
 * public API surface — only test files import this.
 */
export function __resetPlaidClientForTests(): void {
  cached = null;
  initialised = false;
}
