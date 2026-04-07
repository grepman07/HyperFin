import { Request, Response, NextFunction } from 'express';

// JWT authentication middleware
export function requireAuth(req: Request, res: Response, next: NextFunction): void {
  const authHeader = req.headers.authorization;

  if (!authHeader?.startsWith('Bearer ')) {
    res.status(401).json({ error: 'Authorization header required' });
    return;
  }

  const token = authHeader.split(' ')[1];

  try {
    // TODO: Verify JWT token
    // const decoded = jwt.verify(token, process.env.JWT_SECRET!);
    // (req as any).userId = decoded.userId;

    next();
  } catch {
    res.status(401).json({ error: 'Invalid or expired token' });
  }
}
