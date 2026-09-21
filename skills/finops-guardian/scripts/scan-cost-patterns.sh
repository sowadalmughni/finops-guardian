#!/usr/bin/env bash
# =============================================================================
# FinOps Guardian — Cost Pattern Scanner
# Md. Sowad Al-Mughni | Kitalon Labs | www.kitalonlabs.com
# https://github.com/sowadalmughni/finops-guardian
#
# USAGE:  bash scripts/scan-cost-patterns.sh [target] [--files-from FILE] [--gate-only] [--format json]
# OUTPUT: Every cost-risk pattern with classification (CONSTANT/LINEAR/SUPRALINEAR/
#         QUADRATIC_PLUS/RUNAWAY), file path, line number, and fix reference.
#
# NOTE: All scan loops use `done < <(command)` process substitution rather than
# `command | while read`. Piping into a while loop runs it in a subshell, which
# would silently discard every counter increment inside log_finding() — breaking
# both the summary counts and the exit code this script's CI gate depends on.
# =============================================================================

# PCRE preflight: BSD grep (stock macOS) has no -P support. Every pattern below
# relies on -P, so fail loudly here rather than silently under-reporting findings.
if ! printf 'x' | grep -P 'x' >/dev/null 2>&1; then
  echo "ERROR: this script requires GNU grep with PCRE (-P) support." >&2
  echo "On macOS, stock BSD grep does not support -P. Install GNU grep first:" >&2
  echo "  brew install grep" >&2
  echo "then make sure 'grep' on PATH resolves to it (e.g. via gnubin in PATH)." >&2
  exit 1
fi

TARGET="${1:-.}"
FILES_FROM=""
GATE_ONLY=false
FORMAT="text"

shift || true
while [ "$#" -gt 0 ]; do
  case "$1" in
    --files-from) FILES_FROM="$2"; shift 2 ;;
    --gate-only)  GATE_ONLY=true; shift ;;
    --format)     FORMAT="$2"; shift 2 ;;
    *) shift ;;
  esac
done

RUNAWAY_COUNT=0
QUADRATIC_COUNT=0
SUPRALINEAR_COUNT=0
LINEAR_COUNT=0
SUPPRESSED_COUNT=0
declare -a JSON_FINDINGS=()

QUIET=false
[ "$GATE_ONLY" = true ] && QUIET=true
[ "$FORMAT" = "json" ] && QUIET=true

if [ "$QUIET" = false ]; then
  echo ""
  echo "═══════════════════════════════════════════════════"
  echo "  FINOPS GUARDIAN — COST PATTERN SCAN"
  echo "  https://github.com/sowadalmughni/finops-guardian"
  echo "  $(date)"
  echo "═══════════════════════════════════════════════════"
  echo "  Context: one AI-generated dashboard caused \$12,000"
  echo "  in database costs from a single N+1 pattern."
  echo "  Unoptimized AI code has inflated cloud bills up to"
  echo "  400% at production scale."
  echo "═══════════════════════════════════════════════════"
  echo ""
fi

