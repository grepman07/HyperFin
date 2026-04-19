# HyperFin Chat Architecture — Full Technical Review

**Document Version:** 1.0
**Date:** 2026-04-19
**Purpose:** Expert review of the on-device chat pipeline, LLM selection, and custom model evaluation.

---

## Table of Contents

1. [System Overview](#1-system-overview)
2. [Architectural Diagram](#2-architectural-diagram)
3. [Complete Message Lifecycle](#3-complete-message-lifecycle)
4. [Phase 1: Planning — Intent Resolution](#4-phase-1-planning--intent-resolution)
5. [Phase 2: Execution — Tool Dispatch](#5-phase-2-execution--tool-dispatch)
6. [Phase 3: Synthesis — Response Generation](#6-phase-3-synthesis--response-generation)
7. [Model Configuration & Inference Stack](#7-model-configuration--inference-stack)
8. [Prompt Engineering Details](#8-prompt-engineering-details)
9. [Failure Modes & Fallback Strategy](#9-failure-modes--fallback-strategy)
10. [Known Weaknesses & Root Causes](#10-known-weaknesses--root-causes)
11. [LLM Evaluation Matrix](#11-llm-evaluation-matrix)
12. [Custom Model Assessment](#12-custom-model-assessment)
13. [Recommendations](#13-recommendations)
14. [Appendix: All Tool Definitions](#appendix-a-all-tool-definitions)
15. [Appendix: All Prompt Templates](#appendix-b-all-prompt-templates)

---

## 1. System Overview

HyperFin uses a **Plan-Execute-Synthesize** architecture where a single on-device
LLM (Qwen 2.5 3B 4-bit) serves dual duty:

```
  LLM Call #1 (PLAN)     ──>   Structured JSON output   ──>   Tool execution
  LLM Call #2 (SYNTHESIZE) ──>  Streaming natural language  ──>   UI display
```

The same model performs two fundamentally different tasks:
- **Planning:** Structured JSON generation (function-calling / tool selection)
- **Synthesis:** Open-ended natural language generation grounded in data

This dual-use is the source of most reliability issues. Each task has different
optimal model characteristics (see Section 11).

### Key Design Constraints

| Constraint | Impact |
|-----------|--------|
| **On-device only** (default) | Model must fit in ~2 GB, run on iPhone Apple Silicon |
| **Privacy first** | User financial data never leaves device for retrieval |
| **Cloud opt-in** | Optional Claude Haiku path for synthesis only |
| **Real-time streaming** | Response must stream token-by-token for perceived responsiveness |
| **12 tools** | Planner must select from 12 tools with typed arguments |
| **4 tones** | Synthesis must adapt voice (professional/friendly/funny/strict) |

---

## 2. Architectural Diagram

### High-Level Component Map

```
┌─────────────────────────────────────────────────────────────────────┐
│                        HyperFin App (iOS)                          │
│                                                                     │
│  ┌──────────┐    ┌──────────────┐    ┌─────────────────────────┐   │
│  │ ChatView │───>│ChatViewModel │───>│      ChatEngine          │   │
│  │ (SwiftUI)│<───│  (@MainActor)│<───│      (Actor)             │   │
│  │          │    │              │    │                           │   │
│  │ TextField│    │ messages[]   │    │  ┌─────────────────────┐ │   │
│  │ Bubbles  │    │ sendMessage()│    │  │   1. PLAN            │ │   │
│  │ Feedback │    │ streamFrom() │    │  │   ToolPlanner        │ │   │
│  │ Sanitize │    │ persistMsg() │    │  │                      │ │   │
│  └──────────┘    │ telemetry()  │    │  │  isGreeting()        │ │   │
│                  └──────────────┘    │  │  isOutOfScope()      │ │   │
│                                      │  │  LLM plan ──┐       │ │   │
│                                      │  │  heuristic ─┤       │ │   │
│                                      │  │  parse JSON ┘       │ │   │
│  ┌──────────────────────────────┐   │  └────────┬────────────┘ │   │
│  │        SwiftData             │   │           │               │   │
│  │  ┌──────────┐ ┌───────────┐ │   │  ┌────────▼────────────┐ │   │
│  │  │Accounts  │ │Transactions│ │   │  │   2. EXECUTE         │ │   │
│  │  │Holdings  │ │Budgets     │ │   │  │   ToolRegistry       │ │   │
│  │  │Securities│ │Liabilities │ │   │  │                      │ │   │
│  │  │InvTrans  │ │Categories  │ │   │  │  withThrowingTask    │ │   │
│  │  └──────────┘ └───────────┘ │   │  │  Group { parallel }  │ │   │
│  └──────────────────────────────┘   │  │                      │ │   │
│         ▲                           │  │  12 ConcreteTools    │ │   │
│         │ fetch                     │  └────────┬────────────┘ │   │
│         │                           │           │               │   │
│         │                           │  ┌────────▼────────────┐ │   │
│         │                           │  │   3. SYNTHESIZE      │ │   │
│         └───────────────────────────┤  │                      │ │   │
│                                      │  │  PromptAssembler    │ │   │
│                                      │  │       │              │ │   │
│  ┌──────────────────────────────┐   │  │  ┌────▼──────────┐  │ │   │
│  │     Inference Layer          │   │  │  │ Route:         │  │ │   │
│  │                              │   │  │  │ 1. Unsupported │  │ │   │
│  │  ┌────────────────────────┐  │   │  │  │    → canned    │  │ │   │
│  │  │  InferenceEngine       │  │   │  │  │ 2. Cloud       │  │ │   │
│  │  │  (MLX-Swift, on-device)│◄─┼───┤  │  │    → Haiku     │  │ │   │
│  │  │  Qwen 2.5 3B 4-bit    │  │   │  │  │ 3. Local       │  │ │   │
│  │  │  applyChatTemplate     │  │   │  │  │    → Qwen      │  │ │   │
│  │  │  stream tokens         │  │   │  │  │ 4. Template    │  │ │   │
│  │  │  sanitize ChatML       │  │   │  │  │    → hardcoded │  │ │   │
│  │  └────────────────────────┘  │   │  │  └───────────────┘  │ │   │
│  │                              │   │  └─────────────────────┘ │   │
│  │  ┌────────────────────────┐  │   │                           │   │
│  │  │ CloudInferenceEngine   │  │   │  conversationSlots        │   │
│  │  │ (opt-in only)          │◄─┼───┤  (category, merchant,     │   │
│  │  │ Claude Haiku via proxy │  │   │   period, intent)         │   │
│  │  │ /v1/chat/stream        │  │   │                           │   │
│  │  └────────────────────────┘  │   └───────────────────────────┘   │
│  │                              │                                   │
│  │  ┌────────────────────────┐  │                                   │
│  │  │ ModelManager           │  │                                   │
│  │  │ download / load / evict│  │                                   │
│  │  │ status tracking        │  │                                   │
│  │  └────────────────────────┘  │                                   │
│  └──────────────────────────────┘                                   │
└─────────────────────────────────────────────────────────────────────┘
```

### LLM Call Pattern

```
                    Query: "What is my cash balance?"
                                │
            ┌───────────────────┴───────────────────┐
            │                                       │
     LLM CALL #1 (PLAN)                     LLM CALL #2 (SYNTH)
     temp=0.1, max=300 tok                   temp=0.6, max=512 tok
     ┌──────────────────┐                    ┌──────────────────────┐
     │ System: planner  │                    │ System: finance coach│
     │ role + catalog   │                    │ + tone + terminology │
     │                  │                    │                      │
     │ User: raw query  │                    │ User: query +        │
     │                  │                    │ {"account_balance":  │
     │ Asst: {"tools":[ │                    │  {"accounts":[...],  │
     │  (prime)         │                    │   "total":"$213K"}}  │
     └────────┬─────────┘                    └──────────┬───────────┘
              │                                         │
              ▼                                         ▼
     {"name":"account_balance",              "Your cash balance across
      "args":{}}                              checking and savings is
                                              $55,370.00..."
              │
              ▼
     ┌─────────────────┐
     │ AccountBalance  │
     │ Tool.execute()  │
     │ SwiftData fetch │
     └────────┬────────┘
              │
              ▼
     AccountBalanceResult {
       accounts: [
         {name, type:"checking", inst, bal},
         {name, type:"savings", inst, bal},
         {name, type:"investment", inst, bal}
       ],
       total_balance: "$213,535.80"
     }
```

---

## 3. Complete Message Lifecycle

### Pseudocode: Full Path

```
USER TAPS SEND ("What is my cash balance?")
│
├── ChatView
│   └── chatViewModel.sendMessage()
│
├── ChatViewModel.sendMessage()                    // @MainActor
│   ├── text = inputText.trim()
│   ├── inputText = ""                             // clear input field
│   ├── remove welcome bubble if present
│   ├── append ChatMessageUI(text, isUser=true)    // show in UI immediately
│   ├── persistMessage(id, text, isUser=true)      // SwiftData write (crash-safe)
│   ├── append ChatMessageUI("", isUser=false, isStreaming=true)  // placeholder
│   ├── load UserProfile from SwiftData            // for chatTone, cloudOptIn
│   ├── context = ChatContext(sessionId, recentMessages=suffix(4), userProfile)
│   │
│   └── Task {
│       └── for try await token in engine.sendMessage(text, context):
│           ├── messages[responseIdx].content = token.sanitizedForDisplay
│           └── // real-time UI update via @Observable
│       └── on completion:
│           ├── final sanitize pass
│           ├── isStreaming = false
│           ├── persistMessage(responseId, finalContent, isUser=false)
│           └── logTelemetry(query, responseId, latencyMs, toolNames)
│       }
│
├── ChatEngine.sendMessage(text, context)           // Actor-isolated
│   ├── _lastToolNames = []
│   │
│   ├── // ═══════════════════════════════════════
│   ├── // PHASE 1: PLAN
│   ├── // ═══════════════════════════════════════
│   ├── modelLoaded = await modelManager.isLoaded
│   ├── plan = await planner.plan(
│   │       query: text,
│   │       slots: conversationSlots,
│   │       registry: registry,
│   │       inferenceEngine: inferenceEngine,
│   │       modelLoaded: modelLoaded
│   │   )
│   │   │
│   │   ├── IF isGreeting(text):
│   │   │   └── RETURN Plan(calls=[], source=.empty)
│   │   │
│   │   ├── IF isOutOfScope(text):
│   │   │   └── RETURN Plan(calls=[], source=.unsupported)
│   │   │
│   │   ├── IF NOT modelLoaded:
│   │   │   ├── heuristic = heuristicPlan(text)
│   │   │   │   ├── keyword match → ToolCall    // "balance" → account_balance
│   │   │   │   ├── ticker extract → holdings   // "BTC" → holdings_summary(ticker)
│   │   │   │   └── no match → []
│   │   │   └── RETURN heuristic.isEmpty
│   │   │       ? Plan([], .unsupported)        // ← aggressive: empty=refusal
│   │   │       : Plan(heuristic, .heuristic)
│   │   │
│   │   ├── // LLM PLANNING PATH
│   │   ├── catalog = registry.catalogText()     // dynamic tool descriptions
│   │   ├── messages = assemblePlannerPrompt(text, slots, catalog)
│   │   ├── request = InferenceRequest(
│   │   │       messages,
│   │   │       maxTokens = 300,                 // 100 * 3 multiplier
│   │   │       temperature = 0.1                // near-deterministic
│   │   │   )
│   │   ├── raw = inferenceEngine.generateComplete(request)
│   │   ├── // Strip <think>...</think> tags (Qwen sometimes emits these)
│   │   ├── // Prepend {"tools":[ (we primed assistant with this)
│   │   ├── parsed = parsePlan(raw, whitelist=registry.toolNames())
│   │   │   │
│   │   │   ├── TIER 1: Full JSON parse
│   │   │   │   ├── Find balanced {…} slice
│   │   │   │   ├── JSONSerialization decode
│   │   │   │   ├── Extract tools array
│   │   │   │   ├── Validate names against whitelist
│   │   │   │   └── Map args via ToolArgValue.from(any:)
│   │   │   │
│   │   │   ├── TIER 2: Regex scrape (malformed JSON)
│   │   │   │   ├── Match "name":"<tool>" patterns
│   │   │   │   ├── Extract adjacent "args":{...} blocks
│   │   │   │   └── Best-effort key/value extraction
│   │   │   │
│   │   │   └── TIER 3: Return [] (both tiers failed)
│   │   │
│   │   ├── IF parsed.nonEmpty:
│   │   │   └── RETURN Plan(parsed, .llm)        // success
│   │   │
│   │   └── // LLM FAILED → heuristic fallback
│   │       ├── heuristic = heuristicPlan(text)
│   │       └── RETURN heuristic.isEmpty
│   │           ? Plan([], .unsupported)
│   │           : Plan(heuristic, .heuristic)
│   │
│   ├── log("Plan[{source}]: {toolNames}")
│   │
│   ├── // ═══════════════════════════════════════
│   ├── // PHASE 2: EXECUTE
│   ├── // ═══════════════════════════════════════
│   ├── results = executeAll(plan.calls)
│   │   │
│   │   ├── IF calls.isEmpty: RETURN []
│   │   │
│   │   └── withThrowingTaskGroup {
│   │       ├── for (idx, call) in calls.enumerated():
│   │       │   group.addTask {
│   │       │       result = registry.execute(call)
│   │       │       // ToolRegistry looks up Tool by name
│   │       │       // Calls tool.execute(args, repos)
│   │       │       // Tool reads from SwiftData repos
│   │       │       // Returns typed ToolResult
│   │       │       return (idx, result)           // preserve order
│   │       │   }
│   │       │
│   │       └── collect, sort by idx, return results
│   │       // Individual tool failures logged + dropped (don't sink turn)
│   │   }
│   │
│   ├── _lastToolNames = results.map(\.toolName)
│   │
│   ├── // ═══════════════════════════════════════
│   ├── // PHASE 3: SYNTHESIZE
│   ├── // ═══════════════════════════════════════
│   ├── tone = context.userProfile?.chatTone ?? .professional
│   ├── cloudOptIn = context.userProfile?.cloudChatOptIn ?? false
│   │
│   ├── IF plan.source == .unsupported:
│   │   ├── yield unsupportedReply(tone)           // canned, no LLM
│   │   └── RETURN
│   │
│   ├── messages = promptAssembler.assembleSynthesisPrompt(
│   │       userQuery: text,
│   │       toolResults: results,
│   │       conversationHistory: context.recentMessages,
│   │       tone: tone
│   │   )
│   │   // System: role + rules + terminology + tone
│   │   // History: last 2 messages (context)
│   │   // User: "{query}\n\nHere is the data:\n{JSON}"
│   │
│   ├── localRequest = InferenceRequest(messages: messages)
│   ├── cloudRequest = InferenceRequest(prompt: localRequest.prompt)
│   │                                   // flattened [System]\n...\n[User]\n...
│   │
│   ├── ROUTE 1: Cloud (opted-in)
│   │   ├── IF cloudOptIn AND cloudEngine != nil:
│   │   │   ├── for try await token in cloudEngine.generate(cloudRequest):
│   │   │   │   └── yield token                    // stream to UI
│   │   │   ├── on success: RETURN
│   │   │   └── on error: log, FALL THROUGH to local
│   │
│   ├── ROUTE 2: Local (model loaded)
│   │   ├── IF modelManager.isLoaded:
│   │   │   ├── for try await token in inferenceEngine.generate(localRequest):
│   │   │   │   │
│   │   │   │   │  // Inside InferenceEngine:
│   │   │   │   │  // 1. Map StructuredMessage → MLX Chat.Message
│   │   │   │   │  // 2. container.prepare(UserInput(chat: messages))
│   │   │   │   │  //    → applyChatTemplate (Qwen ChatML format)
│   │   │   │   │  //    → tokenize
│   │   │   │   │  // 3. container.generate(input, parameters)
│   │   │   │   │  //    → stream chunks
│   │   │   │   │  // 4. Accumulate fullText
│   │   │   │   │  // 5. Check stop tokens (<|im_end|>, <|endoftext|>)
│   │   │   │   │  // 6. Sanitize (strip markers, suppress partial tails)
│   │   │   │   │
│   │   │   │   └── yield sanitized token          // stream to UI
│   │   │   └── RETURN
│   │
│   ├── ROUTE 3: Template fallback (no model, no cloud)
│   │   ├── IF results.isEmpty:
│   │   │   └── yield defaultTemplateReply(query, tone)
│   │   └── ELSE:
│   │       └── yield results.map(\.templateResponse(tone)).joined("\n\n")
│   │       // Each ToolResult has 4 tone-aware pre-written responses
│   │
│   ├── absorbSlotsFrom(plan)                      // update multi-turn state
│   └── continuation.finish()
│
└── DONE — user sees streaming response in chat bubble
```

---

## 4. Phase 1: Planning — Intent Resolution

### The Planner's Job

Convert a natural-language question into a JSON array of typed tool calls.

### Decision Tree

```
                        User Query
                            │
                    ┌───────▼────────┐
                    │  isGreeting?   │──── YES ──→ Plan([], .empty)
                    │  (< 30 chars,  │              │
                    │   starts with  │              └─→ ChatEngine yields
                    │   hi/hello/hey │                  defaultTemplateReply()
                    │   thanks, etc.)│
                    └───────┬────────┘
                            │ NO
                    ┌───────▼────────┐
                    │ isOutOfScope?  │──── YES ──→ Plan([], .unsupported)
                    │ (retirement,   │              │
                    │  401k, s&p,    │              └─→ ChatEngine yields
                    │  should i buy, │                  unsupportedReply(tone)
                    │  forecast,     │                  "Crystal ball's in
                    │  stock advice) │                   the shop..."
                    └───────┬────────┘
                            │ NO
                    ┌───────▼────────┐
                    │ Model loaded?  │──── NO ──→ heuristicPlan(query)
                    │                │              │
                    └───────┬────────┘              ├─ keyword match → Plan(.heuristic)
                            │ YES                   └─ no match → Plan([], .unsupported)
                    ┌───────▼────────┐
                    │  LLM Plan      │
                    │  (Qwen 2.5 3B) │
                    │  temp=0.1      │
                    │  max=300 tok   │
                    └───────┬────────┘
                            │
                    ┌───────▼────────┐
                    │ Parse JSON     │
                    │ Tier 1: Full   │──── OK ──→ Plan(calls, .llm)
                    │ Tier 2: Regex  │──── OK ──→ Plan(calls, .llm)
                    │ Tier 3: Fail   │──── FAIL ─→ heuristicPlan(query)
                    └────────────────┘              │
                                                    ├─ match → Plan(.heuristic)
                                                    └─ empty → Plan([], .unsupported)
```

### Heuristic Keyword Map (fallback when model unavailable)

| Keywords | Tool | Args |
|----------|------|------|
| net worth, how much am i worth, my assets, how rich | `net_worth` | — |
| owe, debt, liabilities, credit card, mortgage, student loan | `liability_report` | kind? |
| holdings, portfolio, stocks, brokerage, investments, crypto, bitcoin, ethereum | `holdings_summary` | — |
| (uppercase 1-5 letter word, not stop word) | `holdings_summary` | ticker |
| dividend | `investment_activity` | activity_type=dividend |
| trade, buy, sell | `investment_activity` | — |
| budget, over/under budget | `budget_status` | — |
| balance, checking, savings account | `account_balance` | — |
| trend, over time, changed | `spending_trend` | — |
| unusual, spike, higher than usual | `spending_anomaly` | — |
| spend, spent, cost, expense | `spending_summary` | — |
| *(no match)* | *(empty → .unsupported)* | — |

### Known Planning Failures

| Query | Expected | Actual | Root Cause |
|-------|----------|--------|------------|
| "How much BTC do I have?" | `holdings_summary(ticker:BTC)` | `.unsupported` refusal | **Fixed:** no crypto keywords in heuristic |
| "What is my cash balance?" | `account_balance` | `account_balance` (correct plan, wrong synthesis) | Model conflated total with "cash" — **Fixed:** added type field + prompt rules |
| "M CT s get see irgrid" | `.unsupported` or `.empty` | `.unsupported` | Correct behavior — gibberish |
| "How much should I save for retirement?" | `.unsupported` | Was routing to `spending_summary` | **Fixed:** OOS detector + removed "how much" from heuristic |

---

## 5. Phase 2: Execution — Tool Dispatch

### Execution Model

```
Plan: [ToolCall("account_balance", {}), ToolCall("spending_summary", {category:"Food"})]
                    │                                         │
                    └────────────────┬────────────────────────┘
                                     │
                    withThrowingTaskGroup(of: (Int, ToolResult?))
                                     │
                    ┌────────────────┼────────────────┐
                    │                │                │
              Task (idx=0)     Task (idx=1)     ... (parallel)
                    │                │
            ToolRegistry        ToolRegistry
            .execute(call)      .execute(call)
                    │                │
           AccountBalance      SpendingAgg
           Tool.execute()      Tool.execute()
                    │                │
           SwiftData repos     SwiftData repos
                    │                │
           AccountBalance      SpendAggregate
           Result              Result
                    │                │
                    └────────┬───────┘
                             │
                    Sort by original index
                             │
                    [AccountBalanceResult, SpendAggregateResult]
```

### Tool Registry

All 12 tools are registered at app startup in `ToolRegistry.init()`. Each tool
conforms to the `Tool` protocol:

```swift
protocol Tool: Sendable {
    var name: String { get }
    var description: String { get }
    var argsSignature: String { get }
    func execute(args: [String: ToolArgValue], repos: ToolRepos) async throws -> any ToolResult
}
```

The registry generates the **catalog text** dynamically for the planner prompt:

```
- spending_summary(category?: string, merchant?: string, period?: string): Aggregate spending...
- budget_status(category?: string): Compare actual vs. monthly budget...
- account_balance(account_name?: string): Return balances for linked cash/credit accounts...
...
```

### ToolResult Protocol

Every tool returns a typed result conforming to:

```swift
protocol ToolResult: Sendable {
    var toolName: String { get }
    func toJSON() -> String          // pre-formatted currency, human-readable dates
    func templateResponse(tone: ChatTone) -> String   // fallback when no LLM available
}
```

**Critical design choice:** Money values are pre-formatted as strings (`"$1,234.56"`)
inside `toJSON()`, not raw numbers. This means the synthesis model only needs to
*copy* dollar amounts, never format them. This eliminates a class of errors where
small models produce `$1234.56` or `1,234.56` or `$1234.5600`.

---

## 6. Phase 3: Synthesis — Response Generation

### Synthesis Routing

```
                    ToolResults[]
                         │
                ┌────────▼────────┐
                │ plan.source ==  │──── YES ──→ yield unsupportedReply(tone)
                │ .unsupported?   │              (no LLM call, zero cost)
                └────────┬────────┘
                         │ NO
                ┌────────▼────────┐
                │ Build synthesis │
                │ prompt with     │
                │ PromptAssembler │
                └────────┬────────┘
                         │
                ┌────────▼────────┐
                │ cloudOptIn AND  │──── YES ──→ CloudInferenceEngine
                │ cloudEngine?    │              │
                └────────┬────────┘              ├── stream from /v1/chat/stream
                         │ NO                    ├── on success: RETURN
                ┌────────▼────────┐              └── on error: FALL THROUGH ↓
                │ model loaded?   │──── YES ──→ InferenceEngine (local MLX)
                │                 │              │
                └────────┬────────┘              ├── StructuredMessage → Chat.Message
                         │ NO                    ├── applyChatTemplate (ChatML)
                ┌────────▼────────┐              ├── MLX generate stream
                │ Template        │              ├── stop token detection
                │ fallback        │              └── sanitize (strip markers)
                │                 │
                │ results.map {   │
                │   $0.template   │
                │   Response(tone)│
                │ }.joined("\n\n")│
                └─────────────────┘
```

### Message Assembly for Synthesis

```
┌───────────────────────────────────────────────────────────────────┐
│ StructuredMessage.system                                         │
│                                                                   │
│  "You are HyperFin, a personal finance coach.                    │
│   ...                                                             │
│   Each account has a "type" field. Use it to answer precisely:   │
│   - "Cash balance" = only accounts typed "checking" or "savings" │
│   - "Credit" accounts are liabilities, not cash.                 │
│   - "Investment" accounts hold securities — not liquid cash.     │
│   ...                                                             │
│   Be professional and clear.                                      │
│   Keep responses short (2-4 sentences)."                          │
└───────────────────────────────────────────────────────────────────┘
┌───────────────────────────────────────────────────────────────────┐
│ StructuredMessage.user (recent history msg 1, if any)            │
│ StructuredMessage.assistant (recent history msg 2, if any)       │
└───────────────────────────────────────────────────────────────────┘
┌───────────────────────────────────────────────────────────────────┐
│ StructuredMessage.user                                           │
│                                                                   │
│  "What is my cash balance?                                        │
│                                                                   │
│   Here is the data:                                               │
│   {"account_balance":{"accounts":[                                │
│     {"name":"Checking","type":"checking","institution":"Chase",   │
│      "balance":"$110.00"},                                        │
│     {"name":"Savings","type":"savings","institution":"Chase",     │
│      "balance":"$210.00"},                                        │
│     {"name":"401k","type":"investment","institution":"Vanguard",  │
│      "balance":"$158,000.00"}                                     │
│   ],"total_balance":"$158,320.00"}}"                              │
└───────────────────────────────────────────────────────────────────┘
```

### Token Flow: InferenceEngine → UI

```
InferenceEngine.generate(request)
  │
  ├── Map [StructuredMessage] → [Chat.Message]
  │     .system(content) → .system(content)
  │     .user(content)   → .user(content)
  │     .assistant(content) → .assistant(content)
  │
  ├── container.prepare(UserInput(chat: messages))
  │     → applyChatTemplate (Qwen ChatML format):
  │
  │     <|im_start|>system
  │     You are HyperFin, a personal finance coach...
  │     <|im_end|>
  │     <|im_start|>user
  │     What is my cash balance?
  │
  │     Here is the data:
  │     {"account_balance":{...}}
  │     <|im_end|>
  │     <|im_start|>assistant
  │
  ├── container.generate(lmInput, parameters)
  │     → stream of Generation.chunk(text)
  │
  ├── For each chunk:
  │     ├── accumulate into fullText
  │     ├── check for stop tokens in fullText
  │     │     <|im_end|> or <|endoftext|>
  │     ├── IF stop token found:
  │     │     truncate at stop boundary, yield, break
  │     └── ELSE:
  │           sanitize(fullText, config)
  │           └── strip fully-formed markers
  │           └── suppress trailing partial prefix
  │           yield sanitized copy
  │
  └── Final belt-and-suspenders yield if stream ended naturally
        │
        ▼
  ChatViewModel receives cumulative token
  │
  ├── .sanitizedForDisplay (UI-layer regex)
  │     ├── remove <|...|> markers (regex: <\|[^|]*\|>)
  │     ├── remove trailing partial <|... (regex: <\|[\w|]*$)
  │     └── trim whitespace
  │
  └── Update chat bubble content → SwiftUI re-render
```

---

## 7. Model Configuration & Inference Stack

### Current Model: Qwen 2.5 3B Instruct (4-bit)

| Property | Value |
|----------|-------|
| **HuggingFace ID** | `mlx-community/Qwen2.5-3B-Instruct-4bit` |
| **Parameters** | 3 billion |
| **Quantization** | 4-bit (W4A16) |
| **Download size** | ~1.7 GB |
| **Framework** | MLX-Swift (Metal Performance Shaders on Apple Silicon) |
| **Chat template** | ChatML (`<\|im_start\|>role\ncontent<\|im_end\|>`) |
| **GPU cache limit** | 512 MB |
| **Min available memory** | 1024 MB |

### Inference Parameters

| Parameter | Planning | Synthesis | Receipt Parsing |
|-----------|----------|-----------|-----------------|
| **Temperature** | 0.1 | 0.6 | 0.1 |
| **Max tokens** | 300 | 512 | 256 |
| **Purpose** | Near-deterministic JSON | Creative natural language | Factual extraction |

### Cloud Fallback: Claude Haiku

| Property | Value |
|----------|-------|
| **Model** | Claude Haiku (via server proxy) |
| **Endpoint** | `/v1/chat/stream` on DigitalOcean |
| **Activation** | User opt-in (`cloudChatOptIn`) |
| **Data sent** | Flattened prompt string only |
| **Used for** | Synthesis only (planning is always local) |
| **Timeout** | 60 seconds |

### Key Observation: Cloud is Synthesis-Only

```
                  PLANNING          EXECUTION          SYNTHESIS
                     │                  │                  │
  Local model:    ✅ Always          N/A (code)        ✅ Default
  Cloud model:    ❌ Never           N/A (code)        ✅ Opt-in
  Template:       N/A                N/A               ✅ Last resort
  Heuristic:      ✅ Fallback        N/A               N/A
```

**Planning is NEVER cloud-assisted.** If the local model is unavailable, planning
falls back to the keyword heuristic, which has limited coverage.

---

## 8. Prompt Engineering Details

### Planner Prompt Structure

```
SYSTEM:
  "You are the planner for a personal finance assistant."
  + Tool catalog (12 tools, dynamically rendered)
  + JSON output format: {"tools":[{"name":"...","args":{...}}]}
  + Rules:
    - JSON only, no prose
    - Multiple tools allowed
    - Don't invent args
    - Return {"tools":[]} for greetings/out-of-scope
    - Use exact tool names
  + Period vocabulary (today, this_week, this_month, etc.)
  + Category vocabulary (Food & Dining, Transportation, etc.)
  + 9 few-shot examples
  + Slot context from previous turn (if any)

USER:
  Raw query text

ASSISTANT (prime):
  {"tools":[
```

### Synthesis Prompt Structure

```
SYSTEM:
  "You are HyperFin, a personal finance coach."
  + Data grounding rules (only use figures from data, never invent)
  + Currency copy rules (copy $X,XXX.XX verbatim)
  + Account type terminology (cash = checking+savings only)
  + Zero-data guidance
  + Out-of-scope fallback (for queries that slip past planner)
  + Tone instruction (1 of 4)
  + Length constraint (2-4 sentences)
  + Anti-hallucination rules

CONVERSATION HISTORY (suffix of 2):
  user: <previous question>
  assistant: <previous answer>

USER:
  {query}

  Here is the data:
  {"tool_name_1": {...}, "tool_name_2": {...}}
```

### Prompt Token Budget (estimated)

| Component | ~Tokens | Notes |
|-----------|---------|-------|
| Planner system prompt | ~800 | Tool catalog is the bulk |
| Planner few-shot examples | ~400 | 9 examples |
| Planner user query | ~20 | Short natural language |
| **Total planner input** | **~1,220** | |
| Planner max output | 300 | |
| | | |
| Synthesis system prompt | ~250 | Rules + tone |
| Synthesis conversation history | ~200 | Last 2 messages |
| Synthesis user + data block | ~200-800 | Depends on tool result size |
| **Total synthesis input** | **~650-1,250** | |
| Synthesis max output | 512 | |

---

## 9. Failure Modes & Fallback Strategy

### Failure Cascade

```
                    User Query
                         │
              ┌──────────▼──────────┐
              │  PLAN: LLM attempt  │
              │  (Qwen 2.5, local)  │
              └──────────┬──────────┘
                         │
            ┌────────────┼────────────┐
         SUCCESS       PARSE FAIL   MODEL NOT LOADED
            │              │              │
     Plan(.llm)    ┌──────▼──────┐  ┌───▼────────┐
                   │  Heuristic  │  │  Heuristic  │
                   │  fallback   │  │  fallback   │
                   └──────┬──────┘  └───┬────────┘
                          │             │
                   ┌──────┼──────┐  ┌───┼────────┐
                MATCH    EMPTY   MATCH  EMPTY
                   │       │       │       │
            Plan(.heur) Plan(.unsup) Plan(.heur) Plan(.unsup)
                   │       │       │       │
                   ▼       ▼       ▼       ▼
              EXECUTE   CANNED  EXECUTE  CANNED
                   │    REPLY      │     REPLY
                   ▼               ▼
              SYNTHESIZE       SYNTHESIZE
                   │               │
            ┌──────┼──────┐  ┌─────┼──────┐
         CLOUD  LOCAL  TMPL  CLOUD LOCAL TMPL
```

### Failure Mode Inventory

| Failure | Frequency | Impact | Current Mitigation |
|---------|-----------|--------|--------------------|
| LLM emits invalid JSON | Medium | Falls to heuristic, may lose args | 3-tier parser (JSON → regex → fail) |
| LLM picks wrong tool | Low-Medium | Wrong data shown to user | Few-shot examples in prompt |
| LLM invents args | Low | Filter applied that returns no data | Prompt says "don't invent" |
| Heuristic misses valid query | Medium | Canned refusal for answerable question | Keyword list is manually maintained |
| OOS detector false positive | **High** (observed) | Legitimate query refused | Keyword list too broad |
| Synthesis hallucinates numbers | Low | User sees fake financial data | "Only use figures from data" rule |
| Synthesis misinterprets data | **Medium** (observed) | Wrong interpretation (cash=net worth) | Added type field + terminology rules |
| Model not loaded (cold start) | First launch | Heuristic-only planning | Template fallback for synthesis |
| Cloud timeout | Rare | Falls to local model | Try/catch with fallback |
| Tool execution error | Rare | Dropped from results, may cause empty data | Individual try/catch per tool |
| Token leak (<\|im_end\|>) | Rare | Raw markers visible in UI | 2-layer sanitization |

---

## 10. Known Weaknesses & Root Causes

### Weakness 1: The LLM Does Two Very Different Jobs

The same Qwen 2.5 3B model handles:
- **Planning:** Structured JSON output, near-deterministic, must follow schema exactly
- **Synthesis:** Creative natural language, must ground in data, must follow tone

These tasks have **conflicting optimal parameters:**

| Characteristic | Planning Needs | Synthesis Needs |
|----------------|---------------|-----------------|
| Temperature | 0.0-0.1 (deterministic) | 0.5-0.7 (varied) |
| Output format | Strict JSON schema | Free-form prose |
| Creativity | None (harmful) | Moderate (helpful) |
| Grounding | Tool catalog only | Data + rules + tone |
| Failure cost | Broken pipeline | Bad user experience |
| Ideal model size | Smaller is fine | Larger is better |

### Weakness 2: Heuristic Fallback is a Maintenance Treadmill

Every new query pattern requires manually adding keywords. The BTC and crypto
queries failing are symptoms of an inherently incomplete keyword list. The
heuristic currently covers ~15 keyword groups for 12 tools — any natural phrasing
outside those groups gets classified as `.unsupported`.

### Weakness 3: OOS Detection is Keyword-Based, Not Semantic

The `isOutOfScope` function uses `string.contains()` on ~25 phrases. This causes:
- **False positives:** "How much BTC do I have?" if "btc" were added to the OOS list
- **False negatives:** "What will the market do?" (no exact phrase match)
- **Fragile to phrasing:** "Tell me if Tesla is worth buying" dodges all patterns

### Weakness 4: Planning Never Uses Cloud

Even when the user has opted into cloud chat, planning is always local or
heuristic. A cloud-assisted planning path could use Claude Haiku (which is
excellent at structured JSON output) to produce reliable plans when the local
model struggles.

### Weakness 5: Synthesis Prompt Carries Too Much Corrective Guidance

The system prompt has grown to include specific terminology rules (cash =
checking + savings), zero-data handling, OOS fallback wording, and tone
instructions. Each rule was added to fix a specific misinterpretation by the
3B model. A larger or fine-tuned model would need fewer corrective patches.

### Weakness 6: Two-Turn LLM Pattern is Expensive

Every user query makes **two LLM calls** (plan + synthesize). On device, this
means ~2x latency. The planning call alone takes 1-3 seconds on an iPhone,
adding perceived lag before the streaming response even starts.

---

## 11. LLM Evaluation Matrix

### Models Under Consideration

| Model | Params | Quant | Size | Planning | Synthesis | Latency | Notes |
|-------|--------|-------|------|----------|-----------|---------|-------|
| **Qwen 2.5 3B** (current) | 3B | 4-bit | 1.7 GB | Fair | Fair | ~2s plan, ~5s synth | Current production model |
| Qwen 2.5 1.5B | 1.5B | 4-bit | ~0.9 GB | Poor | Poor | ~1s plan, ~3s synth | Too small for reliable JSON |
| Qwen 2.5 7B | 7B | 4-bit | ~4 GB | Good | Good | ~4s plan, ~10s synth | May strain older iPhones |
| Qwen 3 4B | 4B | 4-bit | ~2.2 GB | Good | Good | ~2.5s plan, ~6s synth | Newer architecture, better JSON |
| Gemma 2 2B | 2.6B | 4-bit | ~1.5 GB | Fair | Fair | ~2s plan, ~5s synth | Different chat template |
| Phi-3.5 Mini | 3.8B | 4-bit | ~2.1 GB | Good | Fair | ~2.5s plan, ~6s synth | Strong at structured output |
| SmolLM2 1.7B | 1.7B | 4-bit | ~1 GB | Poor | Poor | Fast | Too small |
| **Claude Haiku** (cloud) | N/A | N/A | N/A | Excellent | Excellent | ~1-2s (network) | Requires connectivity + opt-in |

### Evaluation Criteria

| Criterion | Weight | Why |
|-----------|--------|-----|
| **JSON reliability** (planning) | 30% | A broken plan cascades to wrong tool → wrong data → wrong answer |
| **Data grounding** (synthesis) | 25% | Must not invent numbers; must interpret types/categories correctly |
| **On-device size** | 15% | Must fit in ~2-4 GB with room for the app |
| **Latency** | 15% | Two LLM calls already double the wait; can't be 10s+ each |
| **Instruction following** | 10% | Tone, length, format rules must be respected |
| **Availability** | 5% | Must run on MLX-Swift (Apple Silicon) |

---

## 12. Custom Model Assessment

### Do We Need a Custom Model?

**Short answer:** Probably not a fully custom model, but a **task-specific fine-tune**
of an existing model could solve the planning reliability problem at lower cost
than building from scratch.

### Option A: Fine-Tuned Planner (Recommended to Evaluate)

**What:** Take Qwen 2.5 3B (or 1.5B) and fine-tune on a dataset of
(user_query → tool_call_JSON) pairs specific to HyperFin's 12 tools.

**Training data:** ~2,000-5,000 examples covering:
- All 12 tools with varied natural language
- Multi-tool queries (net worth + spending)
- Edge cases (crypto tickers, mixed intent)
- OOS queries with empty output
- Follow-up queries using conversation slots

**Expected improvement:**
- JSON output reliability: ~95%+ (vs current ~80-85%)
- Correct tool selection: ~95%+ (vs current ~85-90%)
- OOS detection: Built into the model's training data (vs brittle keyword list)
- Could potentially use a **smaller** model (1.5B) with fine-tuning = faster planning

**Cost:** ~$50-200 for training compute (LoRA/QLoRA on consumer GPU or cloud).
2-4 weeks of data collection + iteration.

**Risk:** Training data must be maintained as tools change. Drift over time.

### Option B: Two Separate Models

**What:** Use a small, fast model for planning (e.g., fine-tuned Qwen 1.5B)
and keep or upgrade the synthesis model (Qwen 3B or 7B).

**Expected improvement:**
- Planning: Much faster (smaller model) + more reliable (fine-tuned)
- Synthesis: Better quality if upgraded to 7B
- Total latency could decrease despite two models (1.5B plans in <1s)

**Cost:** Two models on device = ~2.5-5 GB total storage. More complex
model management. But memory usage is sequential, not concurrent.

### Option C: Hybrid Cloud Planning

**What:** Route planning through Claude Haiku (cloud) when available, fall back
to local heuristic when offline. Keep synthesis local or cloud per user preference.

**Expected improvement:**
- Planning reliability: Near-perfect (Haiku is excellent at structured output)
- No heuristic maintenance needed when online
- Latency: ~200ms for planning (fast API call) vs ~2s local

**Cost:** Requires network connectivity for best experience. Additional API cost
(Haiku is cheap: ~$0.001 per plan call). Privacy: query text goes to cloud
(but financial data stays local — tool execution is always local).

### Option D: Fully Custom Model from Scratch

**What:** Train a model from scratch on financial domain data.

**Verdict: Not recommended.** The problem is not domain knowledge — it's structured
output reliability and data grounding in a small model. Fine-tuning solves this
at 1/1000th the cost of pre-training.

### Decision Matrix

| Option | Planning Quality | Synthesis Quality | Latency | Cost | Complexity | Offline |
|--------|-----------------|-------------------|---------|------|------------|---------|
| A: Fine-tuned planner | High | Same | Same | Low | Low | Full |
| B: Two models | High | Higher | Lower | Medium | Medium | Full |
| C: Cloud planning | Highest | Same | Lower | Low | Low | Degraded |
| D: Custom from scratch | Unknown | Unknown | Unknown | Very High | Very High | Full |

---

## 13. Recommendations

### Immediate (This Sprint)

1. **Expand the heuristic keyword coverage** — every tool should have at least
   5-10 keyword patterns. Currently some tools (like `list_transactions`,
   `list_investment_transactions`) have zero heuristic coverage.

2. **Add planner few-shot examples for every tool** — currently 9 examples for
   12 tools. Every tool should appear in at least one example.

3. **Evaluate Qwen 3 4B** — newer architecture, reportedly better at structured
   JSON output. Same-ish size as current 3B. Drop-in replacement if MLX-Swift
   weights are available.

### Short-Term (Next 2-4 Weeks)

4. **Build a planning evaluation harness** — 200+ test queries with expected
   tool calls. Run against the model, measure precision/recall per tool.
   This turns "whack-a-mole" into measurable quality.

5. **Evaluate cloud-assisted planning (Option C)** — add a cloud planning path
   when `cloudChatOptIn` is true. Use Claude Haiku for planning + synthesis
   when online. This would make the cloud path dramatically more reliable.

6. **Collect telemetry on plan failures** — log the planner's raw output,
   parse result, and final source (`.llm` vs `.heuristic` vs `.unsupported`)
   to understand real-world failure rates.

### Medium-Term (1-3 Months)

7. **Fine-tune a planning model (Option A)** — collect 2-5K examples from
   telemetry + manual annotation, LoRA fine-tune Qwen 2.5 1.5B or 3B.
   This is the highest-leverage investment for planning reliability.

8. **Evaluate two-model architecture (Option B)** — fine-tuned 1.5B planner +
   3B or 4B synthesizer. Test on device for memory/storage constraints.

### Not Recommended

9. **Custom model from scratch (Option D)** — cost/benefit ratio is poor.
   Fine-tuning existing models addresses the same problems at a fraction
   of the effort.

---

## Appendix A: All Tool Definitions

| # | Tool Name | Args | Description |
|---|-----------|------|-------------|
| 1 | `spending_summary` | `category?, merchant?, period?` | Aggregate spending by category/merchant for a period |
| 2 | `budget_status` | `category?` | Compare actual spending vs. monthly budget limits |
| 3 | `account_balance` | `account_name?` | Balances for linked accounts, with type field (checking/savings/credit/investment/loan) |
| 4 | `transaction_search` | `merchant?` | Find recent transactions from a specific merchant (limit 5) |
| 5 | `list_transactions` | `category?, merchant?, period?, min_amount?, max_amount?, limit?` | Row-level transaction list with flexible filters (limit 1-50, default 20) |
| 6 | `spending_trend` | `category?, months?` | Month-over-month spending trend + projected annual |
| 7 | `spending_anomaly` | `category?, period?` | Spike detection vs. 3-month rolling baseline |
| 8 | `holdings_summary` | `ticker?, account_name?` | Brokerage positions — total value, unrealized P/L, top holdings |
| 9 | `liability_report` | `kind?` | Credit cards, mortgages, student loans — bucketized by type |
| 10 | `net_worth` | *(none)* | Total net worth = cash + investments − liabilities |
| 11 | `investment_activity` | `activity_type?, period?` | Aggregate buys/sells/dividends/fees for a period |
| 12 | `list_investment_transactions` | `period?, activity_type?, limit?` | Row-level brokerage transactions with ticker enrichment |

---

## Appendix B: All Prompt Templates

### B1: Planner System Prompt

```
You are the planner for a personal finance assistant. The user asks a
question and you decide which tools to call to gather the data needed
to answer it.

Available tools:
{dynamically rendered catalog — one line per tool}

Respond with a JSON object of the form:
{"tools":[{"name":"<tool_name>","args":{<arg_name>:<value>, ...}}, ...]}

Rules:
- Emit ONLY the JSON object, no prose, no markdown fences.
- You may call multiple tools in one plan when a question needs data
  from several sources.
- Omit args the user didn't specify. Do not invent filters.
- For greetings or questions unrelated to the user's finances, return
  {"tools":[]}.
- If the question is about data the app does not track — live market
  prices, benchmarks, stock recommendations, economic forecasts, or
  retirement projections — return {"tools":[]}. Do NOT map the question
  to the nearest tool.
- Use the exact tool names from the list above.

Valid period values: today, this_week, this_month, last_month,
  last_30_days, last_90_days, last_N_months, year_to_date.

Common spending categories: Food & Dining, Transportation, Shopping,
  Entertainment, Bills & Utilities, Health & Fitness, Travel, Groceries,
  Subscriptions, Home, Education, Personal Care, Income.

Examples:
  Q: "What's my net worth?" → {"tools":[{"name":"net_worth","args":{}}]}
  Q: "How much did I spend on groceries this month?" →
     {"tools":[{"name":"spending_summary","args":{"category":"Groceries",
     "period":"this_month"}}]}
  ... (9 total examples including BTC, crypto, OOS refusals)

{slot context if any: "Previous topic: Groceries.\nPrevious period: this month."}
```

### B2: Synthesis System Prompt

```
You are HyperFin, a personal finance coach.
The user asks a question and you receive pre-computed data from one or
more tools.
Write a natural, conversational reply in full sentences — never output
a bare number by itself.
Only use figures that appear in the data. Never invent or estimate numbers.
When referring to dollar amounts, copy them exactly as they appear in
the data (they already include the $ sign and decimals).
Each account has a "type" field. Use it to answer precisely:
- "Cash balance" or "liquid cash" = only accounts typed "checking" or
  "savings".
- "Credit" accounts are liabilities (credit cards), not cash.
- "Investment" accounts hold securities — not liquid cash.
- "Loan" accounts are debts, not assets.
- "Net worth" = sum of all account balances (assets minus liabilities).
Never sum all accounts and call the result "cash balance."
If the data shows $0.00 or 0 transactions, tell the user in a full
sentence that you didn't find any matching transactions for that period.
If the data block is empty, answer briefly from general knowledge.
Never invent user-specific numbers. If the question is about market
forecasts, stock recommendations, benchmarks, or retirement projections,
say "I don't have that data on device," and suggest a related question.
{tone instruction}
Keep responses short (2-4 sentences).
Never mention data formats, tools, JSON, or system internals.
```

### B3: Unsupported Reply Templates (no LLM call)

| Tone | Reply |
|------|-------|
| Professional | "That's outside what I can answer from your on-device data. I can help with spending, balances, budgets, holdings, liabilities, net worth, and investment activity." |
| Friendly | "That one's outside what I can see from your accounts. I can help with..." |
| Funny | "Crystal ball's in the shop — I can't forecast markets or pick stocks. I can help with..." |
| Strict | "I don't answer questions outside your on-device data. I can help with..." |

---

*End of document. For questions, refer to the codebase at the file paths
referenced throughout, or contact the engineering team.*
