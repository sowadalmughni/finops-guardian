#!/usr/bin/env bash
# =============================================================================
# FinOps Guardian — Scanner Validation Harness
# Md. Sowad Al-Mughni | Kitalon Labs | https://github.com/sowadalmughni/finops-guardian
#
# Runs scan-cost-patterns.sh against evals/scan-fixtures/planted-issues, a
# fixture with one deliberately planted cost pattern per classification this
# skill claims to detect, and asserts the expected finding actually surfaces.
# This is what stands behind the "detects N cost patterns" claim, rather than
# just looking plausible.
#
# USAGE: bash evals/run-scan-checks.sh
# =============================================================================

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$SCRIPT_DIR/../scripts"
FIXTURE_SRC="$SCRIPT_DIR/scan-fixtures/planted-issues"

WORKDIR="$(mktemp -d)"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

cp -r "$FIXTURE_SRC"/. "$WORKDIR"/

PASS=0
FAIL=0

check() {
  local label="$1" haystack="$2" needle="$3"
  if printf '%s\n' "$haystack" | grep -qF "$needle"; then
    echo "  ✓ PASS — $label"
    PASS=$((PASS + 1))
  else
    echo "  ✗ FAIL — $label (expected to find: \"$needle\")"
    FAIL=$((FAIL + 1))
  fi
}

echo "Running scan-cost-patterns.sh against planted-issue fixtures..."
echo ""
RESULTS=$(bash "$SCRIPTS_DIR/scan-cost-patterns.sh" "$WORKDIR" --format json)

check "Pattern 1 (N+1 query) — finding raised"            "$RESULTS" '"pattern":"N+1 query (for-loop+await)"'
check "Pattern 1 — correct file flagged"                  "$RESULTS" 'orders.service.ts'

check "Pattern 2 (fan-out) — finding raised"               "$RESULTS" 'Possible fan-out'
check "Pattern 2 — classified SUPRALINEAR"                 "$RESULTS" '"classification":"SUPRALINEAR","pattern":"Possible fan-out'

check "Pattern 3 (runaway retry) — finding raised"         "$RESULTS" 'Unbounded retry loop (while true, no max attempts)'
check "Pattern 3 — classified RUNAWAY"                      "$RESULTS" '"classification":"RUNAWAY","pattern":"Unbounded retry loop'

check "Pattern 4 (unbounded storage) — finding raised"      "$RESULTS" 'Unbounded storage write, no retention policy detected in file'

check "Pattern 5 (lazy auto-scaling) — finding raised"      "$RESULTS" 'Autoscaling/function config with no concurrency or instance cap'
check "Pattern 5 — correct file flagged"                    "$RESULTS" 'serverless.yml'

check "Pattern 6 (missing cache) — finding raised"           "$RESULTS" 'Expensive aggregation/JOIN on GET endpoint with no caching'

check "Pattern 7 (unbounded LLM agent loop) — finding raised" "$RESULTS" 'Agentic loop with no maximum iteration cap'
check "Pattern 7 — classified RUNAWAY"                        "$RESULTS" '"classification":"RUNAWAY","pattern":"Agentic loop with no maximum iteration cap'

check "Pattern 8 (per-item paid API call) — finding raised"  "$RESULTS" 'Per-item paid third-party API call inside loop'
check "Pattern 8 — correct file flagged"                     "$RESULTS" 'enrichment.service.ts'

echo ""
echo "─────────────────────────────────────────────"
echo "  $PASS passed, $FAIL failed"
echo "─────────────────────────────────────────────"

[ "$FAIL" -eq 0 ]
