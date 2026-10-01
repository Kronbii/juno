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
- [ ] Add golden screenshot tests so a visual regression fails CI.

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
- [ ] **Split entries:** one receipt across several categories or scopes.

## Milestone 4: UI
- [x] First-launch onboarding: accounts, opening balances, LBP rate, first budget, sync.
- [ ] A transaction detail screen, with history, receipts and splits.
- [x] Category drill-down: trend, entries and the budget.
- [x] A calendar heatmap of spending.
- [ ] Monthly and yearly reports.
- [ ] A design-critique pass over every screen, plus accessibility (dynamic type, VoiceOver labels, contrast).

## Milestone 5: safety
- [ ] Automatic encrypted local backups and a restore option.
- [ ] Edit history per entry, with undo.

## Optional: AI assist (OpenAI API, off by default)
- [ ] Your own API key, stored on the device. It needs API billing, which ChatGPT Plus doesn't include.
- [ ] Used only when the on-device result is uncertain: messy receipts, ambiguous text, and a monthly summary.
- [ ] Hard caps:
  - a monthly call limit (default 100)
  - short prompts
  - a cheap model
  - a cost counter in Settings
  - an on-device fallback when a cap is hit

## Not doing
- Apple Pay auto-logging (decided against).
- Splitting expenses with other people (you're the only one paying).
