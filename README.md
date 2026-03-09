# envoy-web3-rpc-labs

A collection of hands on labs exploring Envoy Proxy
for blockchain RPC infrastructure.

## Labs

| # | Lab | Concepts |
|---|-----|----------|
| 01 | RPC Load Balancing | Round-robin, health checks, failover |
| 02 | RPC Rate Limiting | Token bucket, per-IP limits |
| 03 | WebSocket Management | Upgrades, sticky sessions |
| 04 | RPC Tracing | Jaeger, distributed tracing |
| 05 | Circuit Breaking | Failure detection, fast fail |
| 06 | Canary Routing | Weighted traffic, safe upgrades |
| 07 | Fault Injection | Chaos engineering, resilience testing |

## Prerequisites
- Docker
- Docker Compose
- curl / jq

## How to Run Each Lab
cd into any lab folder and run:
\`\`\`bash
docker-compose up -d
\`\`\`