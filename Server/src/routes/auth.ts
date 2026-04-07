import { Router, Request, Response } from 'express';
import { z } from 'zod';

export const authRouter = Router();

const RegisterSchema = z.object({
  email: z.string().email(),
  password: z.string().min(8),
});

const LoginSchema = z.object({
  email: z.string().email(),
  password: z.string(),
});

// POST /v1/auth/register
authRouter.post('/register', async (req: Request, res: Response) => {
  try {
    const { email, password } = RegisterSchema.parse(req.body);

    // TODO: Hash password with bcrypt, insert into users table
    // const hashedPassword = await bcrypt.hash(password, 12);
    // const user = await db.query('INSERT INTO users ...', [email, hashedPassword]);

    // TODO: Generate JWT tokens
    // const accessToken = jwt.sign({ userId: user.id }, process.env.JWT_SECRET!, { expiresIn: '15m' });
    // const refreshToken = jwt.sign({ userId: user.id }, process.env.JWT_REFRESH_SECRET!, { expiresIn: '30d' });

    res.status(201).json({
      accessToken: 'placeholder_access_token',
      refreshToken: 'placeholder_refresh_token',
      expiresIn: 900,
    });
  } catch (error) {
    if (error instanceof z.ZodError) {
      res.status(400).json({ error: 'Invalid input', details: error.errors });
      return;
    }
    res.status(500).json({ error: 'Registration failed' });
  }
});

// POST /v1/auth/login
authRouter.post('/login', async (req: Request, res: Response) => {
  try {
    const { email, password } = LoginSchema.parse(req.body);

    // TODO: Verify credentials against database
    // const user = await db.query('SELECT * FROM users WHERE email = $1', [email]);
    // const valid = await bcrypt.compare(password, user.password_hash);

    res.json({
      accessToken: 'placeholder_access_token',
      refreshToken: 'placeholder_refresh_token',
      expiresIn: 900,
    });
  } catch (error) {
    if (error instanceof z.ZodError) {
      res.status(400).json({ error: 'Invalid input', details: error.errors });
      return;
    }
    res.status(401).json({ error: 'Invalid credentials' });
  }
});

// POST /v1/auth/refresh
authRouter.post('/refresh', async (req: Request, res: Response) => {
  try {
    const { refreshToken } = req.body;
    if (!refreshToken) {
      res.status(400).json({ error: 'Refresh token required' });
      return;
    }

    // TODO: Verify refresh token, issue new pair
    res.json({
      accessToken: 'placeholder_new_access_token',
      refreshToken: 'placeholder_new_refresh_token',
      expiresIn: 900,
    });
  } catch {
    res.status(401).json({ error: 'Invalid refresh token' });
  }
});
