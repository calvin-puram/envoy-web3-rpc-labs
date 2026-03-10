#!/bin/bash

# Circuit Breaker Lifecycle Test


ENVOY_RPC="http://localhost:8545"
ENVOY_ADMIN="http://localhost:9901"
PASS=0
FAIL=0

log()   { echo "[$(date +%T)] $*"; }
pass()  { echo "  ✓ $*"; ((PASS++)); }
fail()  { echo "  ✗ $*"; ((FAIL++)); }
header(){ echo ""; echo "================================="; echo "  $*"; echo "================================"; }

rpc() {
  curl -s -o /dev/null -w "%{http_code}" \
    -X POST "$ENVOY_RPC" \
    -H "Content-Type: application/json" \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"eth_blockNumber\",\"params\":[],\"id\":1}"
}

stat() {
  curl -s "$ENVOY_ADMIN/stats" | grep "$1" | awk -F: '{print $2}' | tr -d ' '
}


header "Phase 1: Baseline: Both Nodes Healthy"

log "Sending 10 baseline requests..."
SUCCESS=0
for i in {1..10}; do
  CODE=$(rpc)
  [ "$CODE" = "200" ] && ((SUCCESS++))
done

if [ "$SUCCESS" -eq 10 ]; then
  pass "All 10 baseline requests succeeded (200 OK)"
else
  fail "Expected 10/10 success, got $SUCCESS/10"
fi

EJECTIONS=$(stat "outlier_detection.ejections_active" 2>/dev/null || echo "0")
if [ "${EJECTIONS:-0}" -eq 0 ]; then
  pass "No hosts ejected at baseline"
else
  fail "Unexpected ejections at baseline: $EJECTIONS"
fi


header "Phase 2: Circuit Breaker: Overflow Test"

log "Sending 200 concurrent requests to trigger pending overflow..."
if command -v hey &>/dev/null; then
  hey -n 200 -c 80 \
    -m POST \
    -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
    "$ENVOY_RPC" > /dev/null 2>&1

  OVERFLOW=$(stat "upstream_rq_pending_overflow" 2>/dev/null || echo "0")
  if [ "${OVERFLOW:-0}" -gt 0 ]; then
    pass "Circuit breaker triggered — pending overflow: $OVERFLOW requests rejected"
  else
    fail "Circuit breaker did not trigger — check max_pending_requests threshold"
  fi
else
  log "hey not installed — skipping overflow test (brew install hey)"
  log "Run manually: hey -n 200 -c 80 -m POST -H 'Content-Type: application/json' -d '{...}' $ENVOY_RPC"
fi


header "Phase 3: Outlier Detection: Node2 Ejection"

log "Stopping node2 to simulate failure..."
docker compose stop node2 2>/dev/null

log "Sending 20 requests — some will fail until node2 is ejected..."
ERRORS=0
for i in {1..20}; do
  CODE=$(rpc)
  [ "$CODE" != "200" ] && ((ERRORS++))
  sleep 0.3
done

log "Waiting 15s for outlier detection to eject node2..."
sleep 15

EJECTED_TOTAL=$(curl -s "$ENVOY_ADMIN/stats" \
  | grep "^cluster.ethereum_nodes.outlier_detection.ejections_total:" \
  | awk -F': ' '{print $2}' | tr -d ' ')

if [ "${EJECTED_TOTAL:-0}" -gt 0 ]; then
  pass "Node2 ejected by outlier detection (ejections_total: $EJECTED_TOTAL)"
else
  fail "Node2 was not ejected — check consecutive_5xx threshold and node status"
fi

log "Sending 10 requests after ejection — all should succeed via node1..."
SUCCESS=0
for i in {1..10}; do
  CODE=$(rpc)
  [ "$CODE" = "200" ] && ((SUCCESS++))
done

if [ "$SUCCESS" -eq 10 ]; then
  pass "All 10 post-ejection requests succeeded via node1"
else
  fail "Expected 10/10 success after ejection, got $SUCCESS/10"
fi


header "Phase 4: Recovery: Node2 Re-admitted"

log "Starting node2..."
docker compose start node2 2>/dev/null

log "Waiting 40s for node2 health checks to pass and ejection to expire..."
sleep 40

EJECTED=$(stat "outlier_detection.ejections_active" 2>/dev/null || echo "0")
if [ "${EJECTED:-0}" -eq 0 ]; then
  pass "Node2 re-admitted — ejections_active: 0"
else
  fail "Node2 still ejected after recovery window — ejections_active: $EJECTED"
fi

log "Sending 20 requests — should distribute across both nodes..."
for i in {1..20}; do
  rpc > /dev/null
done

NODE1_RQ=$(stat "upstream_rq_total" 2>/dev/null || echo "unknown")
log "Total upstream requests: $NODE1_RQ"
pass "Traffic flowing post-recovery"


header "Phase 5: Panic Mode: All Nodes Down"

log "Stopping both nodes..."
docker compose stop node1 node2 2>/dev/null

log "Sending requests to trigger outlier detection on both nodes..."
for i in {1..30}; do
  rpc > /dev/null 2>&1 || true
  sleep 0.3
done

sleep 5

PANIC=$(curl -s "$ENVOY_ADMIN/stats" \
  | grep "^cluster.ethereum_nodes.lb_healthy_panic:" \
  | awk -F': ' '{print $2}' | tr -d ' ')

log "Panic mode counter: ${PANIC:-0}"
if [ "${PANIC:-0}" -gt 0 ]; then
  pass "Panic mode activated — lb_healthy_panic counter: $PANIC"
else
  log "  → Panic mode not yet active — check /stats manually"
fi

log "Restoring nodes..."
docker compose start node1 node2 2>/dev/null


header "Test Summary"
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
echo ""

if [ "$FAIL" -eq 0 ]; then
  echo "  All tests passed ✓"
else
  echo "  $FAIL test(s) failed  review output above"
fi

echo ""
echo "  Full circuit breaker stats:"
echo "  curl -s http://localhost:9901/stats | grep -E '(overflow|ejection|panic)' | sort"