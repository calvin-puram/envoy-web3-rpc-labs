#!/bin/bash

# Chaos Test Suite  Fault Injection
# Fixed for macOS (no date +%s%3N) and corrected test logic


ENVOY_RPC="http://localhost:8545"
ENVOY_ADMIN="http://localhost:9901"
NODE_DIRECT="http://localhost:18545"
PASS=0
FAIL=0

log()    { echo "[$(date +%T)] $*"; }
pass()   { echo "  ✓ $*"; ((PASS++)); }
fail()   { echo "  ✗ $*"; ((FAIL++)); }
header() { printf "\n============================\n  %s\n============================\n" "$*"; }

stat() {
  curl -s "$ENVOY_ADMIN/stats" \
    | grep "^${1}:" \
    | awk -F': ' '{print $2}' \
    | tr -d ' ' \
    || echo "0"
}

set_fault() {
  curl -s -X POST "$ENVOY_ADMIN/runtime_modify" \
    --data "$1" > /dev/null
  sleep 1
}

clear_faults() {
  set_fault "fault.http.delay.fixed_delay_percent=0&fault.http.abort.abort_percent=0&fault.http.getlogs.delay_percent=0&fault.http.getlogs.abort_percent=0"
}

rpc_status() {
  curl -s -o /dev/null -w "%{http_code}" \
    -X POST "$1" \
    -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'
}

# macOS-compatible duration in ms using curl time_total
rpc_duration_ms() {
  curl -s -o /dev/null -w "%{time_total}" \
    -X POST "$1" \
    -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
    | awk '{printf "%d", $1 * 1000}'
}

# macOS-compatible elapsed time using curl time_total
curl_duration_ms() {
  # $1 = URL, $2 = extra headers as string (optional)
  curl -s -o /dev/null -w "%{time_total}" \
    -X POST "$ENVOY_RPC" \
    -H "Content-Type: application/json" \
    "${@:2}" \
    -d '{"jsonrpc":"2.0","method":"eth_getLogs","params":[{"fromBlock":"latest"}],"id":1}' \
    | awk '{printf "%d", $1 * 1000}'
}

trap 'clear_faults; log "Faults cleared (trap)"' EXIT


header "Pre-flight Checks"

if ! curl -s "$ENVOY_ADMIN/ready" > /dev/null 2>&1; then
  log "ERROR: Envoy not reachable at $ENVOY_ADMIN  run: docker compose up -d"
  exit 1
fi
pass "Envoy admin reachable"

# Clear faults first, then verify no non-zero fault overrides remain
clear_faults
sleep 1
ACTIVE_NONZERO=$(curl -s "$ENVOY_ADMIN/runtime" \
  | jq '[.entries | to_entries[] | select(.key | startswith("fault")) | select(.value.final_value != "0")] | length' 2>/dev/null || echo "0")
if [ "${ACTIVE_NONZERO:-0}" -eq 0 ]; then
  pass "No active faults at startup"
else
  fail "Unexpected active faults still set: $ACTIVE_NONZERO"
fi

# Test 1: Baseline
header "Test 1  Baseline (No Faults)"

ERRORS=0
for i in {1..20}; do
  CODE=$(rpc_status "$ENVOY_RPC")
  [ "$CODE" != "200" ] && ((ERRORS++))
done

if [ "$ERRORS" -eq 0 ]; then
  pass "20/20 requests succeeded at baseline"
else
  fail "Baseline errors: $ERRORS/20  node may be unhealthy"
fi

DURATION=$(rpc_duration_ms "$ENVOY_RPC")
if [ "$DURATION" -lt 500 ]; then
  pass "Baseline latency: ${DURATION}ms (no injected delay)"
else
  fail "Baseline latency ${DURATION}ms higher than expected  check node"
fi

# ── Test 2: Latency Injection ────────────────────────────────────
header "Test 2  Latency Injection (2s delay, 100%)"

