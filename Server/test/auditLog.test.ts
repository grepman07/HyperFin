/**
 * Audit log unit tests. The database layer is mocked so these tests run
 * offline without a PostgreSQL instance.
 */

jest.mock('../src/services/database', () => ({
  query: jest.fn(),
}));

import { audit, clientIp } from '../src/services/auditLog';
import { query } from '../src/services/database';

const mockQuery = query as jest.MockedFunction<typeof query>;

describe('auditLog', () => {
  beforeEach(() => {
    mockQuery.mockReset();
    mockQuery.mockResolvedValue({ rows: [], rowCount: 0 } as any);
  });

  describe('audit()', () => {
    test('writes full entry to audit_log table', async () => {
      await audit({
        userId: 'user-123',
        action: 'plaid_exchange',
        resourceType: 'plaid_item',
        resourceId: 'item-abc',
        ip: '1.2.3.4',
        detail: { institution: 'Chase' },
      });

      expect(mockQuery).toHaveBeenCalledTimes(1);
      const [sql, params] = mockQuery.mock.calls[0];
      expect(sql).toMatch(/INSERT INTO audit_log/);
      expect(params).toEqual([
        'user-123',
        'plaid_exchange',
        'plaid_item',
        'item-abc',
        '1.2.3.4',
        JSON.stringify({ institution: 'Chase' }),
      ]);
    });

    test('handles minimal entry with only action', async () => {
      await audit({ action: 'login_failed' });

      expect(mockQuery).toHaveBeenCalledTimes(1);
      const [, params] = mockQuery.mock.calls[0];
      expect(params).toEqual([null, 'login_failed', null, null, null, null]);
    });

    test('serializes detail object as JSON', async () => {
      await audit({
        action: 'test',
        detail: { nested: { foo: 'bar' }, arr: [1, 2] },
      });

      const [, params] = mockQuery.mock.calls[0];
      expect(params?.[5]).toBe(JSON.stringify({ nested: { foo: 'bar' }, arr: [1, 2] }));
    });

    test('never throws when the database write fails', async () => {
      mockQuery.mockRejectedValueOnce(new Error('db down'));
      // Silence console.error for this test
      const errSpy = jest.spyOn(console, 'error').mockImplementation(() => {});

      await expect(
        audit({ action: 'should_not_throw', userId: 'u1' })
      ).resolves.toBeUndefined();

      errSpy.mockRestore();
    });

    test('does not log the primary operation when audit fails', async () => {
      mockQuery.mockRejectedValueOnce(new Error('db down'));
      const errSpy = jest.spyOn(console, 'error').mockImplementation(() => {});

      await audit({ action: 'test' });

      // Audit should have logged an error internally, but not rethrown
      expect(errSpy).toHaveBeenCalledWith(
        '[audit] failed to write audit entry:',
        expect.any(Error)
      );
      errSpy.mockRestore();
    });

    test('null userId is stored as null, not as string', async () => {
      await audit({ userId: null, action: 'anonymous_event' });
      const [, params] = mockQuery.mock.calls[0];
      expect(params?.[0]).toBeNull();
    });
  });

  describe('clientIp()', () => {
    test('returns first IP from X-Forwarded-For header', () => {
      const req = {
        ip: '10.0.0.1',
        headers: { 'x-forwarded-for': '203.0.113.5, 10.0.0.1, 10.0.0.2' },
      };
      expect(clientIp(req)).toBe('203.0.113.5');
    });

    test('trims whitespace from forwarded header', () => {
      const req = {
        ip: '10.0.0.1',
        headers: { 'x-forwarded-for': '  203.0.113.5  ' },
      };
      expect(clientIp(req)).toBe('203.0.113.5');
    });

    test('falls back to req.ip when no forwarded header', () => {
      const req = { ip: '10.0.0.1', headers: {} };
      expect(clientIp(req)).toBe('10.0.0.1');
    });

    test('returns 0.0.0.0 as final fallback', () => {
      const req = { headers: {} } as any;
      expect(clientIp(req)).toBe('0.0.0.0');
    });

    test('ignores non-string forwarded headers', () => {
      const req = {
        ip: '10.0.0.1',
        headers: { 'x-forwarded-for': ['unexpected-array'] },
      };
      expect(clientIp(req)).toBe('10.0.0.1');
    });
  });
});
