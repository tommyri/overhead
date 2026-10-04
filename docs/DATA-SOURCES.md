# How Overhead gathers its data

Everything the app shows is derived from two kinds of source: log files that the coding tools already keep on your Mac, and the vendors' own HTTP APIs called with credentials you provide. There is no Overhead backend. This document describes, per data type and per provider, exactly what is read, how it is normalised, and what is left out.

The code paths referenced live in `OverheadCore/Sources/OverheadCore/` unless noted.

## 1. The shapes everything is normalised into

| Type | What it holds | Produced by |
|---|---|---|
| `UsageRecord` | One row per provider × local calendar day × model × project: input, output, cache-write and cache-read tokens, reasoning tokens (a subset of output, where reported), request count, and a cost that is `reported` (from a billing endpoint), `estimated` (from list prices, shown with ≈) or `unknown`. | every provider's `fetch` |
| `PlanStatus` | Subscription consumption: named windows with a used percentage, reset time and period start, plus the detected tier and its list price. | `planStatus` on Codex, Cursor, Claude Code |
| `PlanSample` | One past observation of a plan window: provider, time, window title, used percentage, reset time. The "Plan usage over time" chart is drawn from these. | `planHistory` on Codex and Claude Code; the app's own sampling for the rest |
| `CodeActivity` | One row per provider × day × kind × project: lines added, lines removed, lines suggested, number of edits. | `codeActivity` on Claude Code, Codex, Cursor |
| `ToolActivity` | One row per provider × day × tool × project: number of calls and how many returned an error. | `toolActivity` on Claude Code, Codex |

Conventions that apply across providers:

- **Days are local calendar days.** Local logs carry timestamps and are bucketed in your time zone. APIs that bucket by UTC day (OpenAI, Anthropic, xAI, OpenRouter) have each UTC bucket mapped to the local day with the same calendar date, so "October 1st" stays October 1st regardless of your offset.
- **Cache tokens are kept disjoint.** Input, cache-read and cache-write are separate buckets that sum to the prompt size. OpenAI reports cached tokens as a subset of input; those are subtracted out so the buckets do not overlap.
- **Cost estimation** (`Pricing/PriceTable.swift`) multiplies token counts by the vendor's published per-million list prices, matched by model-id prefix after stripping date suffixes. Anthropic cache writes are priced at 1.25× input for 5-minute and 2× for 1-hour TTL, cache reads at the published read price; OpenAI cached input at its cached price; cache writes bill as input where the vendor has no separate price. Unknown models get `unknown` cost and show "—".
- **Value vs paid.** For subscription sources the estimated cost is *API-equivalent value*, not spend. What you pay is the plan's monthly fee, entered or detected per provider (`BillingPlan`) and prorated to the selected range by calendar month.
- **Fetch window.** Every refresh asks each provider for the last 90 days so all range presets are served from one fetch; the UI filters.

## 2. Claude Code

**Source files.** `~/.claude/projects/**/*.jsonl` (one file per session, plus `subagents/` and workflow files underneath), and the Claude desktop app's agent-mode logs under `~/Library/Application Support/Claude/local-agent-mode-sessions/`, including the `.claude/projects` folders nested inside them. All `.jsonl` files are read, hidden folders included.

**Usage.** Lines with `"type":"assistant"` carry `message.usage` with `input_tokens`, `output_tokens`, `cache_creation_input_tokens`, `cache_read_input_tokens`, `cache_creation.ephemeral_5m_input_tokens` / `ephemeral_1h_input_tokens`, and in newer transcripts `output_tokens_details.thinking_tokens` (the reasoning share of the output; older transcripts lack it, and those responses count as having reported none). One API response is written as several lines, one per content block, all sharing `message.id`; the last line carries the final `output_tokens`, so the parser keeps the last occurrence per message id. Message ids are globally unique, so the same response seen in an audit log and a nested transcript collapses to one. Lines whose model is `<synthetic>` (error placeholders) are skipped. The timestamp is `timestamp`, falling back to `_audit_timestamp` in audit logs.

**Cost.** Claude Code records no cost, so every record is estimated. The 1-hour cache-write share is priced separately from the 5-minute share.

**Project.** Each line carries `cwd`. The directory is resolved to the enclosing git repository root (a `.git` folder, or a `.git` file for worktrees, which are folded into their main repository) by `Aggregation/ProjectResolver.swift`. Directories outside any repository are kept as they are; the home directory is never treated as a root.

