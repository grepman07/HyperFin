# HyperFin

**AI Finance Coach & Proactive Budget Monitor | On-Device AI | Privacy-First Architecture**

HyperFin is a privacy-first iOS personal finance app powered by on-device AI (Google Gemma 4). All AI inference runs locally on the iPhone — your financial data never leaves your device.

## Architecture

```
iOS App (Swift/SwiftUI)     Minimal Server (Node.js/TS)
├── HFDomain     (models)   ├── Auth (JWT)
├── HFShared     (utils)    ├── Plaid relay (webhook → push)
├── HFSecurity   (enclave)  └── App config
├── HFData       (SwiftData)
├── HFNetworking (API/Plaid)
└── HFIntelligence (Gemma 4 on-device AI)
```

## Key Features

- **NLP Chat**: Ask spending questions in plain English, get instant answers
- **Auto-Categorization**: 3-tier ML pipeline (merchant cache → rules → Gemma 4)
- **Automated Budgets**: AI analyzes spending to suggest personalized budgets
- **Proactive Alerts**: Budget threshold warnings, unusual transactions, weekly summaries
- **100% On-Device AI**: Gemma 4 E4B via MLX-Swift/Core ML — zero cloud AI dependency
- **Bank-Grade Security**: AES-256 (Secure Enclave), Face ID, TLS 1.3

## Requirements

- iOS 17+ / iPhone 15 Pro+
- Xcode 16+
- Swift 6.0+
- Node.js 22+ (server)

## Project Structure

| Package | Purpose |
|---------|---------|
| `HFDomain` | Domain models, protocols, use cases (zero dependencies) |
| `HFShared` | Logging, extensions, constants |
| `HFSecurity` | Biometric auth, Keychain, Secure Enclave encryption |
| `HFData` | SwiftData persistence, repository implementations |
| `HFNetworking` | REST API client, Plaid SDK integration |
| `HFIntelligence` | On-device Gemma 4 inference, chat engine, categorizer |
| `Server/` | Minimal Node.js backend (auth + Plaid relay only) |

## Privacy

HyperFin's privacy guarantee is **architectural, not policy-based**:

- All AI inference runs on-device via Gemma 4
- Financial data is stored only on the iPhone (encrypted with Secure Enclave)
- The backend server handles only auth and Plaid token management
- Zero financial data is stored or processed server-side
