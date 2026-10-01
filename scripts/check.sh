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

echo "✓ all CI checks pass"
