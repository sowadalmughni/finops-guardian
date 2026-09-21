#!/usr/bin/env bash
# =============================================================================
# FinOps Guardian — Scale-Based Cost Projector
# Md. Sowad Al-Mughni | Kitalon Labs | www.kitalonlabs.com
# https://github.com/sowadalmughni/finops-guardian
#
# USAGE:  bash scripts/estimate-impact.sh --pattern n1_query --records 10000 --requests-per-day 500
#         bash scripts/estimate-impact.sh --pattern retry_loop_unbounded --attempts 21600 --cost-per-attempt 0.01
#
# Projects dollar cost at current, 10x, and 100x scale for a given pattern,
# using the unit costs and growth formulas in metrics/cloud-cost-heuristics.json
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HEURISTICS="$SCRIPT_DIR/../metrics/cloud-cost-heuristics.json"

PATTERN=""
RECORDS=1000
REQUESTS_PER_DAY=100
ATTEMPTS=0
COST_PER_ATTEMPT=0
GB_STORED=0
ITEM_COUNT=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --pattern)            PATTERN="$2"; shift 2 ;;
    --records)            RECORDS="$2"; shift 2 ;;
    --requests-per-day)   REQUESTS_PER_DAY="$2"; shift 2 ;;
    --attempts)           ATTEMPTS="$2"; shift 2 ;;
    --cost-per-attempt)   COST_PER_ATTEMPT="$2"; shift 2 ;;
    --gb-stored)          GB_STORED="$2"; shift 2 ;;
    --item-count)         ITEM_COUNT="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: estimate-impact.sh --pattern PATTERN [options]"
      echo ""
      echo "Patterns: n1_query, fan_out, retry_loop_unbounded, unbounded_storage,"
      echo "          lazy_autoscaling, missing_cache, llm_agent_loop_unbounded,"
      echo "          per_item_paid_api_call"
      echo ""
      echo "Options:"
      echo "  --records N              Result set size for N+1 queries (default: 1000)"
      echo "  --requests-per-day N     Daily request volume (default: 100)"
      echo "  --attempts N             Total retry/iteration attempts for RUNAWAY patterns"
      echo "  --cost-per-attempt N     Dollar cost of each attempt (default: DB query cost)"
      echo "  --gb-stored N            Accumulated storage in GB for storage patterns"
      echo "  --item-count N           Item count for per-item API call patterns"
      exit 0
      ;;
    *) shift ;;
  esac
done

if [ -z "$PATTERN" ]; then
  echo "ERROR: --pattern is required. Use --help for usage."
  exit 1
fi

if ! command -v python3 &>/dev/null; then
  echo "ERROR: python3 is required to parse cost heuristics JSON."
  exit 1
fi

echo ""
echo "═══════════════════════════════════════════════════"
echo "  FINOPS GUARDIAN — COST PROJECTION"
echo "  Pattern: $PATTERN"
echo "  https://github.com/sowadalmughni/finops-guardian"
echo "═══════════════════════════════════════════════════"
echo ""

python3 - "$HEURISTICS" "$PATTERN" "$RECORDS" "$REQUESTS_PER_DAY" "$ATTEMPTS" "$COST_PER_ATTEMPT" "$GB_STORED" "$ITEM_COUNT" << 'PYEOF'
import json
import sys

heuristics_path, pattern, records, requests_per_day, attempts, cost_per_attempt, gb_stored, item_count = sys.argv[1:9]
records = int(records)
requests_per_day = int(requests_per_day)
attempts = int(attempts)
cost_per_attempt = float(cost_per_attempt)
gb_stored = float(gb_stored)
item_count = int(item_count)

with open(heuristics_path) as f:
    data = json.load(f)

unit = data['unit_costs']
models = data['pattern_growth_models']

def fmt(x):
    if x == 0:
        return "$0.00"
    if x < 0.01:
        # Show enough significant figures that a small unit cost never displays as zero
        return f"${x:.8f}".rstrip('0').ljust(len(f"${x:.2f}"), '0') if x >= 0.00000001 else f"${x:.2e}"
    return f"${x:,.2f}"

def print_scale_table(monthly_cost, label):
    print(f"\n  {label}")
    print(f"  {'Scale':<12} {'Monthly Cost':>16}")
    print(f"  {'-'*12} {'-'*16}")
    print(f"  {'Current':<12} {fmt(monthly_cost):>16}")
    print(f"  {'10x':<12} {fmt(monthly_cost * 10):>16}")
    print(f"  {'100x':<12} {fmt(monthly_cost * 100):>16}")

if pattern == "n1_query":
    read_cost = unit['database']['postgres_read_query']['mid']
    per_page_cost = (1 + records) * read_cost
    monthly_cost = per_page_cost * requests_per_day * 30
    print(f"  Formula: (1 + N) queries × cost/query × requests/day × 30")
    print(f"  N (result set size): {records:,}")
    print(f"  Cost per query: {fmt(read_cost)}")
    print(f"  Requests/day: {requests_per_day:,}")
    print_scale_table(monthly_cost, "Projected monthly database query cost")
    print(f"\n  Note: at scale, connection pool exhaustion becomes the dominant risk")
    print(f"  well before raw query cost does. Pool exhaustion incidents cost")
    print(f"  {fmt(unit['database']['connection_pool_exhaustion']['low'])}-{fmt(unit['database']['connection_pool_exhaustion']['high'])} per incident.")