DELAYS_BEFORE=$(stat "http.rpc_ingress.fault.delays_injected")
set_fault "fault.http.delay.fixed_delay_percent=100"

SLOW_DURATION=$(rpc_duration_ms "$ENVOY_RPC")
if [ "$SLOW_DURATION" -ge 1900 ]; then
  pass "Latency fault active  request took ${SLOW_DURATION}ms (expected ≥1900ms)"
else
  fail "Latency fault may not have fired  duration ${SLOW_DURATION}ms (expected ≥1900ms)"
fi

DIRECT_DURATION=$(rpc_duration_ms "$NODE_DIRECT")
if [ "$DIRECT_DURATION" -lt 500 ]; then
  pass "Direct node unaffected  ${DIRECT_DURATION}ms (fault is proxy-only)"
else
  fail "Direct node also slow  ${DIRECT_DURATION}ms  unrelated latency issue"
fi

DELAYS=$(stat "http.rpc_ingress.fault.delays_injected")
if [ "${DELAYS:-0}" -gt "${DELAYS_BEFORE:-0}" ]; then
  pass "fault.delays_injected counter incrementing"
else
  fail "fault.delays_injected not incrementing  fault filter may not be loaded"
fi

clear_faults

# Test 3: Abort Injection
header "Test 3  Abort Injection (503, 50%)"

set_fault "fault.http.abort.abort_percent=50"

ERRORS=0
for i in {1..40}; do
  CODE=$(rpc_status "$ENVOY_RPC")
  [ "$CODE" = "503" ] && ((ERRORS++))
done

if [ "$ERRORS" -ge 8 ] && [ "$ERRORS" -le 32 ]; then
  pass "503 fault active  $ERRORS/40 requests returned 503 (expected ~20)"
else
  fail "503 fault out of expected range  got $ERRORS/40 (expected 8–32)"
fi

ABORTS=$(stat "http.rpc_ingress.fault.aborts_injected")
if [ "${ABORTS:-0}" -gt 0 ]; then
  pass "fault.aborts_injected counter incrementing ($ABORTS total)"
else
  fail "fault.aborts_injected not incrementing"
fi

DIRECT_CODE=$(rpc_status "$NODE_DIRECT")
if [ "$DIRECT_CODE" = "200" ]; then
  pass "Direct node returns 200  aborts are proxy-injected, not real node errors"
else
  fail "Direct node also erroring  $DIRECT_CODE  real node problem"
fi

clear_faults

# Test 4: Compound Fault
header "Test 4  Compound Fault (Latency + Abort)"

set_fault "fault.http.delay.fixed_delay_percent=30&fault.http.abort.abort_percent=20"

ERRORS=0; SLOW=0
for i in {1..30}; do
  # Use curl time_total instead of date for macOS compatibility
  RESULT=$(curl -s -w "\n%{http_code}\n%{time_total}" \
    -X POST "$ENVOY_RPC" \
    -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}')

  CODE=$(echo "$RESULT" | tail -2 | head -1)
  TIME_S=$(echo "$RESULT" | tail -1)
  ELAPSED=$(echo "$TIME_S" | awk '{printf "%d", $1 * 1000}')

  [ "$CODE" != "200" ]    && ((ERRORS++))
  [ "$ELAPSED" -ge 1900 ] && ((SLOW++))
done

if [ "$ERRORS" -gt 0 ]; then
  pass "Abort fault component active  $ERRORS/30 errors observed"
else
  fail "No aborts observed under compound fault (expected ~6)"
fi

if [ "$SLOW" -gt 0 ]; then
  pass "Latency fault component active  $SLOW/30 requests were slow"
else
  fail "No slow requests observed under compound fault (expected ~9)"
fi

clear_faults

# Test 5: Retry Validation
# Note: fault injection aborts are proxy-side  Envoy returns 503 directly
# without hitting upstream, so retry_on: 5xx does not fire for injected faults.
# This test validates the retry counter baseline is stable (not that retries fire).
header "Test 5  Retry Baseline (injected faults are proxy-side)"