**Plan tier.** `~/.claude.json` → `oauthAccount` holds `organizationType` (`claude_pro`, `claude_max`, `claude_team`, `claude_enterprise`), `seatTier` (`team_standard`, `team_tier_1`, …) and `userRateLimitTier` (`default_claude_ai`, `default_claude_max_5x`, `default_claude_max_20x`). `Pricing/PlanPrices.swift` maps these to a tier name and list price.

**Plan windows.** Claude Code exposes the subscription's rolling windows only to its status-line command: the JSON it pipes to that command contains `rate_limits.five_hour` and `rate_limits.seven_day` (each with `used_percentage` 0–100 and `resets_at` in epoch seconds) and, behind a Claude apps gateway, `spend_limit`. Overhead ships `overhead-statusline`, a small helper that writes that object with a timestamp to `~/Library/Application Support/Overhead/claude-statusline.json` and otherwise prints a status line (chaining to the command you had before, saved in `statusline-chain`, or a compact default). Installing from Settings → Providers → Claude Code copies the helper to `~/Library/Application Support/Overhead/bin/` and sets `statusLine.command` in `~/.claude/settings.json` after backing the file up; removing restores the previous command. `Storage/ClaudeStatusLine.swift` reads the record, derives each window's period start (reset minus 5 hours or 7 days) and drops windows whose reset has passed. The helper also appends the same object to `claude-statusline-history.jsonl` whenever a percentage or reset time changed (and at most once every 15 minutes while nothing changed; past 1 MB the file is trimmed to the last 30 days); `readHistory` turns every line into `PlanSample`s, keeping windows whose reset has since passed since the point is to show what happened. Windows update only while Claude Code runs, and Anthropic documents `rate_limits` for claude.ai Pro and Max subscribers; the endpoint Claude Code's `/usage` command uses directly is undocumented and reserved for Anthropic's clients, so it is not called.

**Code output.** Within each assistant line, `tool_use` blocks named `Edit`, `Write`, `MultiEdit` or `NotebookEdit` are counted: added lines from `new_string` / `content` / `new_source`, removed lines from `old_string`. The count is attributed to the response only when the matching `tool_result` block in a later user line (same `tool_use_id`) does not have `is_error: true`, so rejected or failed edits are excluded. Edits whose result never arrives are not counted.

**Tool usage.** Every `tool_use` block in an assistant line counts one call for its `name` (Bash, Read, Edit, Grep, WebFetch, Task, …). The call is marked failed when the matching `tool_result` has `is_error: true`. Tool inputs other than the edit fields above are not decoded.

**Not read.** Prompt or response text is never parsed, stored or displayed; the parser decodes only the fields above.

## 3. Codex CLI

**Source files.** `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` and `~/.codex/archived_sessions/*.jsonl`.

**Usage.** Two record shapes exist. Newer files have `token_usage_record` lines, one per response, with `payload.response_id` and `payload.usage`; these are deduplicated by response id. Older files only have `event_msg` lines with `payload.type == "token_count"`: `info.total_token_usage` is a running total and `info.last_token_usage` the latest delta, so consecutive events whose running total is unchanged are skipped and the deltas summed. When a file has both shapes only the per-response records are used. Neither shape names the model, so each is attributed to the most recent preceding `turn_context` (`payload.model`, joined by `turn_id` where possible). OpenAI's `cached_input_tokens` and `cache_write_input_tokens` are subsets of `input_tokens` and are split out into disjoint buckets; `reasoning_output_tokens` (a subset of `output_tokens`) is kept as the record's reasoning count.

**Cost.** Estimated from list prices. On a ChatGPT plan this is the API-equivalent value of the tokens, not a charge.

**Project.** `payload.cwd` from `session_meta` and `turn_context`, resolved to the repository root as for Claude Code.

**Plan status.** `token_count` events carry `rate_limits` with `plan_type` (`plus`, `pro`, `prolite` = Pro 100, `promax` = Pro 500, `team`, …) and `primary`/`secondary` windows (`used_percent`, `window_minutes`, `resets_at`). The newest snapshot is taken from the most recently modified session files. A window's period start is its reset time minus its length, which enables projections.

**Plan history.** Every `token_count` event that carries `rate_limits` (newer builds also write them with `info` null) is kept as a snapshot and attached to the last response at or before it in the same file. `aggregatePlanHistory` turns each snapshot into one `PlanSample` per window, so the chart has one point per turn for as far back as the logs go.

