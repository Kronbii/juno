# Juno roadmap

Each milestone ends with its work tested, committed and usable. A box is ticked only when the item is done and verified.

## v1: shipped
Core tracking with the personal/household split, insights, budgets, goals, recurring entries, CSV/Excel/Notion import, Back Tap quick add, multiple currencies (LBP at 89,500), tags, receipts, net worth, reminders, Face ID, the widget source, and Supabase sync.

The audit fixes are also in:
- **Sync:** server-side last-write-wins, keyset paging, seed and recurring timestamps, account binding, per-row isolation.
- **Money:** re-pricing, parsing, DST, totals.

## Milestone 1: finish hardening
- [x] Fix every finding from the UI audit (each button, empty state and failure path).
- [x] Keep the audit's probes as a permanent widget test that presses every button (`test/ui_flows_test.dart`).
- [x] Run GitHub Actions CI on every push: analyze, unit, sync fuzz and reconciliation tests.
- [ ] Golden screenshot tests in CI. Deferred: they need an injectable clock first, because the app reads the real date (greetings, "today", relative demo data), so baselines would change every day. Layout breakage is already caught by the every-screen sweeps at 320, 393 and 1440 px and at 160% text.

## Milestone 2: iPhone integrations
The Dart side is built and tested. The native Swift needs one Xcode session on the Mac (docs/ios-setup.md).
- [x] **Headless logging:** a native App Intent, "Log expense", that never opens the app. Shortcut, Back Tap, Siri and the Action Button all use it. The entry goes into a shared App Group queue, which Juno imports on its next launch or sync.
- [x] **Siri phrases:** "Log 12 dollars groceries in Juno".
- [x] **Interactive widget:** iOS 17 buttons for preset amounts and the top categories.
- [x] **Lock Screen widgets:** accessory circular and rectangular sizes showing spent this month and budget left.
- [x] **Control Center control** (iOS 18): one tap to log an expense.
- [x] **Receipt scanning:** on-device text recognition prefills the total, the date and the merchant.

## Milestone 3: smarter, on-device first
- [x] **Quick-entry text:** "12 coffee kalei", "40k taxi yesterday" and "LBP 150000 generator" fill in the amount, currency, category, date and note.
- [x] **Category suggestions** as you type, learned from your history.
- [x] **Safe to spend today:** the month's income, minus recurring bills still due, minus what you've spent, divided by the days left.
- [x] **Month-end forecast**, including the recurring bills still to come.
- [x] **Subscription detection:** the same merchant charging the same amount on a monthly rhythm triggers a "Make this recurring?" suggestion.
- [x] **Unusual-spending alerts**, measured against your own baseline per category.
- [x] **Budget suggestions** from your 3-month averages.
- [x] **Split entries:** one receipt across several categories or scopes.

## Milestone 4: UI
- [x] First-launch onboarding: accounts, opening balances, LBP rate, first budget, sync.
- [x] A transaction detail screen, with history, receipts and splits. These live in the edit sheet: History, Split and the Receipt strip.
- [x] Category drill-down: trend, entries and the budget.
- [x] A calendar heatmap of spending.
- [x] Monthly and yearly reports (Month in review, with Copy summary).
- [x] Accessibility: every screen passes at 160% text (a CI test); icon buttons carry labels; contrast-validated palettes. A visual review fixed misleading partial-month comparisons.

## Milestone 5: safety
- [x] Automatic local backups (daily snapshot, 14 kept, export) and a merge-restore that never overwrites newer data.
- [x] Edit history per entry, with restore.

## Milestone 6: money you can trust
- [x] **Balance check:** enter what an account really holds; Juno shows the difference and fixes it either as an entry dated today (cash spent without logging, tagged #balance-check) or by correcting the starting balance (spending untouched). Each account shows when it was last checked.
- [x] **Cash flow, next 60 days** (Plan → Cash flow): spendable money (cash, current accounts, cards; savings left out) projected day by day from recurring income and bills, entries already dated ahead, and your usual everyday spending (90-day average, bills excluded). Shows the lowest point and warns before it goes below zero. Missing exchange rates are flagged, never guessed.
- [x] Sample data changes dollars into pounds each month, so the demo LBP wallet stays realistic.
- [x] **Who it's for:** a household expense can be marked "For" a family member (stored as `@person` tags, so it syncs with no new schema). Insights → For whom shows spending per person; an entry for two people is split between them to the cent.
- [x] **Goal pace:** each goal says whether it's on track at your recent saving rate (last three months, withdrawals included), when you'd reach it, and what the target date needs per month.
- [x] **Money health** (Insights): months your money would cover, share of income you keep, fixed bills as a share of income, and card debt — from the last three full months, each with a verdict in words.

## AI (Juno cloud, or your own key)
- [x] Juno cloud: a Supabase edge function holds the OpenAI key as a secret, accepts only signed-in users, and enforces the monthly cap on the server. AI works on every signed-in device with no setup. See [ai-cloud.md](ai-cloud.md).
- [x] Your own key, set on one device, overrides the relay there. Any of six providers (OpenAI, Gemini, Anthropic, DeepSeek, Qwen, Kimi) through one OpenAI-style client. The default is OpenAI gpt-5-mini; the model can be changed. The key stays on the device.
- [x] Assistant: a chat about your money. It answers by calling read-only tools that query the local database (totals, categories, entries, merchants, budgets, accounts, goals, recurring, safe to spend). Only the tool results are sent, never the database. It cannot change anything.
- [x] Log by chatting: "40 groceries for the house yesterday" becomes a draft card. Nothing is saved until you tap Log (Undo takes it back; Edit opens the normal entry sheet and is recognised, so it can't be logged twice).
- [x] The conversation is kept on the device across restarts (never synced); "New conversation" clears it.
- [x] This week on Home: an on-device read of the week so far against the same days last week, rewritten by AI at most once a day from totals only.
- [x] Import: entries Juno can't categorise get AI suggestions from their descriptions alone, marked "AI" until you confirm or change them.
- [x] Receipt fallback and a monthly read, as before.
- [x] Cost controls:
  - a monthly dollar cap (default $2), measured from the token counts each reply reports
  - finished turns folded to question and answer, and only the last 6 turns sent
  - stable instructions first, so providers can reuse the cached prefix
  - an on-device fallback when the cap is hit or anything fails
- [x] Measured live: about $0.0006 per assistant question and $0.0001 per receipt on gpt-5-mini.

## Not doing
- Apple Pay auto-logging (decided against).
- Splitting expenses with other people (you're the only one paying).