log_finding() {
  local classification="$1"
  local pattern="$2"
  local file="$3"
  local line="$4"
  local detail="$5"
  local icon="🟢"

  # Suppression: a comment containing "finops-guardian-ignore" on the
  # flagged line or the line immediately above it silences this specific
  # finding. Auditable, not silent — it still counts toward SUPPRESSED_COUNT
  # and requires an actual comment in the source, so it can't be used to
  # quietly erase evidence of the decision the way deleting the finding by
  # hand or `commit --no-verify` would.
  local suppress_window
  suppress_window=$(sed -n "$((line > 1 ? line - 1 : 1)),${line}p" "$file" 2>/dev/null)
  if echo "$suppress_window" | grep -qF "finops-guardian-ignore"; then
    SUPPRESSED_COUNT=$((SUPPRESSED_COUNT + 1))
    [ "$QUIET" = false ] && echo "  ⚪ SUPPRESSED — $pattern ($file:$line, finops-guardian-ignore)"
    return
  fi

  case "$classification" in
    RUNAWAY)        RUNAWAY_COUNT=$((RUNAWAY_COUNT + 1)); icon="⚫" ;;
    QUADRATIC_PLUS)  QUADRATIC_COUNT=$((QUADRATIC_COUNT + 1)); icon="🔴" ;;
    SUPRALINEAR)     SUPRALINEAR_COUNT=$((SUPRALINEAR_COUNT + 1)); icon="🟠" ;;
    LINEAR)          LINEAR_COUNT=$((LINEAR_COUNT + 1)); icon="🟡" ;;
  esac

  local escaped_pattern escaped_file escaped_detail
  escaped_pattern=$(printf '%s' "$pattern" | sed 's/\\/\\\\/g; s/"/\\"/g')
  escaped_file=$(printf '%s' "$file" | sed 's/\\/\\\\/g; s/"/\\"/g')
  escaped_detail=$(printf '%s' "$detail" | sed 's/\\/\\\\/g; s/"/\\"/g')
  JSON_FINDINGS+=("{\"classification\":\"$classification\",\"pattern\":\"$escaped_pattern\",\"file\":\"$escaped_file\",\"line\":\"$line\",\"detail\":\"$escaped_detail\"}")

  if [ "$QUIET" = false ]; then
    echo "  $icon $classification — $pattern"
    echo "     $file:$line"
    echo "     $detail"
    echo ""
  fi
}

# ─────────────────────────────────────────────────────
# Determine scan set: specific files or full target
# NUL-delimited throughout so paths containing spaces survive intact — a
# plain `for file in $SCAN_FILES` word-splits on whitespace and silently
# skips or mangles any such path.
# ─────────────────────────────────────────────────────
declare -a SCAN_FILES=()
if [ -n "$FILES_FROM" ] && [ -f "$FILES_FROM" ]; then
  while IFS= read -r -d '' f; do
    SCAN_FILES+=("$f")
  done < <(grep -E '\.(ts|tsx|js|jsx|py|yml|yaml)$' "$FILES_FROM" | tr '\n' '\0')
else
  while IFS= read -r -d '' f; do
    SCAN_FILES+=("$f")
  done < <(find "$TARGET" \( -name "*.ts" -o -name "*.tsx" -o -name "*.js" -o -name "*.jsx" -o -name "*.py" -o -name "*.yml" -o -name "*.yaml" \) \
    ! -path "*/node_modules/*" ! -path "*/.git/*" ! -path "*/dist/*" ! -path "*/build/*" ! -path "*/.next/*" -print0 2>/dev/null)
fi

# ─────────────────────────────────────────────────────
# PATTERN 1: N+1 Query
# ─────────────────────────────────────────────────────
[ "$QUIET" = false ] && echo "── Scanning: N+1 query patterns ─────────────────"

for file in "${SCAN_FILES[@]}"; do
  [ -f "$file" ] || continue

  while IFS=: read -r linenum content; do
    [ -z "$linenum" ] && continue
    context=$(sed -n "${linenum},$((linenum + 5))p" "$file" 2>/dev/null)
    if echo "$context" | grep -qP "await.*(find|query|select|prisma\.|supabase\.|db\.)"; then
      # Exclude the triggering .map(async line itself from the lookback —
      # it always contains ".map(", which is exactly what this check searches
      # for, so including it made this always match regardless of real nesting.
      preceding=$(sed -n "1,$((linenum - 1))p" "$file" 2>/dev/null | tail -15)
      if echo "$preceding" | grep -qP "for\s*\(|\.map\(|\.forEach\("; then
        log_finding "QUADRATIC_PLUS" "N+1 query nested inside another loop" "$file" "$linenum" \
          "Nested N+1 pattern — cost grows O(n^2). See reference/cost-pattern-playbook.md section Pattern 1"
      else
        log_finding "LINEAR" "N+1 query (.map+await)" "$file" "$linenum" \
          "1 + N queries where N = result set size. See reference/cost-pattern-playbook.md section Pattern 1"
      fi
    fi
  done < <(grep -nP "\.map\(\s*async" "$file" 2>/dev/null)

  while IFS=: read -r linenum content; do
    [ -z "$linenum" ] && continue
    context=$(sed -n "${linenum},$((linenum + 8))p" "$file" 2>/dev/null)
    if echo "$context" | grep -qP "await.*(find|query|select|prisma\.|supabase\.|db\.)"; then
      log_finding "LINEAR" "N+1 query (for-loop+await)" "$file" "$linenum" \
        "1 + N queries where N = iteration count. Documented case: \$12,000/month from this exact pattern."
    fi
  done < <(grep -nP "for\s*\(" "$file" 2>/dev/null)

