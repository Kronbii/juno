#!/usr/bin/env bash
# The same checks CI runs (.github/workflows/ci.yml), in the same order.
# Run before pushing; the pre-push hook (.githooks/pre-push) does it for you.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "› generated code is up to date"
dart run build_runner build >/dev/null
dart format lib/core/db/database.g.dart >/dev/null
git diff --exit-code -- '*.g.dart'

echo "› formatted"
dart format --output=none --set-exit-if-changed lib test

echo "› analyze (infos fail too)"
flutter analyze

echo "› tests"
flutter test

# Date maths only goes wrong where clocks change: Lebanon moves its clocks
# at midnight, Auckland's DST runs opposite to ours. CI machines run in UTC.
DATED="test/recheck_test.dart test/recheck_edges_test.dart test/forecast_test.dart test/money_health_test.dart test/weekly_read_test.dart test/advisor_test.dart test/logic_test.dart test/money_fixes_test.dart test/entry_parser_test.dart"
for tz in Asia/Beirut Pacific/Auckland; do
  echo "› date tests in $tz"
  TZ=$tz flutter test $DATED
done

echo "✓ all CI checks pass"
