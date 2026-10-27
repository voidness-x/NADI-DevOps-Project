# Nadi Gym DevOps Platform — Master Engineering Documentation

```Meow to you all, Techies, HUB200 staff, and mayhaps Zain tech team!```

https://github.com/user-attachments/assets/30884f93-6bb2-4887-9b75-c4bf91472044

**Document Classification:** Internal Technical Architecture and Operational Manual  
**Project:** Nadi Gym Management Platform Infrastructure and Zero-Downtime Deployment Engine  
**Target Operating System:** AlmaLinux 9 / Enterprise Linux (Kernel 5.14+)  
**Ingress Host Gateway:** 178.18.249.160  
**Security Standard:** SELinux Enforcing Mode (Zero AVC Denials), Polkit D-Bus Least-Privilege Authorization  

---

## Table of Contents
1. [Executive Summary and System Overview](#1-executive-summary-and-system-overview)
2. [Architectural Principles and Core Decisions](#2-architectural-principles-and-core-decisions)
3. [Network Topology, Firewalls, and Ingress Port Mapping](#3-network-topology-firewalls-and-ingress-port-mapping)
4. [Container Inventory and Docker Compose Specifications](#4-container-inventory-and-docker-compose-specifications)
5. [End-to-End DevOps Lifecycle and Automated CI/CD Pipeline](#5-end-to-end-devops-lifecycle-and-automated-cicd-pipeline)
6. [Security Posture and Non-Interactive User Operations](#6-security-posture-and-non-interactive-user-operations)
7. [Disaster Recovery, Streaming Encryption, and Restore Drills](#7-disaster-recovery-streaming-encryption-and-restore-drills)
8. [Observability, Telemetry, and Alerting Matrix](#8-observability-telemetry-and-alerting-matrix)
9. [Advanced Platform Extensions (ChatOps, Benchmark, DevSecOps)](#9-advanced-platform-extensions)
10. [Operational Cheatsheet and Troubleshooting Playbook](#10-operational-cheatsheet-and-troubleshooting-playbook)

---

## 1. Executive Summary and System Overview

The Nadi Gym Management Platform is a multi-tier, multi-tenant SaaS application designed for high availability, transactional consistency, and continuous delivery. 

The primary operational mandate of the platform is the complete elimination of deployment downtime during application updates, combined with a strict least-privilege security model and verifiable disaster recovery.

### Key Operational Metrics
- **Deployment Cutover Latency:** Under 2 milliseconds using in-memory atomic upstream swapping.
- **Service Downtime During Releases:** Zero dropped TCP connections.
- **Automated Rollback Latency:** Under 10 seconds upon health check gate failure.
- **Disaster Recovery RTO (Recovery Time Objective):** Under 3 minutes verified via automated weekly scratch-container restoration tests.
- **Disaster Recovery RPO (Recovery Point Objective):** Under 24 hours via daily automated streaming GPG-encrypted database snapshots.
- **SELinux Posture:** 100% Enforcing mode with zero unexplained Access Vector Cache (AVC) denials.

---

## 2. Architectural Principles and Core Decisions

### 2.1 The Blue/Green Deployment Pattern
In standard in-place deployment strategies, stopping a running application container to swap an image produces 15 to 60 seconds of HTTP 502 Bad Gateway errors. Rolling updates on a single host can introduce database schema mismatches when old and new backend versions access identical tables concurrently.

To eliminate both issues, this infrastructure utilizes an autonomous dual-slot Blue/Green deployment engine:
1. Two identical container project slots exist on loopback interfaces: **Blue** (Ports 8101/8201) and **Green** (Ports 8102/8202).
2. When releasing version $N+1$, the candidate image is deployed exclusively to the idle slot.
3. Database migrations and automated seeding execute against the candidate slot in a backward-compatible manner.
4. Deep HTTP health verification scripts validate the candidate slot on its isolated loopback port.
5. If and only if all health checks return HTTP 200, the ingress proxy atomically swaps its upstream symlink (`/etc/caddy/slots/active.caddy`) and executes an in-memory configuration reload.
6. The old active slot drains existing in-flight connections for 5 seconds before its containers are cleanly stopped.
7. If the candidate fails any health check, Caddy is never reloaded, public traffic remains on the active slot, and the candidate slot is dismantled immediately.

### 2.2 Host-Native Caddy vs. Containerized Proxies
Rather than running Traefik or Nginx inside a container, Caddy v2.9 runs directly on the host as a systemd unit.

| Decision Factor | Host-Native Caddy (Implemented) | Containerized Proxy (Traefik / Nginx) |
|---|---|---|
| Docker Socket Exposure | Zero. Caddy does not mount `/var/run/docker.sock`. | High risk. Container breakout grants root access to host. |
| In-Memory Reload | `caddy reload` swaps routes with zero dropped TCP connections. | Process restarts or signals inside containers can drop active sockets. |
| TLS and SNI Handling | Manages local root CA and SNI fallback in-memory without volume mounts. | Requires persistent ACME volume bindings and certificate sync daemons. |
| Process Confinement | Bounded by standard SELinux type `httpd_t` and systemd sandboxing. | Runs in container namespaces subject to Docker daemon restart interruptions. |

### 2.3 Separation of Stateless and Stateful Planes
- **Stateless Tier (Web/API):** Packaged into disposable Docker containers (`gym-backend` and `gym-frontend`). Filesystems are ephemeral and stateless. Containers can be killed without user state loss.
- **Stateful Tier (PostgreSQL):** Kept separate from slot compose definitions in a dedicated Compose file (`compose.db.yml`). Defined on a persistent named Docker volume (`gym_db_data`). Tearing down an application slot never disrupts or restarts the database engine.

---

## 3. Network Topology, Firewalls, and Ingress Port Mapping

All application container ports are bound strictly to the `127.0.0.1` loopback interface. No application container binds directly to `0.0.0.0`.

### 3.1 Network Port Allocation Matrix

| Port | Protocol | Interface Binding | Service / Component | Purpose and Access Control |
|---|---|---|---|---|
| 22 | TCP | 0.0.0.0 | OpenSSH Daemon (Host) | Administrative shell access (gateway translated from public port 2201). |
| 8000 | TCP | 0.0.0.0 | Caddy Ingress Gateway | Public entrypoint for HTTPS traffic (gateway translated from public port 8001). |
| 3000 | TCP | 0.0.0.0 | Caddy Admin Ingress | Observability proxy for Grafana (gateway translated from public port 3001). |
| 8001 | TCP | 127.0.0.1 | Slot Blue Frontend | Nginx serving React/Next.js static assets for Blue slot. |
| 8101 | TCP | 127.0.0.1 | Slot Blue Backend | FastAPI Python REST API for Blue slot. |
| 8201 | TCP | 127.0.0.1 | Slot Blue Frontend Port | Container published loopback port for Blue frontend. |
| 8002 | TCP | 127.0.0.1 | Slot Green Frontend | Nginx serving React/Next.js static assets for Green slot. |
| 8102 | TCP | 127.0.0.1 | Slot Green Backend | FastAPI Python REST API for Green slot. |
| 8202 | TCP | 127.0.0.1 | Slot Green Frontend Port | Container published loopback port for Green frontend. |
| 9000 | TCP | 127.0.0.1 | `gym-webhook` Daemon | Go CI/CD automated deployment listener. |
| 5432 | TCP | Docker Bridge | PostgreSQL (`gym-postgres`) | Internal to `gym-data` bridge. No host interface published. |
| 3030 | TCP | 127.0.0.1 | Grafana Container | Observability dashboard engine (proxied by Caddy). |
| 9090 | TCP | 127.0.0.1 | Prometheus Engine | Metrics collection and PromQL querying engine. |
| 9093 | TCP | 127.0.0.1 | Alertmanager | Alert aggregation, silencing, and notification dispatcher. |
| 9100 | TCP | 127.0.0.1 | Node Exporter | Host hardware, CPU, memory, and textfile collector metrics. |
| 9187 | TCP | 127.0.0.1 | PostgreSQL Exporter | Database performance and connection metrics. |

### 3.2 Gateway Translation Architecture
The upstream VPS gateway performs the following Network Address Translation (NAT):
- Public `178.18.249.160:8001` forwards to Host `127.0.0.1:8000` (Application Ingress).
- Public `178.18.249.160:3001` forwards to Host `127.0.0.1:3000` (Grafana Ingress).
- Public `178.18.249.160:2201` forwards to Host `127.0.0.1:22` (OpenSSH Service).

### 3.3 Host Firewall (`firewalld`) Rules
The host firewall enforces a default-drop policy on public interfaces:

```bash
# Verify active firewalld configuration
sudo firewall-cmd --list-all
```

Configuration breakdown:
- Default Zone: `public`
- Allowed Services: `ssh`
- Allowed Ports: `22/tcp`, `3000/tcp`, `8000/tcp`
- All other unsolicited incoming connection requests on unlisted ports are discarded.

### 3.4 Caddy Reverse Proxy Path Routing Map

```
[ Incoming HTTPS Request to Port 8000 ]
                  │
                  ├── /hooks/*         ──> Reverse Proxy to 127.0.0.1:9000 (Go Webhook Daemon)
                  ├── /download/*      ──> File Server rooted at /srv/apk (Mobile Releases)
                  ├── /api/*           ──> Strip path prefix, Reverse Proxy to Active Backend (:8101 or :8102)
                  ├── /auth/*          ──> Reverse Proxy to Active Backend (:8101 or :8102)
                  ├── /openapi.json    ──> Reverse Proxy to Active Backend (:8101 or :8102)
                  └── /* (All other)   ──> Reverse Proxy to Active Frontend (:8201 or :8202)
```

---

## 4. Container Inventory and Docker Compose Specifications

### 4.1 Running Container Inventory

| Container Name | Base Image | Service Role | Internal Port | Host Binding | Network |
|---|---|---|---|---|---|
| `gym-postgres` | `postgres:16-alpine` | Relational Database Engine | 5432/tcp | None (Bridge Only) | `gym-data` |
| `gym-blue-backend` | `gym/backend:latest` | FastAPI REST API (Blue Slot) | 8000/tcp | `127.0.0.1:8101` | `gym-data` |
| `gym-blue-frontend` | `gym/frontend:latest` | Next.js SPA Web UI (Blue Slot) | 80/tcp | `127.0.0.1:8201` | `gym-data` |
| `gym-green-backend` | `gym/backend:latest` | FastAPI REST API (Green Slot) | 8000/tcp | `127.0.0.1:8102` | `gym-data` |
| `gym-green-frontend` | `gym/frontend:latest` | Next.js SPA Web UI (Green Slot) | 80/tcp | `127.0.0.1:8202` | `gym-data` |
| `gym-grafana` | `grafana/grafana:10.4.0` | Visualization Dashboards | 3000/tcp | `127.0.0.1:3030` | `gym-monitoring` |
| `gym-prometheus` | `prom/prometheus:v2.51.0` | Metrics Collection Engine | 9090/tcp | `127.0.0.1:9090` | `gym-monitoring` |
| `gym-alertmanager` | `prom/alertmanager:v0.27.0` | Alert Routing Engine | 9093/tcp | `127.0.0.1:9093` | `gym-monitoring` |
| `gym-postgres-exporter` | `prometheuscommunity/postgres-exporter` | Database Metrics Exporter | 9187/tcp | `127.0.0.1:9187` | `gym-data` |

### 4.2 Parameterized Compose Manifest (`/opt/gym/devops/compose/compose.slot.yml`)

```yaml
name: gym-${SLOT}

services:
  backend:
    image: gym/backend:${BACKEND_TAG:-latest}
    container_name: gym-${SLOT}-backend
    build:
      context: /opt/gym/src/backend
    restart: always
    ports:
      - "127.0.0.1:${BE_PORT}:8000"
    environment:
      - DATABASE_URL=postgresql://gym_user:${POSTGRES_PASSWORD}@gym-postgres:5432/gym_db
    env_file:
      - /etc/gym/backend.env
    networks:
      - gym-data
    security_opt:
      - "no-new-privileges:true"

  frontend:
    image: gym/frontend:${FRONTEND_TAG:-latest}
    container_name: gym-${SLOT}-frontend
    build:
      context: /opt/gym/src/frontend
    restart: always
    ports:
      - "127.0.0.1:${FE_PORT}:80"
    networks:
      - gym-data
    security_opt:
      - "no-new-privileges:true"

networks:
  gym-data:
    external: true
```

---

## 5. End-to-End DevOps Lifecycle and Automated CI/CD Pipeline

The platform enforces an automated lifecycle bridging repository commits, container compilation, validation gates, and telemetry notifications.

```
+-----------------------------------------------------------------------------------------+
|                                    DEVOPS LIFECYCLE                                     |
+-------------------+--------------------+------------------------+-----------------------+
| 1. CODE & PR      | 2. BUILD & TEST    | 3. DEPLOY & CUTOVER    | 4. OPERATE & MONITOR  |
| - Feature branch  | - HMAC Webhook     | - Pre-deploy snapshot  | - Prometheus scraping |
| - Pull request    | - Git pull code    | - DB seed & migration  | - Grafana dashboards  |
| - GitHub Actions  | - Docker Compose   | - Smoke test on 810x   | - Discord alerts      |
| - Merge to main   | - Virtualenv build | - Atomic Caddy reload  | - Streaming backups   |
+-------------------+--------------------+------------------------+-----------------------+
```

### 5.1 Pipeline Execution Walkthrough

```
[ Developer ]
      |
      | 1. Git push / Merge Pull Request to main
      v
[ GitHub Repository ]
      |
      | 2. Webhook POST https://178.18.249.160:8001/hooks/deploy
      v (HMAC SHA-256 Signature via X-Hub-Signature-256)
[ Host Port 8001 -> Caddy Gateway (:8000) ]
      |
      | 3. Reverse proxies internally to 127.0.0.1:9000
      v
[ gym-webhook Daemon (Go) ]
      |
      | 4. Reads secret from /etc/gym/secrets/webhook_secret
      | 5. Verifies crypto/hmac equal check; evaluates payload.Ref == "refs/heads/main"
      | 6. Executes /opt/gym/devops/scripts/deploy.sh under deploy user
      v
[ deploy.sh Orchestrator ]
      |
      | 7. Enforces cd /opt/gym/devops
      | 8. Acquires non-blocking kernel mutex: flock -n 9 /opt/gym/state/deploy.lock
      | 9. Generates pre-deploy database snapshot into /var/backups/gym/
      | 10. Executes git -C /opt/gym/src/backend pull origin main
      | 11. Executes git -C /opt/gym/src/frontend pull origin main
      | 12. Builds and starts candidate slot (e.g. Blue on :8101 and :8201)
      | 13. Runs database seeding / migrations inside candidate container
      | 14. Calls /opt/gym/devops/scripts/smoke.sh to validate candidate endpoints
      |
      +---> IF SMOKE TEST FAILS:
      |        ├── Triggers /opt/gym/devops/scripts/rollback.sh
      |        ├── Drains candidate containers (docker compose down)
      |        ├── Sends Discord Failure Notification:
      |        │   "Deployment Failed & Rolled Back! Candidate slot failed smoke tests."
      |        └── Exits with error code 1 (Production remains on current slot)
      |
      +---> IF SMOKE TEST PASSES (HTTP 200 on /health and /):
               ├── Executes /opt/gym/devops/scripts/switch.sh
               ├── Atomically relinks /etc/caddy/slots/active.caddy -> blue.caddy
               ├── Executes caddy reload in-memory (zero dropped connections)
               ├── Writes new active slot to /opt/gym/state/active_slot
               ├── Sends Discord Success Notification:
               │   "Deployment Successful! Candidate slot blue is now active."
               ├── Drains previous active slot for 5 seconds
               └── Stops previous active slot containers (docker compose stop)
```

---

## 6. Security Posture and Non-Interactive User Operations

### 6.1 Unprivileged Service Account Architecture
The deployment automation user (`deploy`) is explicitly constrained:
- The user account has no root login shell (`/sbin/nologin` or locked).
- Interactive password authentication is disabled.
- The user does not have a wildcard `ALL=(ALL) NOPASSWD: ALL` sudoers entry.
- File permissions strictly follow POSIX least privilege:
  - Configuration directories (`/etc/caddy`, `/etc/gym`) are owned by `root:root` (`0755` or `0700`).
  - Secret files (`/etc/gym/secrets/*`) are readable only by `deploy` and root (`0400` or `0600`).
  - Script directories (`/opt/gym/devops/scripts`) are owned by `deploy:deploy` (`0750`).

### 6.2 Polkit Fine-Grained D-Bus Authorization
To allow the unprivileged `deploy` user to restart Caddy and trigger backups without granting full root sudo permissions, a Linux Polkit rule is installed at `/etc/polkit-1/rules.d/50-gym-deploy.rules`:

```javascript
/* ==============================================================================
 * File: /etc/polkit-1/rules.d/50-gym-deploy.rules
 * Purpose: Authorize deploy user to manage only gym-specific systemd units
 * ============================================================================== */
polkit.addRule(function(action, subject) {
    if (action.id == "org.freedesktop.systemd1.manage-units" &&
        subject.user == "deploy") {
        
        var unit = action.lookup("unit");
        var verb = action.lookup("verb");

        // Allow reloading Caddy reverse proxy without sudo
        if (unit == "caddy.service" && (verb == "reload" || verb == "restart" || verb == "status")) {
            return polkit.Result.YES;
        }

        // Allow starting pre-deploy backup services
        if (unit == "gym-backup.service" && (verb == "start" || verb == "status")) {
            return polkit.Result.YES;
        }
    }
});
```

### 6.3 SELinux Mandatory Access Control (MAC)
The operating system runs with SELinux in **Enforcing** mode. Processes and directories operate under explicit security contexts:
- Ingress Caddy runs under domain `system_u:system_r:httpd_t`.
- Boolean `httpd_can_network_connect` is set to `1` to authorize reverse proxying to loopback ports.
- Custom ports 8000, 8001, and 8002 are registered as `http_port_t`.
- Uploads and media directories are labeled with `container_file_t`.
- Mobile APK distribution directories are labeled with `httpd_sys_content_t`.

---

## 7. Disaster Recovery, Streaming Encryption, and Restore Drills

The platform rejects the premise that an untested backup constitutes disaster recovery. Backups are encrypted at rest and validated through automated restore simulations.

### 7.1 Streaming GPG AES-256 Backup Pipeline (`backup.sh`)
Database dumps are streamed through compression and encryption pipelines without unencrypted plaintext touching the file system:

```bash
# Streaming Pipeline:
docker exec gym-postgres pg_dump -U gym_user -d gym_db --format=custom --compress=6 \
  | gpg --batch --yes --symmetric --cipher-algo AES256 --passphrase-file /etc/gym/backup/passphrase \
  > /var/backups/gym/db/gym_TIMESTAMP.dump.gpg
```

Key guarantees:
- Passphrase is stored in `/etc/gym/backup/passphrase` (`0600 root:root`).
- Backups older than 14 days are automatically pruned; a minimum of 7 archives are permanently retained.
- Metrics are written to `/var/lib/node_exporter/textfile/gym_backup.prom` reporting size, duration, and status.

### 7.2 Automated Weekly Restore Verification Drill (`restore-test.sh`)
Every Sunday at 04:00 UTC, a systemd timer executes an automated verification drill without taking the production database offline:
1. Locates the latest GPG-encrypted database archive in `/var/backups/gym/db/`.
2. Launches an ephemeral, isolated scratch container: `gym-restore-test-$$` using `--network none`.
3. Streams the decryption pipeline directly into the scratch container.
4. Executes row-count and schema audits across all production relational tables:
   `gym_branches`, `members`, `subscriptions`, `trainers`, `equipment_inventory`, `billing_invoices`, `access_logs`, `class_schedules`.
5. Compares uploaded media counts in `/srv/gym/uploads` against the archive tarball.
6. Measures and records the exact Recovery Time Objective (RTO in seconds).
7. Dismantles the throwaway scratch container and volume completely.
8. Writes an audit report to `/var/log/gym/restore-tests/restore-test-TIMESTAMP.md`.

---

## 8. Observability, Telemetry, and Alerting Matrix

### 8.1 Prometheus Scrape Matrix
Prometheus scrapes operational targets every 15 seconds:
- **Node Exporter (`127.0.0.1:9100`):** CPU utilization, memory pressure, disk I/O, filesystem space, and custom textfile collector metrics (`gym_backup.prom`, `gym_restore_test.prom`).
- **PostgreSQL Exporter (`127.0.0.1:9187`):** Active connections, transaction commits/rollbacks, buffer cache hit ratios, and deadlock locks.
- **Caddy Metrics (`127.0.0.1:2019/metrics`):** HTTP request rates, response latency percentiles (p95, p99), and HTTP status codes (2xx, 4xx, 5xx).

### 8.2 Critical Alerting Rules (`alerts.yml`)
- `GymSlotDown`: Triggers if the active slot frontend returns HTTP 5xx responses for more than 1 minute.
- `PostgresDown`: Triggers if the PostgreSQL container becomes unresponsive or terminates.
- `GymBackupStale`: Triggers if no successful encrypted backup has executed in the last 25 hours.
- `DiskSpaceLow`: Triggers if root or backup filesystem available space drops below 15%.

---

## 9. Advanced Platform Extensions

To elevate the platform's reliability, observability, and security posture, three advanced enterprise capabilities are integrated:

### 9.1 Interactive Two-Way Discord ChatOps (`gym-discord-bot.service`)
An autonomous, hardened Python daemon running as a host systemd unit enables bidirectional ChatOps through Discord without exposing the VPS to external management networks.

- **Systemd Unit:** `/etc/systemd/system/gym-discord-bot.service`
- **Daemon Executable:** `/opt/gym/devops/scripts/discord_bot.py` (running inside dedicated venv `/opt/gym/devops/venv`)
- **Execution User:** `deploy` (strictly unprivileged)
- **Least-Privilege Systemd Sandboxing:**
  - `ProtectSystem=full` & `ProtectHome=yes` (OS binaries and `/etc` remain strictly Read-Only)
  - `ReadWritePaths=/etc/caddy/slots /opt/gym/state /var/log/gym` (Pinpoint write exceptions exclusively for active slot swapping)
  - `PrivateTmp=yes`
- **RBAC & Authorization:** Strict username whitelist enforced against Discord author metadata (`voidness.x`). Unrecognized users receive immediate access denial.
- **Available Commands:**
  - `!status`: Returns live active slot, Caddy gateway status, container health table, and memory usage.
  - `!switch <blue|green>`: Executes zero-downtime atomic slot cutover via `/usr/local/bin/switch_slot.sh`.
  - `!rollback`: Instantly reverts live traffic to the alternate candidate slot.
  - `!deploy <blue|green>`: Triggers candidate container spinup and automated smoke validation.
  - `!benchmark`: Runs a live in-flight 25-request zero-downtime load test and posts the certificate report directly into Discord.

### 9.2 Empirical Zero-Downtime Benchmark Validation Engine (`benchmark_switch.py`)
A custom, bounded asynchronous load-testing tool validates continuous availability and zero dropped connections during Caddy in-memory configuration reloads.

- **Script Path:** `/opt/gym/devops/scripts/benchmark_switch.py`
- **Execution Profile:** 25 concurrent requests dispatched across multi-threaded workers at 40ms intervals against `https://127.0.0.1:8000/api/health`.
- **In-Flight Traffic Switch:** Triggers `/usr/local/bin/switch_slot.sh` during active HTTP probe transmission.
- **Self-Healing Slot Warmup:** Automatically verifies candidate containers are running and warm prior to traffic cutover.
- **Mathematical Telemetry Verified:**
  - **Availability:** 100.0% (25/25 requests return HTTP 200 OK, 0 dropped TCP sockets).
  - **Transition Tracking:** Captures exact probe sequence index (e.g. Request #8) where response headers transition from `x-slot: blue` to `x-slot: green`.
  - **Latency Profile:** Min ~5.5 ms, Average ~7.3 ms, Max ~13.1 ms.

### 9.3 DevSecOps Automated Vulnerability Scanning Gate (Aqua Security Trivy)
Continuous vulnerability scanning integrated into GitHub Actions CI pipelines provides automated security audits without disrupting release velocity.

- **Workflow Paths:**
  - DevOps Repo: `.github/workflows/devsecops.yml`
  - Backend Repo: `.github/workflows/ci.yml`
- **Scanner Engine:** Aqua Security Trivy (`aquasecurity/trivy-action@master`) scanning filesystems, dependencies (`requirements.txt`), and Dockerfiles.
- **Non-Blocking Observability Policy (`exit-code: 0`):** Build checks pass with a green checkmark to guarantee project deployment continuity while logging security debt.
- **Automated High-Priority Discord Alerting:**
  - Dynamically parses `trivy-report.json` using `jq`.
  - Filters for `CRITICAL` and `HIGH` severity vulnerabilities.
  - If CVEs are detected, constructs an urgent rich Discord embed displaying repository, branch, commit SHA, vulnerability count, detected CVE IDs, affected library versions, and fixed versions.

---

## 10. Operational Cheatsheet and Troubleshooting Playbook

Because the `deploy` user has a non-interactive shell, all administrative commands are executed from the administrative user (`student`) using `sudo` or `sudo -u deploy`.

### 9.1 Container Management Commands

```bash
# View formatted container status and port mappings
sudo docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

# Inspect live container logs
sudo docker logs --tail 50 gym-blue-backend
sudo docker logs --tail 50 gym-green-backend
sudo docker logs --tail 50 gym-postgres

# Restart database state tier
cd /opt/gym/devops && sudo docker compose -f compose/compose.db.yml restart
```

### 9.2 Inspecting Directory Trees and State

```bash
# Display project directory hierarchy (ignoring cache and git objects)
sudo tree -L 3 /opt/gym -I "node_modules|.git|venv|__pycache__"

# Check currently active deployment slot
cat /opt/gym/state/active_slot

# Check active Caddy upstream symlink
readlink /etc/caddy/slots/active.caddy
```

### 9.3 Executing Operations as the Non-Interactive Deploy User

```bash
# Trigger an immediate manual deployment
cd /opt/gym/devops && sudo -u deploy /opt/gym/devops/scripts/deploy.sh latest

# Perform manual slot cutover (e.g. switch to green)
sudo -u deploy /opt/gym/devops/scripts/switch.sh green

# Execute git operations within the repository tree
sudo -u deploy git -C /opt/gym/devops status

# Open a temporary scoped shell for debugging
sudo -u deploy -H bash -c "cd /opt/gym/devops && pwd && ls -la"
```

### 9.4 Systemd Service Inspection Commands

```bash
# View status of all platform services in one line
sudo systemctl status caddy docker gym-webhook gym-backup.timer --no-pager

# Restart Caddy reverse proxy
sudo systemctl restart caddy

# View scheduled backup and restore timers
sudo systemctl list-timers 'gym*'
```

### 9.5 Real-Time Log Inspection

```bash
# Tail webhook listener log
sudo tail -f /var/log/gym/webhook.log

# Tail Caddy ingress access log
sudo tail -f /var/log/caddy/access.log

# Tail the latest deployment execution audit log
sudo tail -f $(ls -t /var/log/gym/deploy-*.log 2>/dev/null | head -n 1)
```

### 9.6 Security and Network Posture Verification

```bash
# Verify SELinux mode
getenforce

# Query recent SELinux denials (proves 0 denials)
sudo ausearch -m AVC,USER_AVC -ts recent || echo "Clean: No recent SELinux denials."

# List active open firewall ports
sudo firewall-cmd --list-ports

# Verify all active TCP listening sockets
sudo ss -tulpn | grep -E ':(22|8000|8101|8102|8201|8202|9000|3000|3030|5432)'
```

---

*I hope it was a nice read for you all. Now I meow out :P*
