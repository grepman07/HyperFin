# HyperFin — Tester Onboarding

Quick setup for senior devs testing HyperFin on their own iPhone. Assumes
Xcode 16+, macOS 14+, familiarity with Swift/iOS signing.

## Prerequisites

- Xcode 16+
- iPhone 15 Pro or newer (8 GB RAM — the 3B on-device LLM needs headroom)
- Apple ID (free personal team works; paid team avoids the 7-day re-sign)
- GitHub access to `grepman07/HyperFin` (ping for invite)

## Setup

```bash
git clone git@github.com:grepman07/HyperFin.git
cd HyperFin
open HyperFin.xcodeproj
```

In Xcode → HyperFin target → Signing & Capabilities:

1. Team: your Apple ID (personal or paid)
2. Bundle Identifier: change `com.hyperfin.app` → `com.<yourname>.hyperfin`
   (must be unique per Apple ID)
3. Select your physical device from the run target dropdown
4. ⌘R

First launch on device:
- Settings → General → VPN & Device Management → trust your Apple ID
- App starts downloading the Qwen 2.5 3B model (~1.7 GB, WiFi required,
  2–5 min). Subsequent launches are offline.

## Signing gotcha

Free Apple ID signatures expire after **7 days**. When the app stops
launching, just ⌘R again (rebuild takes ~60 seconds). If you have a paid
Apple Developer account, use that team instead — 1-year validity.

## Backend

The app points to `hyperfin-server-dzlsx.ondigitalocean.app` (shared
DigitalOcean instance). Create your own account via the in-app signup;
your data is isolated by user ID. No server setup needed on your side.

**Plaid sandbox credentials:** any bank → `user_good` / `pass_good`.

## What to test

Primary focus areas in order of priority:

1. **Chat accuracy** — see `docs/CHAT_UAT.md` for 60+ scenarios. The
   ones that matter most right now:
   - Cash balance queries (should report checking + savings, not net worth)
   - Holdings queries ("how much BTC do I have")
   - Retirement balance queries ("my retirement savings") — should NOT
     trigger the OOS refusal
   - Out-of-scope detection (stock picks, market forecasts, retirement
     advice) — should decline honestly
2. **Plaid sandbox flow** — link a bank, verify transactions appear
3. **Tone settings** — Settings → Chat Tone → verify each tone produces
   distinct phrasing
4. **Memory / performance** — after 20+ chat queries, peak RAM should
   stay under 3 GB

## Running tests locally

```bash
cd Packages/HFIntelligence
xcodebuild test -scheme HFIntelligence \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

73 tests, should all pass. 9 integration tests skip on simulator (they
need a physical device for NLEmbedding).

## Architecture at a glance

```
HyperFin (app target)
├── Packages/
│   ├── HFDomain        models + protocols, zero deps
│   ├── HFShared        logging, extensions, constants
│   ├── HFSecurity      Keychain, biometric auth
│   ├── HFData          SwiftData repositories
│   ├── HFNetworking    API client, Plaid SDK
│   └── HFIntelligence  ChatEngine, ToolPlanner, SemanticRouter,
│                       MLX-Swift inference, telemetry
└── Server/             Node.js auth + Plaid relay (runs on DO)
```

Chat pipeline:
```
query → greeting? → semantic router → LLM planner → heuristic fallback
                           ↓              ↓                 ↓
                       execute tools → synthesize reply → stream to UI
```

See `docs/CHAT_ARCHITECTURE.md` for details.

## Reporting bugs

GitHub issues on `grepman07/HyperFin`. Please include:
- Query you sent (if chat-related)
- Expected vs actual response
- Plan source from logs (`semantic` / `llm` / `heuristic` / `unsupported`)
- iPhone model and iOS version
- Screenshot if UI-related

For reproducible cases, a corresponding test in
`Packages/HFIntelligence/Tests/HFIntelligenceTests/` helps enormously.

## Known issues

- First-time model download on flaky WiFi can fail silently; restart the
  app to retry
- Cloud chat opt-in currently hits a Cloudflare worker that's being
  stabilized; if responses stall, disable cloud opt-in in Settings