done

# ─────────────────────────────────────────────────────
# PATTERN 2: Accidental Fan-Out
# ─────────────────────────────────────────────────────
[ "$QUIET" = false ] && echo "── Scanning: fan-out patterns ───────────────────"

for file in "${SCAN_FILES[@]}"; do
  [ -f "$file" ] || continue

  while IFS=: read -r linenum content; do
    [ -z "$linenum" ] && continue
    fn_body=$(sed -n "${linenum},$((linenum + 30))p" "$file" 2>/dev/null)
    external_calls=$(echo "$fn_body" | grep -cP "await.*(fetch|axios|http\.|\.send\(|\.publish\(|\.notify\(|api\.)")
    if [ "$external_calls" -ge 3 ]; then
      log_finding "SUPRALINEAR" "Possible fan-out — $external_calls sequential external calls in one function" "$file" "$linenum" \
        "Multiple downstream calls per event. See reference/cost-pattern-playbook.md section Pattern 2"
    fi
  done < <(grep -nP "^\s*(async )?function|^\s*async \w+\(" "$file" 2>/dev/null)

done

# ─────────────────────────────────────────────────────
# PATTERN 3: Runaway Retry Loop
# ─────────────────────────────────────────────────────
[ "$QUIET" = false ] && echo "── Scanning: unbounded retry loops ──────────────"

for file in "${SCAN_FILES[@]}"; do
  [ -f "$file" ] || continue

  while IFS=: read -r linenum content; do
    [ -z "$linenum" ] && continue
    context=$(sed -n "${linenum},$((linenum + 15))p" "$file" 2>/dev/null)
    if echo "$context" | grep -qP "catch|except" && ! echo "$context" | grep -qP "max_attempts|maxAttempts|MAX_RETRIES|attempt\s*[<>=]|attempts\s*[<>=]"; then
      log_finding "RUNAWAY" "Unbounded retry loop (while true, no max attempts)" "$file" "$linenum" \
        "No maximum attempt count. A single dependency failure produces unbounded cost. See Pattern 3."
    fi
  done < <(grep -nP "while\s*\(\s*true\s*\)|while\s+True\s*:" "$file" 2>/dev/null)

  while IFS=: read -r linenum content; do
    [ -z "$linenum" ] && continue
    startline=$((linenum - 5))
    [ "$startline" -lt 1 ] && startline=1
    context=$(sed -n "${startline},$((linenum + 5))p" "$file" 2>/dev/null)
    if ! echo "$context" | grep -qP "max|limit|< *[0-9]|<=\s*[0-9]"; then
      log_finding "RUNAWAY" "Retry counter with no visible maximum" "$file" "$linenum" \
        "Retry/attempt counter increments with no enforced ceiling. See Pattern 3."
    fi
  done < <(grep -nP "(retry|retries|attempts)\s*[+][+]|\+\+\s*(retry|retries|attempts)" "$file" 2>/dev/null)

done

# ─────────────────────────────────────────────────────
# PATTERN 4: Unbounded Storage
# ─────────────────────────────────────────────────────
[ "$QUIET" = false ] && echo "── Scanning: unbounded storage writes ───────────"

