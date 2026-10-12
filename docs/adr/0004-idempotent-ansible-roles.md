# ADR 0004: Fully Idempotent Ansible Baseline

## Context
Host configuration must be reproducible across bare-metal or cloud VMs without drift.

## Decision
Implement modular Ansible roles (base, docker, caddy, gym_app, monitoring, backup) with zero changed tasks on second run.

## Consequences
- Any fresh VM can be provisioned into a full production host with a single `ansible-playbook` invocation.
