# Envoy Web3 RPC Labs

> **Note:** Etherem Geth runs in `--dev` mode (single-node, instant mining, no peers).
> Envoy, Prometheus, and Grafana have no authentication configured.
> Intended for local lab use only do not expose these ports in production.

## Overview

This is a hands on lab series where I apply SRE principles to Web3 node infrastructure using Envoy proxy patterns.

Start with lab 01 and work your way through. Each lab builds on the last, and every lab has all the necessary config files you need to get started.

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
- Basic familiarity with Ethereum JSON-RPC
- Basic familiarity with Envoy configuration (YAML)

## How to Run Each Lab
cd into any lab folder and run:
```bash
git clone https://github.com/calvinpuram/envoy-web3-rpc-labs.git
cd envoy-web3-rpc-labs/load-balancing

docker compose up -d
```

