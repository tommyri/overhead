# Changelog

All notable changes to Overhead are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow semantic versioning.
The release script uses a version's section below as the GitHub release notes.

## [Unreleased]

## [0.3.0] - 2026-10-04

### Documentation
- `docs/DATA-SOURCES.md` explains how every type of data is gathered per provider: files and endpoints, deduplication, cost estimation, project and tier derivation, code-output counting, caching, and what is not collected.

### Added
- Sessions and working hours: a card on the overview and on the Claude Code and Codex pages with the number of sessions, total and median active time, the longest session, responses and tokens per session, a weekday × hour heatmap of when model responses happen (local time), and a table of the longest sessions with project and value. A session is one Claude Code transcript (subagent transcripts fold into their parent) or one Codex rollout; active time counts gaps between responses up to 15 minutes.
- Plan usage over time: a chart on the provider page showing how each plan window filled up across the selected range, one line per window, restarting from zero at every reset, with the alert threshold as a reference line. Codex history comes from the rate-limit snapshot it writes to its log on every turn; Claude Code history is appended by the status-line helper whenever the percentages change; Cursor is sampled by the app on each refresh.
- Cache savings: the overview and provider pages show what prompt caching saved at list prices ("≈$X saved, 95% of prompt tokens from cache"), computed as the cost had every prompt token been fresh input minus the cost as it was.
- Thinking share: Claude Code's `thinking_tokens` and Codex's `reasoning_output_tokens` are parsed into the records; the model tables get a "Thinking" column with the share of output spent on reasoning, and the token breakdown states the total.
- Period comparison: the stat tiles carry a delta against the previous period of the same length (yesterday, the previous 7/30 days, the same days last month, the month before). Hidden for the 90-day preset, whose previous period lies outside what API providers are asked for.
- The debug CLI prints thinking share, cache savings and the plan-history sample count.

### Changed
- The status-line helper also appends to `claude-statusline-history.jsonl` (one line per change, at most one every 15 minutes while unchanged; trimmed to 30 days past 1 MB), and the app replaces the installed helper copy when a newer build is bundled, so updates reach Claude Code without reinstalling.
- Parse caches are renamed (`claude-code-v6`, `codex-v6`), so existing installs re-index their local logs once with reasoning tokens, rate-limit snapshots and session ids attached.
- Claude plan windows: a bundled status-line helper (`overhead-statusline`) records the 5-hour and weekly rate-limit windows that Claude Code exposes only to its status-line command, so Claude Code gets the same plan card, projections and alerts as Codex and Cursor. Install or remove it from Settings → Providers → Claude Code (or `overhead statusline install`); an existing status line keeps working through the helper, and `~/.claude/settings.json` is backed up before it is changed.
- Tool usage: how often each tool was called and how often it failed, per day and per tool, for Claude Code (tool_use blocks and their results) and Codex (function and custom tool calls with exit codes). Card on the overview and on provider pages with tiles, a daily chart and a per-tool table.
- AI code output: lines of code accepted from each tool per day, with a chart and a per-source table. Claude Code and Codex counts come from edit tool calls and `apply_patch` calls whose result was not an error; Cursor's Tab and Composer suggested-vs-accepted lines come from the statistics Cursor keeps locally. Shown on the overview and on provider pages.
- Plan-limit alerts: optional macOS notifications when a Codex or Cursor usage window passes a chosen threshold (70/80/90%) or is on pace to run out before it resets; the menu bar icon switches to a warning symbol and the popover lists each window with its state. Settings → General has the toggle, threshold and a test button.
- Projections on plan windows: "on pace for N% by reset" or "runs out <when>", computed from the elapsed share of the period.
- "This month, projected" card on the overview: value so far, straight-line projection to month end at the last seven days' pace, and the monthly fee, per provider and in total.

## [0.2.1] - 2026-10-04

### Changed
- Projects are grouped by git repository root instead of working directory; git worktrees fold into their main repository, and folders outside any repository are kept as they are.

## [0.2.0] - 2026-10-04

### Added
- Per-project breakdown: a "By project" card on the overview and a "Projects" card on the Claude Code and Codex pages, with per-tool bars. Projects come from the working directory recorded in Claude Code transcripts and Codex session logs.
- Debug CLI prints a by-project section; demo data includes projects.

### Changed
- Parse caches are renamed, so existing installs re-index local logs once with projects attached.

## [0.1.3] - 2026-10-04

### Fixed
- Sidebar rows were not selectable: the list's selection type did not match the row tags.

### Added
- Go menu with ⌘1 for the overview and ⌘2 onward for providers.
- Provider rows in the overview's "Paid vs value" and "By provider" cards open that provider's page.

## [0.1.2] - 2026-10-04

### Fixed
- Release builds reported version 0.1.0 regardless of tag; the bundle version now comes from build settings.
- Checksum file uses a bare filename so `shasum -c` works from any directory.

### Added
- Manual trigger for the release workflow with a version input.

## [0.1.1] - 2026-10-04

### Added
- Demo data mode (`-demoData YES`) with deterministic synthetic usage for screenshots; nothing is read, fetched or persisted.
- Release workflow on GitHub Actions: builds, signs with Developer ID, notarizes, staples and publishes a DMG on tag push. Setup helper for the required secrets.
- Launch at login toggle.
- CI workflow running the test suite and an unsigned build.

### Changed
- App renamed from LLM Overview to Overhead (bundle identifier `app.overhead`); Keychain items, preferences and the Application Support folder migrate automatically.
- Range picker sizes to its content so the toolbar no longer truncates.

## [0.1.0] - 2026-10-04

### Added
- Local sources: Claude Code (`~/.claude/projects`) and Codex CLI (`~/.codex/sessions`) parsed incrementally, with cost estimated from list prices including Anthropic 5-minute and 1-hour cache-write pricing.
- API sources: Anthropic Admin, OpenAI Admin, Cursor (team Admin API and personal cursor.com session, importable from the Cursor app), xAI Management API, OpenRouter.
- Dashboard with daily value chart, per-provider and per-model breakdowns, provider pages, menu bar popover.
- Subscription plan status: Codex rolling windows and Cursor included-usage budget.
- Billing plans per provider (pay-per-use or subscription with monthly fee, prorated by calendar month) shown as paid vs API-equivalent value; tier and price auto-detected from Cursor's account endpoint, Codex's plan type and Claude Code's cached account profile.
- Credentials stored in the macOS Keychain.

[Unreleased]: https://github.com/tommyri/overhead/compare/v0.2.1...HEAD
[0.2.1]: https://github.com/tommyri/overhead/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/tommyri/overhead/compare/v0.1.3...v0.2.0
[0.1.3]: https://github.com/tommyri/overhead/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/tommyri/overhead/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/tommyri/overhead/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/tommyri/overhead/releases/tag/v0.1.0
