import { Router, Request, Response } from 'express';

export const configRouter = Router();

// GET /v1/config
// Returns app configuration, feature flags, and model version info
configRouter.get('/', (_req: Request, res: Response) => {
  res.json({
    version: '1.0.0',
    minimumAppVersion: '1.0.0',
    features: {
      chatEnabled: true,
      budgetAutoGeneration: true,
      anomalyDetection: false, // P1
      cashFlowForecast: false, // P1
      subscriptionTracking: false, // P1
      goalTracking: false, // P1
    },
    ai: {
      primaryModel: 'gemma-4-e4b-it-4bit',
      primaryModelVersion: '1.0.0',
      advancedModel: 'gemma-4-26b-moe-it-4bit',
      advancedModelVersion: '1.0.0',
      modelDownloadBaseURL: 'https://models.hyperfin.app',
    },
    plaid: {
      environment: process.env.PLAID_ENV || 'sandbox',
    },
    maintenance: {
      enabled: false,
      message: null,
    },
  });
});