for file in "${SCAN_FILES[@]}"; do
  [ -f "$file" ] || continue

  file_content=$(cat "$file" 2>/dev/null)
  has_retention=false
  echo "$file_content" | grep -qiP "ttl|expire|retention|archive|cutoff|deleteMany.*createdAt" && has_retention=true

  if [ "$has_retention" = false ]; then
    while IFS=: read -r linenum content; do
      [ -z "$linenum" ] && continue
      log_finding "LINEAR" "Unbounded storage write, no retention policy detected in file" "$file" "$linenum" \
        "Storage table grows indefinitely with no TTL or archival. See Pattern 4."
    done < <(grep -nP "\.(create|insert|put|save)\(.*\{.*\}\)" "$file" 2>/dev/null | grep -iP "(log|history|interaction|event|audit|activity)")
  fi
done

# ─────────────────────────────────────────────────────
# PATTERN 5: Lazy Auto-Scaling
# Lives in infra config, not application code — this is why yml/yaml is in
# the file filter above even though every other pattern here targets ts/js/py.
# ─────────────────────────────────────────────────────
[ "$QUIET" = false ] && echo "── Scanning: autoscaling configs with no concurrency cap ──"

for file in "${SCAN_FILES[@]}"; do
  [ -f "$file" ] || continue
  case "$file" in
    *.yml|*.yaml) ;;
    *) continue ;;
  esac

  file_content=$(cat "$file" 2>/dev/null)
  if echo "$file_content" | grep -qiP "^\s*functions:|handler:\s*\S|kind:\s*(Deployment|HorizontalPodAutoscaler)"; then
    if ! echo "$file_content" | grep -qiP "reservedConcurrency|maxInstances|max_instances|maxReplicas|concurrency:\s*[0-9]"; then
      linenum=$(grep -nP "^\s*functions:|handler:\s*\S|kind:\s*(Deployment|HorizontalPodAutoscaler)" "$file" 2>/dev/null | head -1 | cut -d: -f1)
      [ -z "$linenum" ] && linenum=1
      log_finding "SUPRALINEAR" "Autoscaling/function config with no concurrency or instance cap" "$file" "$linenum" \
        "No reservedConcurrency/maxInstances/maxReplicas cap found. Escalates to RUNAWAY if combined with an unbounded retry loop. See reference/cost-pattern-playbook.md section Pattern 5."
    fi
  fi
done

# ─────────────────────────────────────────────────────
# PATTERN 6: Missing Cache on Expensive Operation
# ─────────────────────────────────────────────────────
[ "$QUIET" = false ] && echo "── Scanning: missing cache on expensive GET endpoints ──"

for file in "${SCAN_FILES[@]}"; do
  [ -f "$file" ] || continue

  while IFS=: read -r linenum content; do
    [ -z "$linenum" ] && continue
    context=$(sed -n "${linenum},$((linenum + 20))p" "$file" 2>/dev/null)
    has_join_or_aggregate=$(echo "$context" | grep -cP "JOIN|groupBy|aggregate|reduce\(")
    has_cache=$(echo "$context" | grep -cP "cache\.|Cache-Control|redis\.|memcache")
    if [ "$has_join_or_aggregate" -gt 0 ] && [ "$has_cache" -eq 0 ]; then
      log_finding "SUPRALINEAR" "Expensive aggregation/JOIN on GET endpoint with no caching" "$file" "$linenum" \
        "Recomputed on every request instead of cached. See Pattern 6."
    fi
  done < <(grep -nP "@Get\(" "$file" 2>/dev/null)

done

# ─────────────────────────────────────────────────────
# PATTERN 7: LLM Agent Loop Unbounded
# ─────────────────────────────────────────────────────
[ "$QUIET" = false ] && echo "── Scanning: unbounded agent/LLM loops ──────────"

