#!/bin/bash
# sTalk Smoke Tests Runner
# Requires: Maestro CLI, simulator with logged-in user
#
# Usage:
#   ./run_smoke.sh                    # Run all smoke tests
#   ./run_smoke.sh 02_tabs            # Run specific test

set -e

export JAVA_HOME="/opt/homebrew/opt/openjdk@17"
export PATH="$JAVA_HOME/bin:$HOME/.maestro/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SIMULATOR_ID="${SIMULATOR_ID:-A50D4EE6-BCA4-4E20-A3CF-A855F9498FAF}"
APP_ID="ru.implica.stalk"

echo "=== sTalk Smoke Tests ==="
echo "Simulator: $SIMULATOR_ID"
echo ""

# Boot simulator if needed
SIM_STATE=$(xcrun simctl list devices | grep "$SIMULATOR_ID" | grep -o "(Booted)\|(Shutdown)" || echo "Unknown")
if [ "$SIM_STATE" != "(Booted)" ]; then
    echo "Booting simulator..."
    xcrun simctl boot "$SIMULATOR_ID" 2>/dev/null || true
    sleep 5
fi

# Run tests
PASSED=0
FAILED=0
TOTAL=0

if [ -n "$1" ]; then
    # Run specific test
    FILES=$(ls "$SCRIPT_DIR"/${1}*.yaml 2>/dev/null)
else
    # Run all tests
    FILES=$(ls "$SCRIPT_DIR"/[0-9]*.yaml 2>/dev/null)
fi

for TEST_FILE in $FILES; do
    TEST_NAME=$(basename "$TEST_FILE" .yaml)
    TOTAL=$((TOTAL + 1))
    echo "--- [$TOTAL] $TEST_NAME ---"

    if maestro --device "$SIMULATOR_ID" test "$TEST_FILE" 2>&1; then
        echo "✅ PASSED: $TEST_NAME"
        PASSED=$((PASSED + 1))
    else
        echo "❌ FAILED: $TEST_NAME"
        FAILED=$((FAILED + 1))
    fi
    echo ""
done

echo "=== Results ==="
echo "Total: $TOTAL | Passed: $PASSED | Failed: $FAILED"

if [ $FAILED -gt 0 ]; then
    echo "❌ SMOKE TESTS FAILED"
    exit 1
else
    echo "✅ ALL SMOKE TESTS PASSED"
    exit 0
fi
