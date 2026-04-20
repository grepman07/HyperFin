# HyperFin Chat — User Acceptance Test Plan

**Version:** 1.0
**Last updated:** 2026-04-19
**Target:** Post-architecture refactor (cloud planning bridge, dynamic ontology mapping, semantic router Phase 1)

---

## Purpose

This document drives manual end-to-end testing of the HyperFin chat pipeline
on a physical iOS device. It complements the automated unit and integration
tests in `Packages/HFIntelligence/Tests/HFIntelligenceTests/`, which cover
logic correctness but cannot fully exercise:

1. The real on-device Qwen 2.5 3B model (synthesis quality on realistic prose)
2. Apple's NLEmbedding (only available on real devices, not simulator)
3. End-to-end latency and streaming UI behavior
4. Multi-turn conversation state (slot tracking)
5. Plaid sandbox data integration

Every scenario below has a corresponding automated test in the suite; UAT
verifies that the real-device stack behaves as the unit tests predict.

---

## Pre-flight checklist

Before starting UAT, verify on the test device:

- [ ] Fresh install OR cleared chat history (Settings → Clear chat)
- [ ] Plaid sandbox account linked (credentials: `user_good` / `pass_good`)
- [ ] Sample data seeded (fresh install handles this automatically)
- [ ] On-device model downloaded and loaded (Settings → On-Device AI shows green)
- [ ] Cloud chat opt-in preference set explicitly (see test matrix below)
- [ ] Telemetry opt-in set explicitly (required to verify telemetry scenarios)
- [ ] Device model: iPhone 15 Pro or newer (8+ GB RAM recommended)
- [ ] Network state: tests run in WiFi AND Airplane Mode (see scenarios)

---

## Test matrix — run each scenario in these configurations

| Config | Local model loaded | Cloud opt-in | Network | Expected primary path |
|--------|--------------------|--------------|---------|-----------------------|
| **A** | Yes | No | WiFi | Semantic router → Local LLM → Heuristic |
| **B** | Yes | Yes | WiFi | Semantic router → Cloud LLM → Local LLM → Heuristic |
| **C** | Yes | Yes | Airplane mode | Semantic router → Local LLM → Heuristic |
| **D** | No (not yet downloaded) | No | WiFi | Semantic router → Heuristic → Template |

Scenarios marked **[all configs]** must pass under A, B, C, and D. Scenarios
marked **[config X]** are specific to one row.

---

## 1. Cash balance queries — dynamic ontology verification

**Goal:** Verify `scope` filter pre-filters accounts server-side (tool-side),
so synthesis never mis-interprets "cash balance" as net worth.

### UAT-1.1 — "What is my cash balance?" [all configs]
**Steps:**
1. Open chat
2. Send: `What is my cash balance?`
3. Wait for streaming response

**Expected:**
- Response mentions ONLY checking + savings balances
- Total should equal sum of checking + savings from Plaid sandbox
- Response does NOT mention investment, retirement, or credit accounts
- Response does NOT mention a figure larger than liquid cash (e.g., if net worth = $213K and cash = $55K, response uses $55K)
- Tone matches user's configured tone

**Why this matters:** This was the original bug — the model was calling net worth "cash." Fix verifies the tool pre-filters before the model sees data.

### UAT-1.2 — "How much cash do I have?" [all configs]
Same as 1.1 but with colloquial phrasing. Semantic router should match the
"how much cash do I have" seed exemplar. Plan source in logs should be `semantic`.

### UAT-1.3 — "Did my paycheck land?" [all configs]
Checks semantic router handles novel phrasing that the keyword heuristic
misses. Should route to `account_balance` with `scope=cash`.

### UAT-1.4 — "What is my total balance?" [all configs]
**Expected:**
- Response includes ALL account types (checking, savings, investment, credit, loan)
- Response does NOT use the phrase "cash balance" — it's a total
- Total matches sum across all linked accounts

### UAT-1.5 — "Balance in my Chase account" [all configs]
**Expected:**
- Scoped to one institution
- Shows Chase accounts only
- Response mentions Chase by name

---

## 2. Holdings queries — semantic + ticker extraction

### UAT-2.1 — "How much BTC do I have?" [all configs]
**Steps:**
1. Send: `How much BTC do I have?`

**Expected:**
- Response mentions BTC (Bitcoin) specifically, not other holdings
- Share count and dollar value match the Plaid sandbox BTC position
- Plan JSON in telemetry: `{"tools":[{"name":"holdings_summary","args":{"ticker":"BTC"}}]}`

### UAT-2.2 — "What are my holdings?" [all configs]
**Expected:**
- Summary of portfolio (top holdings, total value, P/L)
- No ticker filter applied

### UAT-2.3 — "My portfolio performance" [all configs]
Semantic router should match the "my portfolio" exemplar.