for file in "${SCAN_FILES[@]}"; do
  [ -f "$file" ] || continue

  while IFS=: read -r linenum content; do
    [ -z "$linenum" ] && continue
    context=$(sed -n "${linenum},$((linenum + 15))p" "$file" 2>/dev/null)
    calls_llm=$(echo "$context" | grep -cP "llm\.|openai\.|anthropic\.|\.chat\(|\.complete\(|messages\.create")
    has_max=$(echo "$context" | grep -cP "max_iter|MAX_ITER|iteration.*<|iterations.*<")
    if [ "$calls_llm" -gt 0 ] && [ "$has_max" -eq 0 ]; then
      log_finding "RUNAWAY" "Agentic loop with no maximum iteration cap, calls LLM per iteration" "$file" "$linenum" \
        "Token cost is unbounded if completion condition never triggers. See Pattern 7."
    fi
  done < <(grep -nP "while.*(is_complete|complete\(\)|done\(\)|finished)" "$file" 2>/dev/null)

done

# ─────────────────────────────────────────────────────
# PATTERN 8: Per-Item Paid API Call
# ─────────────────────────────────────────────────────
[ "$QUIET" = false ] && echo "── Scanning: per-item paid API calls in loops ───"

for file in "${SCAN_FILES[@]}"; do
  [ -f "$file" ] || continue

  while IFS=: read -r linenum content; do
    [ -z "$linenum" ] && continue
    context=$(sed -n "${linenum},$((linenum + 8))p" "$file" 2>/dev/null)
    if echo "$context" | grep -qiP "await.*(enrichment|geocod|sms\.|twilio|stripe\.|sendgrid|payment.*api)"; then
      log_finding "LINEAR" "Per-item paid third-party API call inside loop" "$file" "$linenum" \
        "Check whether the provider offers a batch endpoint. See Pattern 8."
    fi
  done < <(grep -nP "for\s*\(|\.map\(|\.forEach\(" "$file" 2>/dev/null)

done

# ─────────────────────────────────────────────────────
# GATE DECISION
# ─────────────────────────────────────────────────────
if [ "$FORMAT" = "json" ]; then
  findings_joined=""
  if [ "${#JSON_FINDINGS[@]}" -gt 0 ]; then
    findings_joined=$(IFS=,; echo "${JSON_FINDINGS[*]}")
  fi
  printf '{"runaway_count":%d,"quadratic_count":%d,"supralinear_count":%d,"linear_count":%d,"suppressed_count":%d,"findings":[%s]}\n' \
    "$RUNAWAY_COUNT" "$QUADRATIC_COUNT" "$SUPRALINEAR_COUNT" "$LINEAR_COUNT" "$SUPPRESSED_COUNT" "$findings_joined"
fi

if [ "$QUIET" = false ]; then
  echo ""
  echo "═══════════════════════════════════════════════════"
  if [ "$RUNAWAY_COUNT" -gt 0 ] || [ "$QUADRATIC_COUNT" -gt 0 ]; then
    echo "  GATE: 🔴 BLOCK"
  elif [ "$SUPRALINEAR_COUNT" -gt 0 ]; then
    echo "  GATE: 🟠 WARN"
  else
    echo "  GATE: 🟢 PASS"
  fi
  echo ""
  echo "  ⚫ RUNAWAY:      $RUNAWAY_COUNT"
  echo "  🔴 QUADRATIC+:   $QUADRATIC_COUNT"
  echo "  🟠 SUPRALINEAR:  $SUPRALINEAR_COUNT"
  echo "  🟡 LINEAR:       $LINEAR_COUNT"
  echo "  ⚪ SUPPRESSED:   $SUPPRESSED_COUNT"
  echo ""
  echo "  NEXT: Project dollar cost with scale assumptions:"
  echo "    → bash scripts/estimate-impact.sh --pattern n1_query --records N --requests-per-day N"
  echo "  Populate confirmed findings into: templates/cost-impact-report.md"
  echo "═══════════════════════════════════════════════════"
  echo ""
fi

# Exit code drives the CI gate — 1 if BLOCK, 0 otherwise
if [ "$RUNAWAY_COUNT" -gt 0 ] || [ "$QUADRATIC_COUNT" -gt 0 ]; then
  exit 1
else
  exit 0
fi
