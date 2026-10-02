# Testing Juno

`./scripts/check.sh` runs exactly what CI runs, and the pre-push hook runs it for you before every push.

## What `check.sh` runs

1. **Generated code and formatting:** checks that both are up to date.
2. **Analyzer:** infos fail too.
3. **The full test suite:**
   - **Reconciliation:** dashboard figures, budgets, balances and net worth are recomputed from raw SQL over random ledgers, then compared with what the app shows.
   - **New-feature reconciliation** (`recheck_test.dart`): the cash flow forecast, money health, "for whom", the week so far and the assistant's lookups are checked against independent oracles.
   - **Sync:** three-device fuzz with outages, last-write-wins, paging and hardening. `recheck_sync_test.dart` covers the newer write paths: balance checks, assistant logging and Undo, and person tags.
   - **Edges** (`recheck_edges_test.dart`): stale drafts, leap days, month ends and year turns, an app with no accounts, corrupt local state, and 20,000 entries.
   - **UI flows:** every screen at 320, 393 and 1440 px and at 160% text, in dark theme, in an empty app, with no accounts, and with a missing LBP rate. Every Plan tab and the entry sheet are covered too.
4. **The date tests again under `TZ=Asia/Beirut` and `TZ=Pacific/Auckland`:** date maths only breaks where clocks change, and CI runs in UTC.
   - Lebanon moves its clocks at midnight.
   - Count days with `Day.between` and step dates with `Day.shift`, never `Duration(days: …)`.

## Deeper runs

```bash
JUNO_SEEDS=40 flutter test test/reconcile_test.dart test/recheck_test.dart test/sync_fuzz_test.dart
```

`JUNO_SEEDS` adds that many extra random worlds to each randomised test.

## Live runs (opt-in, cost fractions of a cent)

```bash
# The real model: receipts, an assistant question, logging by chat, import categories
JUNO_AI_KEY="$(sed -n 's/^openAI= *//p' .env)" flutter test test/ai_live_test.dart --run-skipped --name '^(?!relay)'

# The real Supabase project: two devices, receipts through Storage, LWW, paging, new write paths
JUNO_LIVE_EMAIL=… JUNO_LIVE_PASSWORD=… flutter test test/live_sync_test.dart --run-skipped

# Screenshots for review (test/goldens/)
flutter test test/screenshots_test.dart --update-goldens --run-skipped --tags shots
```

The live sync test removes its own Storage files. Use a throwaway account for it, not your real one.
