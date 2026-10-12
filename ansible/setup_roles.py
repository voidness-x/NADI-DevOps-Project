import os

BASE = "/opt/gym/devops/ansible"

files = {
    # ── 1. site.yml ──
    f"{BASE}/site.yml": """---
- name: Gym server — full build from a fresh AlmaLinux install
  hosts: all
  become: true
  pre_tasks:
    - name: Refuse anything that is not EL 9/10
      ansible.builtin.assert:
        that:
          - ansible_facts['os_family'] == 'RedHat'
          - ansible_facts['distribution_major_version'] | int in [9, 10]
        fail_msg: "This playbook targets AlmaLinux/RHEL 9 or 10."
  roles:
    - {role: common, tags: [common]}
    - {role: ssh, tags: [ssh]}
    - {role: firewall, tags: [firewall]}
    - {role: selinux, tags: [selinux]}
    - {role: docker, tags: [docker]}
    - {role: caddy, tags: [caddy]}
    - {role: gym_stack, tags: [stack]}
    - {role: backup, tags: [backup]}
    - {role: webhook, tags: [webhook]}
    - {role: monitoring, tags: [monitoring]}
    - {role: apk_page, tags: [apk]}
""",

    # ── 2. common role ──
    f"{BASE}/roles/common/tasks/main.yml": """---
- name: Ensure EPEL repository is present
  ansible.builtin.dnf:
    name: epel-release
    state: present

- name: Core system services running
  ansible.builtin.systemd_service:
    name: "{{ item }}"
    enabled: true
    state: started
  loop: [chronyd, auditd, fail2ban]
  failed_when: false

- name: Admin user in wheel
  ansible.builtin.user:
    name: "{{ admin_user }}"
    groups: wheel
    append: true
    shell: /bin/bash

- name: Automation user deploy
  ansible.builtin.user:
    name: deploy
    system: true
    home: /opt/gym
    create_home: true
    shell: /sbin/nologin

- name: State and runtime directories
  ansible.builtin.file:
    path: "{{ item }}"
    state: directory
    owner: deploy
    group: deploy
    mode: "0755"
  loop:
    - /opt/gym/state
    - /opt/gym/src
    - /var/log/gym
    - /var/lib/node_exporter/textfile

- name: Project storage directories
  ansible.builtin.file:
    path: "{{ item.path }}"
    state: directory
    owner: "{{ item.owner }}"
    group: "{{ item.group }}"
    mode: "{{ item.mode }}"
  loop:
    - {path: /etc/gym, owner: root, group: deploy, mode: "0750"}
    - {path: /etc/gym/secrets, owner: root, group: deploy, mode: "0750"}
    - {path: /etc/gym/backup, owner: root, group: root, mode: "0700"}
    - {path: /srv/gym/uploads, owner: "1000", group: "1000", mode: "0750"}
    - {path: /srv/gym/monitoring, owner: root, group: root, mode: "0755"}
    - {path: /srv/apk, owner: deploy, group: deploy, mode: "0755"}
    - {path: /var/backups/gym, owner: "{{ admin_user }}", group: "{{ admin_user }}", mode: "0700"}
    - {path: /var/backups/gym/db, owner: "{{ admin_user }}", group: "{{ admin_user }}", mode: "0700"}
    - {path: /var/backups/gym/uploads, owner: "{{ admin_user }}", group: "{{ admin_user }}", mode: "0700"}
""",

    # ── 3. ssh role ──
    f"{BASE}/roles/ssh/tasks/main.yml": """---
- name: Hardened sshd drop-in
  ansible.builtin.template:
    src: 10-gym.conf.j2
    dest: /etc/ssh/sshd_config.d/10-gym.conf
    owner: root
    group: root
    mode: "0600"
    validate: /usr/sbin/sshd -t -f %s
  notify: Reload sshd
""",
    f"{BASE}/roles/ssh/handlers/main.yml": """---
- name: Reload sshd
  ansible.builtin.systemd_service:
    name: sshd
    state: reloaded
""",
    f"{BASE}/roles/ssh/templates/10-gym.conf.j2": """PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
AllowUsers {{ admin_user }}
""",

    # ── 4. firewall role ──
    f"{BASE}/roles/firewall/tasks/main.yml": """---
- name: Firewalld running
  ansible.builtin.systemd_service:
    name: firewalld
    enabled: true
    state: started

- name: Open assigned public ports
  ansible.posix.firewalld:
    zone: public
    port: "{{ item }}/tcp"
    permanent: true
    immediate: true
    state: enabled
  loop:
    - "{{ ssh_listen_port }}"
    - "{{ app_port }}"
    - "{{ admin_port }}"
""",

    # ── 5. selinux role ──
    f"{BASE}/roles/selinux/tasks/main.yml": """---
- name: SELinux Enforcing
  ansible.posix.selinux:
    policy: targeted
    state: enforcing

- name: Persistent file contexts
  community.general.sefcontext:
    target: "{{ item.path }}(/.*)?"
    setype: "{{ item.setype }}"
    state: present
  loop:
    - {path: /srv/gym/uploads, setype: container_file_t}
    - {path: /srv/gym/monitoring, setype: container_file_t}
    - {path: /etc/gym/secrets, setype: container_file_t}
    - {path: /srv/apk, setype: httpd_sys_content_t}

- name: Allow HTTP ports in SELinux
  community.general.seport:
    ports: "{{ item }}"
    proto: tcp
    setype: http_port_t
    state: present
  loop:
    - "{{ app_port }}"
    - "{{ admin_port }}"
  failed_when: false

- name: Allow Caddy loopback connects
  ansible.posix.seboolean:
    name: httpd_can_network_connect
    state: true
    persistent: true
""",

    # ── 6. docker role ──
    f"{BASE}/roles/docker/tasks/main.yml": """---
- name: Docker daemon config
  ansible.builtin.copy:
    dest: /etc/docker/daemon.json
    content: |
      {
        "selinux-enabled": true,
        "live-restore": true,
        "log-driver": "json-file",
        "log-opts": {"max-size": "10m", "max-file": "3"},
        "metrics-addr": "127.0.0.1:9323"
      }
    owner: root
    group: root
    mode: "0644"
  notify: Restart docker

- name: Docker service running
  ansible.builtin.systemd_service:
    name: docker
    enabled: true
    state: started

- name: Deploy user in docker group
  ansible.builtin.user:
    name: deploy
    groups: docker
    append: true

- name: Ensure gym-data network exists
  ansible.builtin.shell: |
    docker network inspect gym-data >/dev/null 2>&1 || docker network create gym-data
  changed_when: false
""",
    f"{BASE}/roles/docker/handlers/main.yml": """---
- name: Restart docker
  ansible.builtin.systemd_service:
    name: docker
    state: restarted
""",

    # ── 7. caddy role ──
    f"{BASE}/roles/caddy/tasks/main.yml": """---
- name: Caddy directories
  ansible.builtin.file:
    path: "{{ item.path }}"
    state: directory
    owner: "{{ item.owner }}"
    group: "{{ item.group }}"
    mode: "{{ item.mode }}"
  loop:
    - {path: /etc/caddy, owner: root, group: caddy, mode: "0755"}
    - {path: /etc/caddy/slots, owner: deploy, group: caddy, mode: "0755"}
    - {path: /var/log/caddy, owner: caddy, group: caddy, mode: "0750"}

- name: Slot files
  ansible.builtin.template:
    src: slot.caddy.j2
    dest: "/etc/caddy/slots/{{ item.name }}.caddy"
    owner: root
    group: caddy
    mode: "0644"
  loop:
    - {name: blue, backend: 8101, frontend: 8201}
    - {name: green, backend: 8102, frontend: 8202}
  notify: Reload caddy

- name: Check active slot symlink
  ansible.builtin.stat:
    path: /etc/caddy/slots/active.caddy
    follow: false
  register: caddy_active_link

- name: Create active.caddy link ONLY if missing
  ansible.builtin.file:
    src: blue.caddy
    dest: /etc/caddy/slots/active.caddy
    state: link
    owner: deploy
    group: caddy
  when: not caddy_active_link.stat.exists

- name: Install Caddyfile
  ansible.builtin.template:
    src: Caddyfile.j2
    dest: /etc/caddy/Caddyfile
    owner: root
    group: caddy
    mode: "0644"
    validate: caddy validate --adapter caddyfile --config %s
  notify: Reload caddy

- name: Caddy service running
  ansible.builtin.systemd_service:
    name: caddy
    enabled: true
    state: started
""",
    f"{BASE}/roles/caddy/handlers/main.yml": """---
- name: Reload caddy
  ansible.builtin.systemd_service:
    name: caddy
    state: reloaded
""",
    f"{BASE}/roles/caddy/templates/slot.caddy.j2": """header X-Slot {{ item.name }}
handle_path /api/* {
\treverse_proxy 127.0.0.1:{{ item.backend }} {
\t\thealth_uri /health
\t\thealth_interval 5s
\t\tlb_try_duration 5s
\t}
}
handle {
\treverse_proxy 127.0.0.1:{{ item.frontend }}
}
""",
    f"{BASE}/roles/caddy/templates/Caddyfile.j2": """{
\tadmin localhost:2019
\tmetrics
\tskip_install_trust
}

(security_headers) {
\theader {
\t\tStrict-Transport-Security "max-age=31536000"
\t\tX-Content-Type-Options nosniff
\t\tX-Frame-Options DENY
\t\tReferrer-Policy strict-origin-when-cross-origin
\t\t-Server
\t}
}

https://{{ public_host }}:{{ app_port }} {
\ttls internal
\tencode zstd gzip
\timport security_headers

\tlog {
\t\toutput file /var/log/caddy/access.log {
\t\t\troll_size 10mb
\t\t\troll_keep 5
\t\t}
\t\tformat json
\t}

\thandle /hooks/* {
\t\t@notpost not method POST
\t\trespond @notpost 405
\t\trequest_body {
\t\t\tmax_size 2MB
\t\t}
\t\treverse_proxy 127.0.0.1:9000
\t}

\tredir /download /download/ 308
\thandle_path /download/* {
\t\troot * /srv/apk
\t\t@apk path *.apk
\t\theader @apk {
\t\t\tContent-Type application/vnd.android.package-archive
\t\t\tContent-Disposition attachment
\t\t}
\t\t@meta path /version.json /index.html /
\t\theader @meta Cache-Control "no-cache"
\t\tfile_server
\t}

\timport /etc/caddy/slots/active.caddy
}

https://{{ public_host }}:{{ admin_port }} {
\ttls internal
\timport security_headers
\treverse_proxy 127.0.0.1:3000
}
""",

    # ── 8. gym_stack role ──
    f"{BASE}/roles/gym_stack/tasks/main.yml": """---
- name: Deploy environment files
  ansible.builtin.template:
    src: "{{ item }}.j2"
    dest: "/etc/gym/{{ item }}"
    owner: root
    group: deploy
    mode: "0640"
  loop: [deploy.env, notify.env, backend.env]
  no_log: true

- name: Postgres password secret file
  ansible.builtin.copy:
    dest: /etc/gym/secrets/postgres_password
    content: "{{ postgres_password }}"
    owner: root
    group: deploy
    mode: "0444"
  no_log: true

- name: Polkit authorization rule
  ansible.builtin.copy:
    src: /opt/gym/devops/polkit/50-gym-deploy.rules
    dest: /etc/polkit-1/rules.d/50-gym-deploy.rules
    remote_src: true
    owner: root
    group: root
    mode: "0644"
  failed_when: false

- name: Shared PostgreSQL container running
  ansible.builtin.command: docker compose -f /opt/gym/devops/compose/compose.infra.yml up -d
  register: compose_infra
  changed_when: compose_infra.stderr is search('Created|Recreated|Started')
  become: true
  become_user: deploy

- name: Check if release exists
  ansible.builtin.stat:
    path: /opt/gym/state/releases.env
  register: releases_env_stat

- name: Run bootstrap ONLY if releases.env missing
  ansible.builtin.command: /opt/gym/devops/scripts/bootstrap.sh
  when: not releases_env_stat.stat.exists
  become: true
  become_user: deploy
""",
    f"{BASE}/roles/gym_stack/templates/deploy.env.j2": """APP_PORT={{ app_port }}
PUBLIC_HOST={{ public_host }}
DRAIN_SECONDS=30
MIGRATE_CMD="{{ backend_migrate_cmd }}"
IMAGE_KEEP=5
""",
    f"{BASE}/roles/gym_stack/templates/notify.env.j2": """DISCORD_WEBHOOK_URL={{ discord_webhook_url }}
""",
    f"{BASE}/roles/gym_stack/templates/backend.env.j2": """DATABASE_URL=postgres://gym_user:{{ postgres_password }}@gym-postgres:5432/gym_db
POSTGRES_USER=gym_user
POSTGRES_PASSWORD={{ postgres_password }}
POSTGRES_DB=gym_db
""",

    # ── 9. backup role ──
    f"{BASE}/roles/backup/tasks/main.yml": """---
- name: Escrowed backup passphrase from Vault
  ansible.builtin.copy:
    dest: /etc/gym/backup/passphrase
    content: "{{ backup_passphrase }}"
    owner: root
    group: root
    mode: "0600"
  no_log: true

- name: Backup configuration file
  ansible.builtin.template:
    src: backup.env.j2
    dest: /etc/gym/backup.env
    owner: root
    group: root
    mode: "0600"

- name: Systemd units from devops repo
  ansible.builtin.copy:
    src: "/opt/gym/devops/systemd/{{ item }}"
    dest: "/etc/systemd/system/{{ item }}"
    remote_src: true
    owner: root
    group: root
    mode: "0644"
  loop:
    - gym-backup.service
    - gym-backup.timer
    - gym-restore-test.service
    - gym-restore-test.timer
  notify: Reload systemd

- name: Backup timers enabled
  ansible.builtin.systemd_service:
    name: "{{ item }}"
    enabled: true
    state: started
  loop:
    - gym-backup.timer
    - gym-restore-test.timer
""",
    f"{BASE}/roles/backup/handlers/main.yml": """---
- name: Reload systemd
  ansible.builtin.systemd_service:
    daemon_reload: true
""",
    f"{BASE}/roles/backup/templates/backup.env.j2": """BACKUP_DIR=/var/backups/gym
PASSPHRASE_FILE=/etc/gym/backup/passphrase
GNUPGHOME=/var/lib/gym-backup/gnupg
ADMIN_USER={{ admin_user }}
PG_CONTAINER=gym-postgres
PG_USER=gym_user
PG_DB=gym_db
PG_IMAGE=postgres:16-alpine
UPLOADS_DIR=/srv/gym/uploads
RETENTION_DAYS=14
KEEP_MIN=7
RESTORE_CHECK_TABLES=""
""",

    # ── 10. webhook role ──
    f"{BASE}/roles/webhook/tasks/main.yml": """---
- name: Webhook secret file
  ansible.builtin.copy:
    dest: /etc/gym/webhook.env
    content: "WEBHOOK_SECRET={{ webhook_secret }}\\n"
    owner: root
    group: deploy
    mode: "0640"
  no_log: true
  notify: Restart webhook

- name: Ensure gym-webhook service enabled
  ansible.builtin.systemd_service:
    name: gym-webhook
    enabled: true
    state: started
""",
    f"{BASE}/roles/webhook/handlers/main.yml": """---
- name: Restart webhook
  ansible.builtin.systemd_service:
    name: gym-webhook
    state: restarted
""",

    # ── 11. monitoring role ──
    f"{BASE}/roles/monitoring/tasks/main.yml": """---
- name: Container secrets
  ansible.builtin.copy:
    dest: "/etc/gym/secrets/{{ item.name }}"
    content: "{{ item.value }}"
    owner: root
    group: deploy
    mode: "0444"
  loop:
    - {name: grafana_admin_password, value: "{{ grafana_admin_password }}"}
    - {name: pg_monitor_password, value: "{{ pg_monitor_password }}"}
    - {name: discord_webhook_url, value: "{{ discord_webhook_url }}"}
  no_log: true

- name: Monitoring environment file
  ansible.builtin.copy:
    dest: /etc/gym/monitoring.env
    content: "GRAFANA_ROOT_URL=https://{{ public_host }}:{{ admin_port }}/\\n"
    owner: root
    group: deploy
    mode: "0640"

- name: Monitoring stack running
  ansible.builtin.command: >-
    docker compose --env-file /etc/gym/monitoring.env
    -f /opt/gym/devops/compose/compose.monitoring.yml up -d
  register: compose_mon
  changed_when: compose_mon.stderr is search('Created|Recreated|Started')
  become: true
  become_user: deploy
""",

    # ── 12. apk_page role ──
    f"{BASE}/roles/apk_page/tasks/main.yml": """---
- name: APK download page
  ansible.builtin.copy:
    src: /opt/gym/devops/apk-page/index.html
    dest: /srv/apk/index.html
    remote_src: true
    owner: deploy
    group: deploy
    mode: "0644"
  failed_when: false

- name: Write fetch-apk.env
  ansible.builtin.copy:
    dest: /etc/gym/fetch-apk.env
    content: |
      GITHUB_REPO={{ github_org }}/Nadi-Mobile
      GITHUB_TOKEN={{ fetch_apk_token }}
      APK_KEEP=3
    owner: root
    group: deploy
    mode: "0640"
  no_log: true
"""
}

for path, content in files.items():
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(content)

print(f"SUCCESS: Generated site.yml and {len(files)} role files!")