elif pattern == "retry_loop_unbounded" or pattern == "llm_agent_loop_unbounded":
    if attempts == 0:
        attempts = 21600  # default: 1/sec for 6 hours, matches documented case
    if cost_per_attempt == 0:
        cost_per_attempt = unit['third_party_api']['generic_paid_api_call']['mid']
    incident_cost = attempts * cost_per_attempt
    print(f"  Formula: attempts × cost/attempt")
    print(f"  Attempts before manual intervention: {attempts:,}")
    print(f"  Cost per attempt: {fmt(cost_per_attempt)}")
    print(f"\n  Projected cost from ONE stuck loop incident: {fmt(incident_cost)}")
    print(f"  If this occurs on {requests_per_day} concurrent requests during an outage:")
    print(f"    Total incident cost: {fmt(incident_cost * requests_per_day)}")
    print(f"\n  RUNAWAY classification: this is not a monthly recurring cost —")
    print(f"  it is unbounded PER INCIDENT. A single failure event can produce")
    print(f"  this cost regardless of current traffic level.")

elif pattern == "unbounded_storage":
    storage_cost = unit['storage']['object_storage_gb_month']['mid']
    if gb_stored == 0:
        gb_stored = 1.0
    monthly_cost = gb_stored * storage_cost
    print(f"  Formula: GB stored × cost/GB-month")
    print(f"  GB accumulated: {gb_stored:,.2f}")
    print(f"  Cost per GB-month: {fmt(storage_cost)}")
    print_scale_table(monthly_cost, "Projected monthly storage cost")
    print(f"\n  Note: unlike other patterns, this cost is CUMULATIVE and COMPOUNDS")
    print(f"  every month with no retention policy — month 12's bill includes")
    print(f"  every byte stored since month 1.")

elif pattern == "per_item_paid_api_call":
    api_cost = unit['third_party_api']['generic_paid_api_call']['mid']
    if item_count == 0:
        item_count = records
    monthly_cost = item_count * api_cost
    batch_cost = monthly_cost * 0.45  # typical batch discount midpoint
    print(f"  Formula: item count × cost/item")
    print(f"  Items/month: {item_count:,}")
    print(f"  Cost per item (per-item endpoint): {fmt(api_cost)}")
    print_scale_table(monthly_cost, "Projected monthly cost (per-item endpoint)")
    print(f"\n  Estimated cost if using a BATCH endpoint instead (~45-60% of per-item rate):")
    print_scale_table(batch_cost, "Projected monthly cost (batch endpoint)")
    print(f"\n  Estimated monthly savings from switching to batch: {fmt(monthly_cost - batch_cost)}")

elif pattern == "fan_out":
    avg_call_cost = unit['third_party_api']['generic_paid_api_call']['mid']
    calls_per_event = 3  # conservative default for a fan-out finding
    per_event_cost = calls_per_event * avg_call_cost
    monthly_cost = per_event_cost * requests_per_day * 30
    print(f"  Formula: downstream calls/event × cost/call × events/day × 30")
    print(f"  Assumed downstream calls per event: {calls_per_event}")
    print(f"  Cost per call: {fmt(avg_call_cost)}")
    print(f"  Events/day: {requests_per_day:,}")
    print_scale_table(monthly_cost, "Projected monthly fan-out cost")

elif pattern == "missing_cache":
    read_cost = unit['database']['postgres_read_query']['mid'] * 20  # aggregation multiplier
    uncached_monthly = read_cost * requests_per_day * 30
    # Assume underlying data changes ~24x/day (hourly) vs polled every request
    cached_monthly = read_cost * min(24, requests_per_day) * 30
    print(f"  Formula: uncached = requests × cost/computation × 30")
    print(f"           cached   = actual_changes × cost/computation × 30")
    print(f"  Requests/day: {requests_per_day:,}")
    print_scale_table(uncached_monthly, "Projected monthly cost — UNCACHED")
    print_scale_table(cached_monthly, "Projected monthly cost — CACHED (hourly TTL assumed)")
    print(f"\n  Estimated monthly savings from caching: {fmt(uncached_monthly - cached_monthly)}")

elif pattern == "lazy_autoscaling":
    vcpu_cost = unit['compute']['container_vcpu_hour']['mid']
    peak_instances = 500  # documented incident scale default
    incident_hours = 2
    incident_cost = peak_instances * vcpu_cost * incident_hours
    print(f"  Formula: peak concurrent instances × cost/vCPU-hour × incident duration")
    print(f"  Assumed peak instances during incident: {peak_instances}")
    print(f"  Cost per vCPU-hour: {fmt(vcpu_cost)}")
    print(f"  Assumed incident duration: {incident_hours} hours")
    print(f"\n  Projected cost from ONE scaling incident: {fmt(incident_cost)}")
    print(f"  This compounds multiplicatively if combined with a retry storm (see Pattern 3).")

else:
    print(f"  Unknown pattern: '{pattern}'")
    print(f"  Available patterns: {list(models.keys())}")
    sys.exit(1)

print()
print("  All figures are directional estimates based on metrics/cloud-cost-heuristics.json")
print("  Adjust unit costs in that file to match your actual provider and tier for accuracy.")
PYEOF

echo ""
echo "═══════════════════════════════════════════════════"
echo ""
