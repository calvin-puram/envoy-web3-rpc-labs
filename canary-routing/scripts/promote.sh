#!/bin/bash


ENVOY_ADMIN="http://localhost:9901"
DRY_RUN=false
PASS=0
FAIL=0

# SLO Thresholds
MAX_ERROR_RATE="1.0"         # max canary error rate (%)
MAX_ERROR_DELTA="0.1"        # max canary vs stable error rate delta (%)
MAX_LATENCY_REGRESSION="1.2" # max canary/stable latency ratio
MAX_CB_OVERFLOW="0"          # max circuit breaker overflow events

# Promotion Stages
# Format: "canary_weight:stable_weight:observe_seconds:description"
STAGES=(
  "20:80:60:Initial validation (20% canary)"
  "50:50:120:Parity test (50/50 split)"
  "100:0:120:Full promotion (100% canary)"
)

# Argument Parsing
for arg in "$@"; do
  case $arg in
    --dry-run) DRY_RUN=true ;;
    *) echo "Unknown argument: $arg"; exit 1 ;;
  esac
done

# Helpers
log()     { echo "[$(date +%T)] $*"; }
pass()    { echo "  ✓ $*"; ((PASS++)); }
fail()    { echo "  ✗ $*"; ((FAIL++)); }
header()  { echo ""; echo "======================"; echo "  $*"; echo "======================"; }
dry_log() { $DRY_RUN && echo "  [DRY RUN] $*" || true; }

stat() {
  local key="$1"
  curl -s "$ENVOY_ADMIN/stats" \
    | grep "^${key}:" \
    | awk -F': ' '{print $2}' \
    | tr -d ' ' \
    || echo "0"
}

set_weight() {
  local canary_weight="$1"
  local stable_weight="$2"

  if $DRY_RUN; then
    dry_log "Would set: canary=$canary_weight stable=$stable_weight"
    return 0
  fi

  curl -s -X POST "$ENVOY_ADMIN/runtime_modify" \
    --data "routing.traffic_shift.canary=${canary_weight}&routing.traffic_shift.stable=${stable_weight}" \
    > /dev/null

  log "Weight updated  canary=${canary_weight}% stable=${stable_weight}%"
}

rollback() {
  local reason="$1"
  header "ROLLBACK TRIGGERED"
  log "Reason: $reason"
  log "Shifting 100% traffic back to stable..."

  if ! $DRY_RUN; then
    curl -s -X POST "$ENVOY_ADMIN/runtime_modify" \
      --data "routing.traffic_shift.canary=0&routing.traffic_shift.stable=100" \
      > /dev/null
  fi

  log "✓ Rollback complete — 100% traffic on stable"
  exit 1
}

check_slos() {
  local stage_desc="$1"
  log "Evaluating SLOs for: $stage_desc"

  # Error Rates
  local stable_total canary_total stable_5xx canary_5xx
  stable_total=$(stat "cluster.stable.upstream_rq_total")
  canary_total=$(stat "cluster.canary.upstream_rq_total")
  stable_5xx=$(stat "cluster.stable.upstream_rq_5xx")
  canary_5xx=$(stat "cluster.canary.upstream_rq_5xx")

  # Avoid division by zero
  if [ "${stable_total:-0}" -eq 0 ] || [ "${canary_total:-0}" -eq 0 ]; then
    log "  Insufficient traffic for SLO evaluation — skipping"
    return 0
  fi

  local stable_error_rate canary_error_rate error_delta
  stable_error_rate=$(echo "scale=4; ${stable_5xx:-0} / $stable_total * 100" | bc)
  canary_error_rate=$(echo "scale=4; ${canary_5xx:-0} / $canary_total * 100" | bc)
  error_delta=$(echo "scale=4; $canary_error_rate - $stable_error_rate" | bc)

  log "  Stable error rate:  ${stable_error_rate}%"
  log "  Canary error rate:  ${canary_error_rate}%"
  log "  Error rate delta:   ${error_delta}%"

  # Check absolute canary error rate
  if (( $(echo "$canary_error_rate > $MAX_ERROR_RATE" | bc -l) )); then
    fail "Canary error rate ${canary_error_rate}% exceeds threshold ${MAX_ERROR_RATE}%"
    rollback "Canary error rate too high: ${canary_error_rate}%"
  else
    pass "Canary error rate ${canary_error_rate}% within threshold"
  fi

  # Check error rate delta (canary vs stable)
  if (( $(echo "$error_delta > $MAX_ERROR_DELTA" | bc -l) )); then
    fail "Error rate delta ${error_delta}% exceeds threshold ${MAX_ERROR_DELTA}%"
    rollback "Canary error rate significantly worse than stable"
  else
    pass "Error rate delta ${error_delta}% within tolerance"
  fi

  # Circuit Breaker Overflow
  local canary_overflow
  canary_overflow=$(stat "cluster.canary.upstream_rq_pending_overflow")

  if [ "${canary_overflow:-0}" -gt "$MAX_CB_OVERFLOW" ]; then
    fail "Canary circuit breaker overflow: $canary_overflow events"
    rollback "Canary circuit breaker overflowing — node cannot handle load"
  else
    pass "No circuit breaker overflow on canary"
  fi

  # Outlier Detection
  local canary_ejections
  canary_ejections=$(stat "cluster.canary.outlier_detection.ejections_active")

  if [ "${canary_ejections:-0}" -gt 0 ]; then
    fail "Canary host ejected by outlier detection (ejections_active: $canary_ejections)"
    rollback "Canary node ejected — consecutive failures detected"
  else
    pass "No active outlier ejections on canary"
  fi
}

# Main
header "Canary Promotion$(${DRY_RUN} && echo ' [DRY RUN]' || echo '')"
log "Starting with 5% canary / 95% stable"
log "SLO thresholds:"
log "  Max canary error rate: ${MAX_ERROR_RATE}%"
log "  Max error rate delta:  ${MAX_ERROR_DELTA}%"
log "  CB overflow allowed:   ${MAX_CB_OVERFLOW}"

# Verify Envoy is reachable
if ! curl -s "$ENVOY_ADMIN/ready" > /dev/null 2>&1; then
  log "ERROR: Envoy admin not reachable at $ENVOY_ADMIN"
  log "Run: docker compose up -d"
  exit 1
fi

# Ensure we start at 5%
set_weight 5 95
sleep 5

# Promotion Stages
STAGE_NUM=0
for stage in "${STAGES[@]}"; do
  ((STAGE_NUM++))

  IFS=':' read -r canary_weight stable_weight observe_secs description <<< "$stage"

  header "Stage ${STAGE_NUM}/${#STAGES[@]}: $description"

  log "Shifting traffic → canary=${canary_weight}% stable=${stable_weight}%"
  set_weight "$canary_weight" "$stable_weight"

  log "Observing for ${observe_secs}s..."
  if ! $DRY_RUN; then
    sleep "$observe_secs"
  fi

  check_slos "$description"
done

# Promotion Complete
header "Promotion Complete"
log "✓ Canary fully promoted  100% traffic on canary"
log ""
log "Next steps:"
log "  1. Monitor canary node for 24h before decommissioning stable"
log "  2. Update envoy.yaml default weights (canary=100, stable=0)"
log "  3. Rename canary → stable in your deployment"
log "  4. Remove stable node after confirmation period"
log ""
log "Results: $PASS checks passed, $FAIL checks failed"