### UAT-2.4 — "How much AAPL do I own?" [all configs]
Ticker-style question; should route to `holdings_summary(ticker:"AAPL")`.

### UAT-2.5 — "Show positions in my Fidelity account" [all configs]
**Expected:**
- Positions scoped to the Fidelity-linked account
- Uses `holdings_summary(account_name:"fidelity")`

---

## 3. Out-of-scope detection

Every OOS query must produce the canned refusal — the pipeline must NOT
invent financial advice.

### UAT-3.1 — "Is AAPL a good buy?" [all configs]
**Expected:**
- Response: variant of "Crystal ball's in the shop — I can't forecast markets or pick stocks" (funny) or professional equivalent
- No tool execution (confirmed via Settings → Debug → Last plan source: `unsupported`)
- Response length < 250 characters (it's a canned reply)

### UAT-3.2 — "Should I invest in Tesla?" [all configs]

### UAT-3.3 — "Will the market crash next year?" [all configs]

### UAT-3.4 — "How much should I save for retirement?" [all configs]
**Critical:** this was a previously-mis-routed query — must now decline,
not answer with a spending summary.

### UAT-3.5 — "Am I on track for retirement?" [all configs]

### UAT-3.6 — "Should I refinance my mortgage?" [all configs]

---

## 4. Standard query coverage

Each of the 12 tools must be reachable via at least one natural query.

| UAT | Query | Expected tool |
|-----|-------|---------------|
| 4.1 | "How much did I spend on groceries this month?" | `spending_summary` |
| 4.2 | "Am I over budget?" | `budget_status` |
| 4.3 | "Show my recent transactions" | `transaction_search` |
| 4.4 | "Every transaction over $500 this month" | `list_transactions` |
| 4.5 | "Has my food spending been going up?" | `spending_trend` |
| 4.6 | "Any unusual spending this month?" | `spending_anomaly` |
| 4.7 | "What do I owe?" | `liability_report` |
| 4.8 | "What is my net worth?" | `net_worth` |
| 4.9 | "My dividends this year" | `investment_activity` |
| 4.10 | "List my last 10 investment transactions" | `list_investment_transactions` |

For each: verify the correct tool fires (Settings → Debug → Last tool names),
numbers match Plaid sandbox data, and response is well-formed prose.

---

## 5. Cloud planning bridge [config B only]

### UAT-5.1 — Cloud-opted-in query latency
**Steps:**
1. Enable cloud opt-in
2. Send: `What is my cash balance?`
3. Measure time from send tap to first streaming token

**Expected:**
- First token arrives within 2-3 seconds (vs. ~4-5s for local model)
- Plan source in logs: `llm` (produced by cloud Haiku, not on-device Qwen)
- Response quality is noticeably better (more fluent, handles ambiguity)

### UAT-5.2 — Cloud failover to local
**Steps:**
1. Enable cloud opt-in
2. Enable Airplane mode mid-query
3. Send: `What is my cash balance?`

**Expected:**
- Pipeline falls back to local Qwen gracefully
- User sees a response (no error)
- Plan source in logs starts as cloud attempt, logs `Cloud planning failed` warning, then local LLM succeeds

---

## 6. Multi-turn conversation (slot tracking)

### UAT-6.1 — Follow-up with implicit period
**Turn 1:** `How much did I spend on groceries last month?`
**Turn 2:** `What about this month?`

**Expected:**
- Turn 2 recognizes `this month` as a period update for the same category (Groceries)
- Response shows spending on Groceries for this month
- Slot state in ChatEngine: `lastCategory = "Groceries"` carried to turn 2

### UAT-6.2 — Follow-up after greeting clears slots
**Turn 1:** `My food spending this month`
**Turn 2:** `Hi`
**Turn 3:** `What about last month?`

**Expected:**
- Turn 2: empty reply (greeting), slots cleared
- Turn 3: ambiguous — should either ask for clarification or default to overall spending (NOT carry stale "food" category from turn 1 since turn 2 cleared slots)

---

## 7. Memory and performance

### UAT-7.1 — Semantic router cold start latency
**Steps:**
1. Fresh install
2. Open chat immediately after AppDependencies init
3. Send first query

**Expected:**
- Router prewarm completes within 500ms (logged as "SemanticRouter prewarmed" with N/M exemplars)
- First query doesn't block on prewarm (routes via heuristic if prewarm in progress)

### UAT-7.2 — Concurrent loads
**Steps:**
1. Open chat while model is still downloading
2. Send query before model is ready

**Expected:**
- Semantic router handles queries using heuristic fallback
- No crashes, no OOM
- Response uses template fallback if neither router nor model are ready

### UAT-7.3 — Memory after long conversation
**Steps:**
1. Send 20+ back-to-back queries
2. Check Xcode Memory Report / iOS Settings → Battery → App Activity

**Expected:**
- Peak memory < 3 GB (model + embeddings + app overhead)
- No unbounded growth across turns

---

## 8. Telemetry & data flywheel [opt-in configs]

### UAT-8.1 — planJSON capture
**Steps:**
1. Opt into telemetry
2. Send: `What is my cash balance?`
3. Open Settings → Privacy → Telemetry queue (or inspect via SwiftData)

**Expected:**
- One event captured with:
  - `queryAnon = "What is my cash balance?"` (no PII to anonymize)
  - `intent = "account_balance"`
  - `planSource = "semantic"` (or `"llm"` on cloud config)
  - `planJSON` contains the full tool call with `"scope":"cash"`
  - `feedback = nil` initially

### UAT-8.2 — Feedback round-trip
**Steps:**
1. Continue from 8.1
2. Tap thumbs-up on the response
3. Re-inspect telemetry event

**Expected:**
- `feedback = "positive"` on the event
- Event re-queued for upload with updated feedback

### UAT-8.3 — Greeting produces no planJSON
**Steps:**
1. Send: `hi`
2. Inspect telemetry

**Expected:**
- Event saved
- `planSource = "empty"` OR omitted
- `planJSON` is nil or empty string (no waste)

### UAT-8.4 — Opt-out purges local queue
**Steps:**
1. Opt into telemetry, send 3 queries
2. Opt out of telemetry
3. Inspect queue

**Expected:**
- All events purged from SwiftData
- `TelemetryLogger.purgeLocalQueue()` logged

---

## 9. Edge cases

### UAT-9.1 — Empty query
Send just whitespace. Expected: no message sent, input field remains focused.

### UAT-9.2 — Very long query (300+ chars)
Expected: handled gracefully; semantic router may return `uncertain` due to
`textTooLong` → falls through to LLM planner.

### UAT-9.3 — Gibberish ("asdfghjkl qwerty")
Expected: router returns uncertain → LLM planner → either produces a plan or
the final heuristic fails → canned "I don't understand" reply.

### UAT-9.4 — Mixed-language query ("cuanto tengo en mi cuenta")
Expected: NLEmbedding may not handle Spanish well; heuristic won't match;
falls through to LLM; LLM may respond in English with generic help.

### UAT-9.5 — Query during model eviction (low memory)
Expected: pipeline gracefully degrades; template fallback kicks in; no crash.

---

## 10. Regression scenarios

These explicitly cover bugs fixed in prior commits — they must keep passing.

### UAT-10.1 — "How much BTC do I have?" does NOT refuse (was bug 91f8220)
Previously: canned OOS refusal. Now: holdings summary with BTC ticker.

### UAT-10.2 — "What is my cash balance?" does NOT report net worth (was bug 678107a)
Previously: mixed total $213K with $55K cash. Now: only reports cash ($55K) unambiguously.

### UAT-10.3 — "How much should I save for retirement?" does NOT route to spending (was bug 0c18915)
Previously: mis-routed to `spending_summary`. Now: unsupported canned reply.

---

## Sign-off checklist

Tester completes for each release:

- [ ] All UAT-1.x (cash balance / ontology) pass under configs A-D
- [ ] All UAT-2.x (holdings) pass under configs A-D
- [ ] All UAT-3.x (OOS) pass under configs A-D
- [ ] UAT-4.x covers all 12 tools at least once
- [ ] UAT-5.x (cloud bridge) passes under config B
- [ ] UAT-6.x (multi-turn) pass
- [ ] UAT-7.x (memory/performance) pass on target device
- [ ] UAT-8.x (telemetry) pass under opt-in config
- [ ] UAT-9.x (edge cases) produce no crashes
- [ ] UAT-10.x (regressions) all pass

**Sign-off:** _______________________  Date: _______________

---

## Automated test coverage map

Each UAT scenario is backed by one or more automated tests that run in CI:

| UAT Section | Automated tests |
|-------------|-----------------|
| 1.x — Ontology | `AccountBalanceToolTests.testScope_*`, `ChatEnginePipelineTests.test_e2e_cashBalance_*` |
| 2.x — Holdings | Integration tests in `RealSemanticRouterIntegrationTests.test_realRouter_holdings*` |
| 3.x — OOS | `SemanticRouterTests.testRoute_highConfidenceOOS_*`, `ChatEnginePipelineTests.test_e2e_stockAdvice_*` |
| 5.x — Cloud bridge | Logic covered by `ToolPlannerTests` (cloud engine is just another inference backend) |
| 6.x — Multi-turn | Existing `ChatEngine` slot logic |
| 8.x — Telemetry | `ChatEnginePipelineTests.test_chatEngine_recordsPlanJSONForTelemetry`, `TelemetryLoggerTests` |
| 10.x — Regressions | Covered throughout; regression tests added for each original bug |

Run the full suite: `xcodebuild test -scheme HFIntelligence -destination 'platform=iOS Simulator,name=iPhone 17'`
