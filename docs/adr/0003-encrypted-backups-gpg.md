# ADR 0003: Encrypted Backups with GPG and Isolated Systemd

## Context
Database dumps and user uploads contain sensitive user data and must be protected at rest.

## Decision
Run backups via dedicated systemd timers under a restricted service account (`gym-backup`). Encrypt using GPG symmetric AES-256 with root-restricted passphrases.

## Consequences
- Data at rest is encrypted before moving to offsite/backup storage.
- Principle of least privilege enforced via systemd security sandboxing.
