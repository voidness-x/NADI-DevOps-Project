# ADR 0002: Atomic Symlink Blue/Green Switch

## Context
Deployments require zero-downtime traffic switching with immediate rollback.

## Decision
Caddy imports `/etc/caddy/slots/active.caddy`, an atomic symlink pointing to `blue.caddy` or `green.caddy`.

## Consequences
- Atomic filesystem replacement (`ln -sfn ... && mv -T ...`) ensures Caddy never reads partial state.
- Rollback is instantaneous by pointing the symlink back.
