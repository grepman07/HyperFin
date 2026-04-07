import express from 'express';
import cors from 'cors';
import helmet from 'helmet';
import dotenv from 'dotenv';
import { authRouter } from './routes/auth';
import { plaidRouter } from './routes/plaid';
import { configRouter } from './routes/config';
import { webhookRouter } from './routes/webhooks';

dotenv.config();

const app = express();
const PORT = process.env.PORT || 3000;

// Security middleware
app.use(helmet());
app.use(cors({ origin: process.env.ALLOWED_ORIGINS?.split(',') || '*' }));
app.use(express.json());

// Health check
app.get('/health', (_req, res) => {
  res.json({ status: 'ok', service: 'hyperfin-server', version: '1.0.0' });
});

// API routes
app.use('/v1/auth', authRouter);
app.use('/v1/plaid', plaidRouter);
app.use('/v1/config', configRouter);
app.use('/v1/plaid/webhooks', webhookRouter);

// Error handler
app.use((err: Error, _req: express.Request, res: express.Response, _next: express.NextFunction) => {
  console.error('Unhandled error:', err.message);
  res.status(500).json({ error: 'Internal server error' });
});

app.listen(PORT, () => {
  console.log(`HyperFin server running on port ${PORT}`);
  console.log('This server handles ONLY: auth, Plaid relay, config, webhooks');
  console.log('Zero financial data processing. Zero AI inference.');
});

export default app;
