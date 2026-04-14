import { query } from './database';

/**
 * Append-only audit trail for sensitive operations.
 *
 * Every Plaid token exchange, transaction fetch, authentication event, and
 * webhook is logged here. The admin route can read from `audit_log` but the
 * table never contains raw access tokens or financial data — only action
 * labels, resource identifiers, and IP addresses.
 *
 * Writes are fire-and-forget: a failed audit insert should never block the
 * primary operation. We catch and log instead of throwing.
 */

export interface AuditEntry {
  userId?: string | null;
  action: string;
  resourceType?: string;
  resourceId?: string;
  ip?: string;
  detail?: Record<string, unknown>;
}

export async function audit(entry: AuditEntry): Promise<void> {
  try {
    await query(
      `INSERT INTO audit_log (user_id, action, resource_type, resource_id, ip_addr, detail)
       VALUES ($1, $2, $3, $4, $5::inet, $6)`,
      [
        entry.userId ?? null,
        entry.action,
        entry.resourceType ?? null,
        entry.resourceId ?? null,
        entry.ip ?? null,
        entry.detail ? JSON.stringify(entry.detail) : null,
      ]
    );
  } catch (err) {
    // Never let audit failures break the primary flow
    console.error('[audit] failed to write audit entry:', err);
  }
}

/** Helper to extract the client IP from an Express request. */
export function clientIp(req: { ip?: string; headers: Record<string, unknown> }): string {
  // Behind DigitalOcean's load balancer the real IP is in X-Forwarded-For
  const forwarded = req.headers['x-forwarded-for'];
  if (typeof forwarded === 'string') {
    return forwarded.split(',')[0].trim();
  }
  return req.ip ?? '0.0.0.0';
}