**Code output.** `response_item` lines with `payload.type == "custom_tool_call"` and `name == "apply_patch"` contain the patch in `payload.input`; added and removed lines are the `+`/`-` lines of the patch (directive and header lines excluded). The count is applied only when the matching `custom_tool_call_output` (same `call_id`) contains "Success", and is attributed to the next usage record in the file.

**Tool usage.** `response_item` lines of type `function_call` (exec_command, shell, write_stdin, update_plan, …) and `custom_tool_call` (exec, apply_patch) each count one call for `payload.name`. The matching `*_output` line's `output` is a JSON string whose `metadata.exit_code` marks the call as failed when non-zero; a patch whose output reports a verification failure counts as failed too. Calls are attributed to the next usage record in the file, like patches.

## 4. Cursor

Cursor stores no per-request token data locally, so usage comes from Cursor's servers.

**Personal plans (Pro, Pro+, Ultra).** Cursor publishes no API for individual accounts; the app uses the JSON endpoints the cursor.com dashboard page itself calls, authenticated with your login session. This is what every third-party Cursor usage tool does, and it may break when Cursor changes its dashboard.

- *Credential.* The `WorkosCursorSessionToken` cookie value, `<user id>::<JWT>`. You paste it from the browser, or press "Import from Cursor app", which reads `cursorAuth/accessToken` from a private, read-only copy of `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb` (the write-ahead log is copied too so a freshly refreshed token is seen) and takes the user id from the JWT's `sub` claim. Nothing is written back and the refresh token is not touched. The JWT's expiry is checked before use.
- *Usage.* `POST https://cursor.com/api/dashboard/get-filtered-usage-events` with `teamId: 0`, epoch-millisecond `startDate`/`endDate` as strings, 500 events per page, and the `Origin: https://cursor.com` header the server requires. Each event gives `model`, `tokenUsage` (input, output, cache write, cache read) and `chargedCents`, the amount deducted from the plan; numbers may arrive as strings and are decoded leniently. Events have no stable id, so pages are deduplicated by a fingerprint of timestamp, model, tokens and cents. Cost is `reported` (charged cents ÷ 100).
- *Plan status.* `GET /api/usage-summary` gives the included-usage percentage, the Auto and Other model pools, the billing cycle, and `membershipType`; `GET /api/auth/stripe` gives `individualMembershipType` (which distinguishes Pro+ from Pro) and annual billing. The dollar detail is shown only when it agrees with the percentage, since the two are known to disagree on some plans.
- *Plan history.* Cursor keeps no history of the budget, so the app records the plan status it fetched on each refresh (`Storage/PlanHistoryStore.swift`, under `plan-history/`): one sample per window whenever its value or reset changed, or every six hours otherwise, kept for 90 days. The same sampling runs for every provider, but is only shown where the source has no history of its own.
- *Not available.* Events carry no working directory, so Cursor usage has no project, and nothing Cursor exposes locally or over these endpoints describes tool calls.

**Team plans.** The documented Admin API: `POST https://api.cursor.com/teams/filtered-usage-events` with HTTP Basic auth (team key as username), 30-day windows, same token and cents fields.

**Code output.** Cursor keeps daily counters in `state.vscdb` under `aiCodeTracking.dailyStats.v1.5.<date>`: `tabSuggestedLines`, `tabAcceptedLines`, `composerSuggestedLines`, `composerAcceptedLines`. These are read from a private copy of the database, no credentials required. Cursor can report more accepted than suggested lines for Composer; the acceptance rate is hidden when counts are not comparable.

## 5. Pay-per-use APIs

All of these report billed cost, so records are `reported`, and none carry a project.