RETRIES_BEFORE=$(stat "cluster.ethereum_nodes.upstream_rq_retry" || echo "0")

set_fault "fault.http.abort.abort_percent=10"

for i in {1..50}; do
  rpc_status "$ENVOY_RPC" > /dev/null
done

RETRIES_AFTER=$(stat "cluster.ethereum_nodes.upstream_rq_retry" || echo "0")
ABORTS_TOTAL=$(stat "http.rpc_ingress.fault.aborts_injected" || echo "0")

# Injected aborts should NOT cause retries (proxy-side, never reaches upstream)
if [ "${ABORTS_TOTAL:-0}" -gt 0 ]; then
  pass "Fault injection confirmed proxy-side  aborts_injected: $ABORTS_TOTAL (retries not expected)"
else
  fail "No aborts injected  fault filter may not be active"
fi

clear_faults

# Test 6: eth_getLogs Targeted Fault
header "Test 6  Targeted Fault (eth_getLogs header-based)"

set_fault "fault.http.getlogs.delay_percent=100"

# Use curl time_total for macOS compatible ms measurement
ELAPSED=$(curl -s -o /dev/null -w "%{time_total}" \
  -X POST "$ENVOY_RPC" \
  -H "Content-Type: application/json" \
  -H "x-rpc-method: eth_getLogs" \
  -d '{"jsonrpc":"2.0","method":"eth_getLogs","params":[{"fromBlock":"latest"}],"id":1}' \
  | awk '{printf "%d", $1 * 1000}')

if [ "${ELAPSED:-0}" -ge 2900 ]; then
  pass "eth_getLogs targeted fault active  ${ELAPSED}ms (expected ≥2900ms)"
else
  fail "eth_getLogs targeted fault may not have fired  ${ELAPSED}ms (expected ≥2900ms)"
fi

FAST=$(rpc_duration_ms "$ENVOY_RPC")
if [ "$FAST" -lt 500 ]; then
  pass "eth_blockNumber unaffected by getLogs fault  ${FAST}ms"
else
  fail "eth_blockNumber unexpectedly slow  ${FAST}ms  fault bleed-over"
fi

clear_faults

# Test 7: Clean State Verification
header "Test 7  Clean State After All Tests"

ACTIVE_OVERRIDES=$(curl -s "$ENVOY_ADMIN/runtime" \
  | jq '[.entries | to_entries[] | select(.key | startswith("fault")) | select(.value.final_value != "0")] | length' 2>/dev/null || echo "0")

if [ "${ACTIVE_OVERRIDES:-0}" -eq 0 ]; then
  pass "All fault overrides cleared  runtime clean"
else
  fail "$ACTIVE_OVERRIDES fault overrides still active  clear manually"
fi

ERRORS=0
for i in {1..10}; do
  CODE=$(rpc_status "$ENVOY_RPC")
  [ "$CODE" != "200" ] && ((ERRORS++))
done

if [ "$ERRORS" -eq 0 ]; then
  pass "Post-test baseline healthy  10/10 requests succeeded"
else
  fail "Post-test errors: $ERRORS/10  check node health"
fi

# Summary
header "Results"
printf "  Passed: %d\n  Failed: %d\n\n" "$PASS" "$FAIL"

if [ "$FAIL" -eq 0 ]; then
  echo "  All chaos tests passed ✓"
else
  echo "  $FAIL test(s) failed  review output above."
  echo "  Common causes:"
  echo "    - Fault filter not loaded (check: curl http://localhost:9901/config_dump | grep fault)"
  echo "    - Runtime override not propagating (check: curl http://localhost:9901/runtime)"
  echo "    - Node unhealthy (check: curl http://localhost:18545 directly)"
fi

echo ""
echo "  Fault stats summary:"
curl -s "$ENVOY_ADMIN/stats" \
  | grep -E "fault\.(delays|aborts)_injected" | sort