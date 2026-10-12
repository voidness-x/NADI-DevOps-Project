# ADR 0005: Local Prometheus and Grafana Observability

## Context
The stack needs performance tracking, container health, and SLI/SLO dashboards.

## Decision
Deploy Prometheus and Grafana as Docker containers scraping local node-exporter, postgres-exporter, and caddy.

## Consequences
- Real-time visibility into CPU, memory, database connection pools, and HTTP response latencies.
