# ADR 0001: Caddy Reverse Proxy on Host

## Context
Needed a reverse proxy to terminate TLS, route traffic to backend/frontend slots, and protect metrics/webhooks.

## Decision
Run Caddy directly on host via systemd rather than inside a Docker container.

## Consequences
- Clean loopback access (127.0.0.1:8101, 8201, 3000, 9000).
- Automatic TLS certificate issuance and reload without dropping active connections.
