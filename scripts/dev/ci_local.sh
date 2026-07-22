#!/usr/bin/env bash
set -euo pipefail

# Local CI parity check: clean release build + full parallel test run.
#
# The type-check budget flags surface expressions that compile slowly. CI
# runners are much slower than local Apple Silicon, so an expression that
# type-checks locally can fail CI outright with "unable to type-check this
# expression in reasonable time" (seen on PR #781). Treat any warning these
# flags emit as a must-fix: break the expression into typed sub-expressions.
TYPE_CHECK_BUDGET_MS=400
BUDGET_FLAGS=(
  -Xswiftc -Xfrontend
  -Xswiftc -warn-long-expression-type-checking="${TYPE_CHECK_BUDGET_MS}"
  -Xswiftc -Xfrontend
  -Xswiftc -warn-long-function-bodies="${TYPE_CHECK_BUDGET_MS}"
)

swift package clean
swift build -c release "${BUDGET_FLAGS[@]}"
swift test --parallel "${BUDGET_FLAGS[@]}"