| Provider | Credential | Endpoints | Notes |
|---|---|---|---|
| **Anthropic** | Admin API key (`sk-ant-admin…`), org required | `GET /v1/organizations/usage_report/messages` (daily buckets, `group_by[]=model`, ≤31 days per call, cursor pagination) and `GET /v1/organizations/cost_report` (`group_by[]=description`) | Cost amounts are decimal strings in cents. Usage tokens: `uncached_input_tokens`, `cache_creation.*`, `cache_read_input_tokens`, `output_tokens`. Rows with tokens but no cost line (e.g. priority tier) fall back to an estimate. |
| **OpenAI** | Admin API key (`sk-admin…`) | `GET /v1/organization/usage/completions` (unix-second times, `group_by[]=model`, ≤31 daily buckets) and `GET /v1/organization/costs` (`group_by[]=line_item`, ≤180 buckets) | `input_tokens` includes cached and cache-write tokens, which are split out. Line items look like `gpt-5, input_tokens`; the model is the part before the comma. |
| **xAI** | Management API key + team id | `POST https://management-api.x.ai/v1/billing/teams/{team}/usage` with a daily `analyticsRequest` grouped by description | Returns USD per model per day; no token counts. "Chat grok-…" labels are shortened to the model id. |
| **OpenRouter** | API key; optional Management key | `GET /api/v1/key` (today's spend); with a Management key `GET /api/v1/activity` (30 days per model, with tokens and requests) | Without a Management key only today's total is available. |

## 6. Plan tiers and prices

`Pricing/PlanPrices.swift` maps tier identifiers to list prices: Cursor `membershipType`/`individualMembershipType` (Pro $20, Pro+ $60, Ultra $200; annual billing 20% lower), Codex `plan_type` (Plus $20, Pro 100 $100, Pro 200 $200, Pro 500 $500, Business $25), and the Claude fields above (Pro $20, Max 5x $100, Max 20x $200, Team Standard seat $25, Team Premium seat $125). A detected tier pre-fills the provider's billing plan; a fee you type is never overwritten, and "Use detected" restores detection. Prices were last reviewed on the date in that file.

## 7. Derived figures: alerts, forecasts, comparisons

- **Window projections and alerts.** `Aggregation/Forecast.swift` projects plan windows linearly from the elapsed share of the period: expected usage at reset is `used ÷ elapsed fraction`, and the exhaustion time is where that line crosses 100%, reported only if it falls before the reset and at least 5% of the period has elapsed. Alerts fire when a window passes your threshold (70/80/90%), reaches 95% (critical), or is on pace to run out while at least half used; one macOS notification per window, level and period.
- **Month-end projection** continues the last seven days' average value for the remaining days of the month.
- **Plan usage over time** (`UsageAggregator.planSeries`) draws the samples above as one line per window. Between two samples whose reset time moved later, the line holds the last value until the old reset and starts a new segment at zero, so the sawtooth is explicit. Samples are thinned to about 400 points per window (the last sample of each time bucket) before drawing.
- **Cache savings** (`UsageAggregator.cacheSavings`) sums, over records whose model is in the price table, the list-price cost had every prompt token (input + cache read + cache write) been billed as fresh input, and subtracts the list-price cost with caching as it happened (an estimated record's own cost, which includes the 1-hour cache-write premium; for billed records a fresh estimate, because a plan charge or invoice is not a per-token price). Both sides are list-price arithmetic, so the result is always an estimate, shown with ≈; models without a list price are left out of both sides.
- **Thinking share** is reasoning tokens ÷ output tokens, shown only where some reasoning tokens were reported; a dash means the source did not say, not that there was none.
- **Period comparison** puts a delta on the stat tiles against the previous period of the same length (`DateRangePreset.previousInterval`): yesterday for Today, the preceding 7 or 30 days, the same number of elapsed days of the previous month for This month, and the whole month before for Last month. The 90-day preset has no comparison because its previous period lies outside the 90 days API providers are asked for.

## 8. Storage and caching

- Parsed local logs are indexed per file by size and modification time under `~/Library/Application Support/Overhead/index/`, so only new or changed session files are re-read. When the parser changes shape the index name is bumped and everything is re-read once.
- Each provider's last successful result (usage, code activity, tool usage and plan history) is saved under `~/Library/Application Support/Overhead/cache/` so the app shows data immediately on launch and keeps stale data visible if a fetch fails.
- The status-line helper's current record and history live next to those folders as `claude-statusline.json` and `claude-statusline-history.jsonl`; the app's own plan samples under `plan-history/`.
- Credentials live in the macOS Keychain under the bundle identifier (`app.overhead`). Preferences, including billing plans and alert settings, live in the app's UserDefaults domain. Settings → General → "Clear cached data" removes the caches; credentials stay.

## 9. What is deliberately not collected

- Prompt and response text from any tool.
- ChatGPT app usage (conversations, images): no official API for consumer accounts.
- claude.ai chat usage and Pro/Max rolling windows: undocumented endpoint reserved for Anthropic's clients.
- Consumer Grok (grok.com, X Premium): no API.
- Cursor's access token beyond the one-time, user-triggered import; Cursor's refresh token, ever.
