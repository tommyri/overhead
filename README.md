# LLM Overview

A native macOS app (SwiftUI, menu bar + window) that shows how much you use and spend across LLM providers in one place: daily cost and token charts, per-model breakdowns, and a menu bar item with today's spend.

## Screenshots

![Overview: paid vs value, daily value by provider, top models](docs/screenshots/overview.png)

| Provider page with plan limits (Codex) | Provider page with plan limits (Cursor) |
|---|---|
| ![Codex CLI page](docs/screenshots/codex.png) | ![Cursor page](docs/screenshots/cursor.png) |

| Menu bar | Settings → Providers |
|---|---|
| <img src="docs/screenshots/menubar.png" width="420" alt="Menu bar popover with today's and this month's spend per provider"> | <img src="docs/screenshots/settings.png" width="420" alt="Provider settings with credentials, import button and billing plan"> |

## Providers

| Provider | How data is obtained | What you get |
|---|---|---|
| **Claude Code** | Parses `~/.claude/projects/**/*.jsonl` (and the Claude desktop app's agent-mode logs). No setup. | Tokens per model and day, request counts, cost **estimated** from list prices (incl. 5m/1h cache-write pricing). |
| **Codex CLI** | Parses `~/.codex/sessions/**/*.jsonl` and `archived_sessions`. No setup. | Tokens per model and day, API-equivalent cost estimate, and your ChatGPT plan's 5-hour / weekly usage windows. |
| **Anthropic API** | Admin API key (`sk-ant-admin…`). | Org-wide token usage by model plus billed cost from the cost report. |
| **OpenAI API** | Admin API key (`sk-admin…`). | Org-wide completions usage by model plus billed cost by line item. |
| **Cursor** | Personal plans (Pro/Pro+/Ultra): your cursor.com login session, imported from the Cursor app with one click or pasted from the browser. Teams: Admin API key. | Per-request tokens and charged cents per model and day, plus the plan's included-usage budget and billing cycle. |
| **xAI (Grok)** | Management API key + Team ID. | Billed USD per model and day (no token counts in the API). |
| **OpenRouter** | API key; optional Management key. | Today's spend from the key endpoint; with a Management key, 30 days of per-model history. |

Not available through any official API, so not in the app: ChatGPT consumer (Plus/Pro) usage, Claude.ai Pro/Max limits, consumer Grok (grok.com / X Premium).

### A note on Cursor personal plans

Cursor has no official usage API for individual subscriptions. The app uses the same JSON endpoints the cursor.com dashboard page calls (`/api/usage-summary` and `/api/dashboard/get-filtered-usage-events`), authenticated with your `WorkosCursorSessionToken` login cookie. This is what every third-party Cursor usage tool does, but it is reverse-engineered and may break when Cursor changes its dashboard.

Two ways to provide the session, both in Settings → Providers → Cursor:

- **Import from Cursor app** reads the access token the Cursor desktop app keeps in `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb` (opened read-only, on a private copy; nothing is written back and no refresh token is touched). Cursor refreshes that token itself, so if the session expires, open Cursor and import again.
- **Paste the cookie**: on cursor.com, open the browser dev tools → Application → Cookies → copy the value of `WorkosCursorSessionToken`.

The session is stored in the macOS Keychain and sent only to `cursor.com`.

### Paid vs value

Subscription sources (Codex on a ChatGPT plan, Cursor Pro/Pro+/Ultra, Claude Code on a seat) charge a flat monthly fee, so the per-token dollar figures the app computes for them are **API-equivalent value**, not spend: what the same tokens would have cost at the vendor's API list prices. The app detects the tier where it can and pre-fills the list price: Cursor from the account endpoint (`/api/auth/stripe`, which distinguishes Pro+ from Pro and knows about annual billing), Codex from the `plan_type` in its logs, Claude Code from the organization type and seat tier cached in `~/.claude.json`. Detected values can be edited in Settings → Providers → Billing; a typed fee is never overwritten, and "Use detected" switches back. Tier prices live in `LLMOverviewCore/Sources/LLMOverviewCore/Pricing/PlanPrices.swift` (Cursor Pro/Pro+/Ultra $20/$60/$200, ChatGPT Plus/Pro 100/Pro 200/Pro 500 $20/$100/$200/$500, Claude Pro/Max/Team seats; reviewed 2026-10-04). The dashboard then shows a "Paid vs value" table with the fee prorated to the selected range (a whole calendar month counts once; a 7-day range counts about a quarter of a month) next to the value used, and the value ÷ paid multiple. Pay-per-use providers show their billed cost as "paid".

Costs marked `≈` are estimates computed from the vendor's published list prices (`LLMOverviewCore/Sources/LLMOverviewCore/Pricing/PriceTable.swift`). Unmarked costs come straight from a billing endpoint.

## Build & run

Requirements: Xcode 26+, [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
xcodegen generate
xcodebuild -project LLMOverview.xcodeproj -scheme LLMOverview -configuration Release -derivedDataPath build/DerivedData build
open "build/DerivedData/Build/Products/Release/LLM Overview.app"
```

Or open `LLMOverview.xcodeproj` in Xcode and press Run.

### Core package tests and debug CLI

The parsing/aggregation logic lives in the `LLMOverviewCore` Swift package and has no UI dependencies:

```bash
cd LLMOverviewCore
swift test                      # parser + API adapter tests (mocked HTTP)
swift run llmo 30               # print per-model totals from local logs for the last 30 days
```

## Architecture

```
LLMOverview/                 SwiftUI app (xcodegen target)
  App/AppModel.swift         @Observable state: records, statuses, credentials, refresh timer
  App/ProviderRegistry*.swift  which adapter backs each ProviderID
  Views/                     Dashboard, provider detail, settings, menu bar
LLMOverviewCore/             Swift package, unit-tested
  Models/                    ProviderID, UsageRecord (normalized day × model row), DateRangePreset
  Providers/                 One UsageProvider per source (local log parsers + HTTP adapters)
  Pricing/PriceTable.swift   list prices used for estimates
  Aggregation/               totals, per-model, daily series
  Storage/                   Keychain, per-provider JSON cache, incremental file-parse cache
```

Every adapter emits `UsageRecord`s: one row per (provider, local calendar day, model) with input / output / cache-write / cache-read tokens, request count, and a cost that is `reported`, `estimated`, or `unknown`. The UI only understands that shape, so adding a provider means implementing `UsageProvider.fetch` and adding a case to `ProviderID`.

Local parsers keep a per-file index (size + mtime → parsed entries) under `~/Library/Application Support/LLM Overview/index/`, so after the first run only new or changed session files are re-read. API results are cached under `.../LLM Overview/cache/` so the app shows data instantly on launch.

Credentials are stored in the macOS Keychain (service `app.llmoverview`, the bundle identifier), never in files.

## Adding a provider

1. Add a case to `ProviderID` (name, kind, palette slot, setup hint).
2. Implement a `UsageProvider` in `LLMOverviewCore/Sources/LLMOverviewCore/Providers/`, declaring any `credentialFields`.
3. Register it in `LLMOverview/App/ProviderRegistry+Providers.swift`.
4. Add a fixture under `LLMOverviewCore/Tests/.../Fixtures` and a test.
