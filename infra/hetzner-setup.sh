#!/usr/bin/env bash
# ──────────────────────────────────────────────────
# One-Click Hetzner Server Setup
#
# Hardened Ubuntu server accessible only via Tailscale.
# No SSH on public IP — connect through Tailscale mesh.
#
# Stack: Tailscale + Mosh/SSH + Docker + Claude Code + GitHub CLI
#        + Termius + sshid.io hardware keys
#
# ── Quick Start ──────────────────────────────────
#
#   Prerequisites:
#     brew install hcloud
#     export HCLOUD_TOKEN="..."              # https://console.hetzner.cloud > Security > API Tokens
#     export TAILSCALE_API_KEY="tskey-api-..." # https://login.tailscale.com/admin/settings/keys
#     SSH key uploaded to Hetzner             # https://console.hetzner.com > Security > SSH Keys
#
#   # Ephemeral server (default — TS node auto-removes when offline)
#   bash infra/hetzner-setup.sh my-sandbox
#
#   # Production server (persistent TS node)
#   TS_EPHEMERAL=false bash infra/hetzner-setup.sh my-prod
#
#   # Production + clone repo
#   TS_EPHEMERAL=false bash infra/hetzner-setup.sh my-prod
#   GH_TOKEN=ghp_... bash infra/server-init-repo.sh my-prod owner/repo
#
#   # Connect (~3 min)
#   mosh evios@<server-name>               # Mosh via Tailscale (recommended)
#   ssh evios@<server-name>                # SSH via Tailscale
#
#   # Destroy
#   hcloud server delete <server-name>
#
# ── Config ───────────────────────────────────────
#
#   Variable             Default                  Description
#   ──────────────────   ──────────────────────   ──────────────────────────────────────
#   BOOTSTRAP_APPS       docker,claude-code,gh    Apps to install (tailscale always included)
#   TS_EPHEMERAL         true                     Ephemeral (auto-removes) or persistent TS node
#   TS_TAGS              tag:server               Tailscale ACL tags (empty to skip, auto-checked)
#   SSH_USER             evios                    Server username
#   HCLOUD_SERVER_TYPE   cx23                     Server type (2 vCPU, 4GB, ~€3/mo)
#   HCLOUD_LOCATION      hel1                     Datacenter (hel1/fsn1/ash)
#   HCLOUD_SSH_KEY       evios_id_ed25519.pub     SSH key name in Hetzner
#   TIMEZONE             UTC                      Server timezone
#   CLOUDFLARE_ONLY      true                     Restrict HTTP/S to Cloudflare IPs
#
# ── Examples ─────────────────────────────────────
#
#   # Bigger server in Germany
#   HCLOUD_SERVER_TYPE=cx32 HCLOUD_LOCATION=fsn1 bash infra/hetzner-setup.sh my-server
#
#   # Open HTTP/S to all (not just Cloudflare)
#   CLOUDFLARE_ONLY=false bash infra/hetzner-setup.sh my-server
#
#   # Docker only — no Claude Code, no gh
#   BOOTSTRAP_APPS=docker bash infra/hetzner-setup.sh my-minimal
#
#   # Clone repo without pre-auth (gh auth login manually after SSH)
#   bash infra/hetzner-setup.sh my-dev
#
# ── What You Get ─────────────────────────────────
#
#   Base (always installed):
#     Ubuntu 24.04, Tailscale, Mosh, curl, jq, tmux, git, UFW, fail2ban
#     Hetzner HW firewall (80/443 only), OpenSSH on Tailscale IP only
#     sshid.io hardware keys, sysctl hardening, 180-day log retention
#     Unattended security upgrades (auto-reboot 02:00)
#
#   BOOTSTRAP_APPS (default: docker,claude-code,gh):
#     docker      — Docker Engine + Compose (iptables isolated, explicit NAT)
#     claude-code — Claude Code + c() alias (--dangerously-skip-permissions)
#     gh          — GitHub CLI (+ optional GH_TOKEN auth and GH_REPO clone)
#
# ── Architecture ─────────────────────────────────
#
#   Internet --> Hetzner HW FW (80/443) --> UFW --> Docker containers
#   You ------> Tailscale tunnel ---------> SSH/Mosh (all ports on tailscale0)
#
# ── Server Types ─────────────────────────────────
#
#   cx23  — 2 vCPU, 4GB, 40GB  ~€3/mo (default)
#   cx33  — 4 vCPU, 8GB, 80GB  ~€7/mo
#   cax23 — 4 ARM, 8GB, 80GB   ~€5/mo
#   Full list: hcloud server-type list
#
# ── Locations ────────────────────────────────────
#
#   hel1 — Helsinki    fsn1 — Falkenstein    ash — Ashburn
#
# ── Verify / Debug ───────────────────────────────
#
#   ssh evios@<name> cat /var/log/hetzner-setup-done
#   ssh evios@<name> cat /var/log/hetzner-setup.log
#   # VNC console: https://console.hetzner.cloud
#
# ── Security ─────────────────────────────────────
#
#   - No public SSH — OpenSSH bound to Tailscale IP only
#   - Key-only auth, no root, no forwarding, sshid.io hardware keys
#   - UFW: Cloudflare-only HTTP/S + all on tailscale0
#   - Docker: iptables:false + explicit NAT (can't bypass UFW)
#   - fail2ban: 3 attempts → 1h ban
#   - Cloud-init secrets: only Tailscale auth key (3-min TTL, one-time)
#
# ── Clone a repo after setup ─────────────────────
#
#   GH_TOKEN=ghp_... bash infra/server-init-repo.sh <server-name> owner/repo
#   See infra/server-init-repo.sh for GH_TOKEN creation guide.
#
# ──────────────────────────────────────────────────
set -eo pipefail

# ── Config ──────────────────────────────────────
SERVER_NAME="${1:?Usage: bash infra/hetzner-setup.sh <server-name>}"
SERVER_TYPE="${HCLOUD_SERVER_TYPE:-cx23}"         # 2 vCPU, 4GB, 40GB NVMe (~€3/mo)
SERVER_LOCATION="${HCLOUD_LOCATION:-hel1}"        # Helsinki, FI
SSH_USER="${SSH_USER:-evios}"
HCLOUD_SSH_KEY="${HCLOUD_SSH_KEY:-evios_id_ed25519.pub}"
TIMEZONE="${TIMEZONE:-UTC}"
CLOUDFLARE_ONLY="${CLOUDFLARE_ONLY:-true}"        # restrict HTTP/S to Cloudflare IPs
BOOTSTRAP_APPS="${BOOTSTRAP_APPS:-docker,claude-code,gh}"  # comma-separated; tailscale always installed
TS_EPHEMERAL="${TS_EPHEMERAL:-true}"             # ephemeral TS node (set false for production)
TS_TAGS="${TS_TAGS:-tag:server}"                  # Tailscale ACL tags (empty to skip)
FW_NAME="http-s-only-fw"

# Validate BOOTSTRAP_APPS (catch typos early)
KNOWN_APPS="docker,claude-code,gh"
for app in $(echo "$BOOTSTRAP_APPS" | tr ',' ' '); do
  if ! echo ",$KNOWN_APPS," | grep -q ",$app,"; then
    echo "ERROR: Unknown app '$app' in BOOTSTRAP_APPS"
    echo "  Known apps: $KNOWN_APPS"
    exit 1
  fi
done

# Validate TS_EPHEMERAL (injected raw into Tailscale API JSON)
if [ "$TS_EPHEMERAL" != "true" ] && [ "$TS_EPHEMERAL" != "false" ]; then
  echo "ERROR: TS_EPHEMERAL must be 'true' or 'false', got '$TS_EPHEMERAL'"
  exit 1
fi

# ── Validate ────────────────────────────────────
if [ -z "${HCLOUD_TOKEN:-}" ]; then
  echo "ERROR: HCLOUD_TOKEN is required -- https://console.hetzner.cloud > Security > API Tokens"
  exit 1
fi
if [ -z "${TAILSCALE_API_KEY:-}" ]; then
  echo "ERROR: TAILSCALE_API_KEY is required -- https://login.tailscale.com/admin/settings/keys > API Keys"
  exit 1
fi

command -v hcloud &>/dev/null || { echo "ERROR: hcloud CLI not found -- brew install hcloud"; exit 1; }

# Validate Tailscale ACL tags (if specified)
if [ -n "$TS_TAGS" ]; then
  echo "--- Checking Tailscale ACL for '$TS_TAGS' ---"
  TS_ACL=$(curl -sf "https://api.tailscale.com/api/v2/tailnet/-/acl" \
    -H "Authorization: Bearer ${TAILSCALE_API_KEY}" 2>/dev/null) || true
  if [ -n "$TS_ACL" ]; then
    # Check if the tag is defined in tagOwners
    TAG_NAME="${TS_TAGS#tag:}"
    if echo "$TS_ACL" | grep -q "\"tag:${TAG_NAME}\""; then
      echo "ACL tag '$TS_TAGS' exists"
    else
      echo "WARNING: '$TS_TAGS' not found in Tailscale ACLs -- skipping tags"
      echo "  To fix: add '\"$TS_TAGS\": [\"autogroup:admin\"]' to tagOwners in"
      echo "  https://login.tailscale.com/admin/acls"
      TS_TAGS=""
    fi
  else
    echo "WARNING: Could not read Tailscale ACLs (API key may lack acl:read) -- skipping tags"
    TS_TAGS=""
  fi
fi

# Generate one-time Tailscale auth key (expires in 3 min)
echo "--- Generating one-time Tailscale auth key (ephemeral=$TS_EPHEMERAL) ---"
TS_RESPONSE=$(curl -s -X POST "https://api.tailscale.com/api/v2/tailnet/-/keys" \
  -H "Authorization: Bearer ${TAILSCALE_API_KEY}" \
  -H "Content-Type: application/json" \
  -d "{\"capabilities\":{\"devices\":{\"create\":{\"reusable\":false,\"ephemeral\":${TS_EPHEMERAL},\"preauthorized\":true}}},\"expirySeconds\":180}")

TAILSCALE_AUTH_KEY=$(echo "$TS_RESPONSE" | grep -o '"key":"[^"]*"' | head -1 | cut -d'"' -f4)
if [ -z "$TAILSCALE_AUTH_KEY" ]; then
  echo "ERROR: Failed to generate Tailscale auth key"
  echo "$TS_RESPONSE"
  exit 1
fi
echo "One-time auth key generated (expires in 3 min)"

# Check Tailscale hostname not taken
if tailscale status 2>/dev/null | grep -q " ${SERVER_NAME} "; then
  echo "ERROR: '${SERVER_NAME}' already exists in Tailscale"
  echo "  Options: use a different name, or remove at https://login.tailscale.com/admin/machines"
  exit 1
fi

# Verify SSH key exists in Hetzner
hcloud ssh-key describe "$HCLOUD_SSH_KEY" &>/dev/null 2>&1 \
  || { echo "ERROR: SSH key '$HCLOUD_SSH_KEY' not found in Hetzner. Upload at https://console.hetzner.com -> Security -> SSH Keys"; exit 1; }
SSH_PUB_KEY=$(hcloud ssh-key describe "$HCLOUD_SSH_KEY" -o format='{{.PublicKey}}')

if hcloud server describe "$SERVER_NAME" &>/dev/null 2>&1; then
  echo "ERROR: Server '$SERVER_NAME' already exists"
  echo "  Delete: hcloud server delete $SERVER_NAME && hcloud firewall delete $FW_NAME"
  exit 1
fi

echo "=== Hetzner VPS Setup ==="
echo "Server:    $SERVER_NAME ($SERVER_TYPE @ $SERVER_LOCATION)"
echo "User:      $SSH_USER"
echo "Timezone:  $TIMEZONE"
echo "Firewall:  80/443 only (SSH via Tailscale)"
echo "Apps:      tailscale (always), $BOOTSTRAP_APPS"
echo "TS node:   $([ "$TS_EPHEMERAL" = "true" ] && echo "ephemeral" || echo "persistent")"
echo ""

# ── Hetzner Firewall (80/443 only) ──────────────
if ! hcloud firewall describe "$FW_NAME" &>/dev/null 2>&1; then
  echo "--- Creating firewall: $FW_NAME ---"
  hcloud firewall create --name "$FW_NAME"
  hcloud firewall add-rule "$FW_NAME" --direction in --protocol tcp --port 80 \
    --source-ips 0.0.0.0/0 --source-ips ::/0 --description "HTTP"
  hcloud firewall add-rule "$FW_NAME" --direction in --protocol tcp --port 443 \
    --source-ips 0.0.0.0/0 --source-ips ::/0 --description "HTTPS"
  hcloud firewall add-rule "$FW_NAME" --direction in --protocol udp --port 41641 \
    --source-ips 0.0.0.0/0 --source-ips ::/0 --description "Tailscale direct"
else
  echo "Firewall '$FW_NAME' exists -- reusing"
fi

# ── Generate Cloud-Init ─────────────────────────
# Uses single-quoted heredoc (no expansion) + sed substitution for safety.
# All __PLACEHOLDER__ values are replaced with local variables before upload.
CLOUD_INIT=$(mktemp /tmp/cloud-init-XXXX.yml)
trap 'rm -f "$CLOUD_INIT"' EXIT

cat > "$CLOUD_INIT" <<'CIEOF'
#cloud-config

timezone: __TIMEZONE__

users:
  - name: __SSH_USER__
    groups: sudo
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - __SSH_PUB_KEY__

package_update: true
package_upgrade: true

packages:
  - mosh
  - fail2ban
  - unattended-upgrades
  - apt-listchanges
  - curl
  - jq
  - tmux
  - git
  - ufw

write_files:
  # Auto-updates
  - path: /etc/apt/apt.conf.d/20auto-upgrades
    content: |
      APT::Periodic::Update-Package-Lists "1";
      APT::Periodic::Unattended-Upgrade "1";

  # fail2ban
  - path: /etc/fail2ban/jail.local
    content: |
      [sshd]
      enabled = true
      port = 22
      maxretry = 3
      bantime = 3600
      findtime = 600

  # sysctl hardening
  - path: /etc/sysctl.d/99-hardening.conf
    content: |
      net.ipv4.conf.all.accept_redirects = 0
      net.ipv4.conf.default.accept_redirects = 0
      net.ipv6.conf.all.accept_redirects = 0
      net.ipv6.conf.default.accept_redirects = 0
      net.ipv4.conf.all.send_redirects = 0
      net.ipv4.conf.default.send_redirects = 0
      net.ipv4.icmp_echo_ignore_broadcasts = 1
      net.ipv4.tcp_syncookies = 1
      net.ipv4.tcp_max_syn_backlog = 2048
      net.ipv4.tcp_synack_retries = 2
      net.ipv4.conf.all.rp_filter = 1
      net.ipv4.conf.default.rp_filter = 1
      net.ipv4.conf.all.log_martians = 1
      net.ipv4.conf.default.log_martians = 1

  # SSH config (Tailscale IP filled in at boot)
  - path: /etc/ssh/sshd_config.tpl
    content: |
      ListenAddress __TS_IP__
      PermitRootLogin no
      AllowUsers __SSH_USER__
      PasswordAuthentication no
      PermitEmptyPasswords no
      KbdInteractiveAuthentication no
      MaxAuthTries 6
      UsePAM no
      X11Forwarding no
      AllowTcpForwarding no
      AllowAgentForwarding no
      PrintMotd no
      AuthorizedKeysFile .ssh/authorized_keys .ssh/authorized_keys_sshid
      AcceptEnv LANG LC_*
      Subsystem sftp /usr/lib/openssh/sftp-server

  # Main setup script — runs once on first boot
  - path: /opt/setup.sh
    permissions: '0755'
    content: |
      #!/bin/bash
      set -euo pipefail
      echo "=== Server Setup Started $(date -Iseconds) ==="

      # App install helper
      APPS=",__BOOTSTRAP_APPS__,"
      has_app() { echo "$APPS" | grep -q ",$1,"; }

      # ── Tailscale ──────────────────────────────
      echo "--- Installing Tailscale ---"
      curl -fsSL https://tailscale.com/install.sh | sh
      TS_UP_ARGS="--auth-key=__TAILSCALE_AUTH_KEY__ --hostname=__SERVER_NAME__"
      [ -n "__TS_TAGS__" ] && TS_UP_ARGS="$TS_UP_ARGS --advertise-tags=__TS_TAGS__"
      tailscale up $TS_UP_ARGS
      TS_IP=$(tailscale ip -4)
      echo "Tailscale connected: $TS_IP"

      # ── SSH: bind to Tailscale IP ──────────────
      echo "--- Configuring SSH ---"
      usermod -p '*' __SSH_USER__
      sed "s/__TS_IP__/$TS_IP/" /etc/ssh/sshd_config.tpl > /etc/ssh/sshd_config
      rm /etc/ssh/sshd_config.tpl
      systemctl restart ssh
      echo "SSH bound to $TS_IP (key-only, no root)"

      # Add SSH.id hardware keys (Termius mobile access, separate file)
      KEYS_DIR="/home/__SSH_USER__/.ssh"
      echo "# __SSH_USER__ - sshid.io keys" > "$KEYS_DIR/authorized_keys_sshid"
      SSHID_RESPONSE=$(curl -fs https://sshid.io/__SSH_USER__ || true)
      if [ -n "$SSHID_RESPONSE" ]; then
        echo "$SSHID_RESPONSE" | grep -E '^(ssh-|ecdsa-|sk-)' >> "$KEYS_DIR/authorized_keys_sshid"
        echo "sshid.io keys added ($(echo "$SSHID_RESPONSE" | grep -cE '^(ssh-|ecdsa-|sk-)') keys)"
      else
        echo "WARNING: sshid.io returned empty response -- skipping hardware keys"
      fi
      chown __SSH_USER__:__SSH_USER__ "$KEYS_DIR/authorized_keys_sshid"
      chmod 600 "$KEYS_DIR/authorized_keys_sshid"

      # ── UFW (defense-in-depth) ─────────────────
      echo "--- Configuring UFW ---"
      ufw default deny incoming
      ufw default allow outgoing

      if [ "__CLOUDFLARE_ONLY__" = "true" ]; then
        # HTTP/S from Cloudflare IPs only (retry + validate)
        CF_IPV4=""
        for _attempt in 1 2 3; do
          CF_IPV4=$(curl -sf --retry 2 https://www.cloudflare.com/ips-v4) && break
          sleep 2
        done
        CF_IPV6=$(curl -sf --retry 2 https://www.cloudflare.com/ips-v6) || true

        CF_COUNT=$(echo "$CF_IPV4" | grep -c . || true)
        if [ -n "$CF_IPV4" ] && [ "$CF_COUNT" -ge 10 ]; then
          for ip in $CF_IPV4 $CF_IPV6; do
            ufw allow from "$ip" to any port 80,443 proto tcp comment 'Cloudflare'
          done
          echo "HTTP/S restricted to Cloudflare IPs ($CF_COUNT IPv4 ranges)"
        else
          echo "WARNING: Cloudflare IP list looks wrong ($CF_COUNT ranges, expected 10+) -- allowing all"
          ufw allow 80/tcp comment 'HTTP'
          ufw allow 443/tcp comment 'HTTPS'
        fi
      else
        ufw allow 80/tcp comment 'HTTP'
        ufw allow 443/tcp comment 'HTTPS'
      fi

      ufw allow in on tailscale0 comment 'Tailscale - SSH, Mosh, all'
      ufw --force enable

      # ── Docker + Compose ───────────────────────
      if has_app docker; then
        echo "--- Installing Docker ---"
        curl -fsSL https://get.docker.com | sh
        mkdir -p /etc/docker
        echo '{"iptables": false}' > /etc/docker/daemon.json
        systemctl enable docker
        usermod -aG docker __SSH_USER__
        apt-get install -y docker-compose-plugin
        systemctl restart docker

        # Docker NAT (required when iptables: false)
        # Retry bridge inspect — daemon may need a moment after restart
        DOCKER_SUB=""
        for _i in 1 2 3; do
          DOCKER_SUB=$(docker network inspect bridge --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null) && break
          sleep 2
        done
        DOCKER_SUB="${DOCKER_SUB:-172.17.0.0/16}"
        EXT_IF=$(ip route | awk '/default/ {print $5; exit}')

        BEFORE_RULES=/etc/ufw/before.rules
        if ! grep -q "Docker NAT" "$BEFORE_RULES" 2>/dev/null; then
          sed -i "1i\\
      # Docker NAT\\
      *nat\\
      :POSTROUTING ACCEPT [0:0]\\
      -A POSTROUTING -s ${DOCKER_SUB} -o ${EXT_IF} -j MASQUERADE\\
      COMMIT\\
      " "$BEFORE_RULES"

          sed -i "/^# don't delete the 'COMMIT' line/i\\
      # Docker forwarding\\
      -A ufw-before-forward -s ${DOCKER_SUB} -o ${EXT_IF} -j ACCEPT\\
      -A ufw-before-forward -d ${DOCKER_SUB} -m state --state RELATED,ESTABLISHED -j ACCEPT" "$BEFORE_RULES"

          ufw reload
        fi
        echo "Docker installed (iptables isolated, NAT configured)"
      else
        echo "--- Skipping Docker (not in BOOTSTRAP_APPS) ---"
      fi

      # ── Unattended upgrades ────────────────────
      # Drop-in config (higher priority than 50unattended-upgrades, survives format changes)
      echo "--- Configuring auto-updates ---"
      cat > /etc/apt/apt.conf.d/51auto-reboot << 'AUTOREBOOT'
      Unattended-Upgrade::Automatic-Reboot "true";
      Unattended-Upgrade::Automatic-Reboot-WithUsers "true";
      Unattended-Upgrade::Automatic-Reboot-Time "02:00";
      AUTOREBOOT
      systemctl enable unattended-upgrades
      systemctl restart unattended-upgrades

      # ── Apply hardening ────────────────────────
      echo "--- Applying hardening ---"
      sysctl -p /etc/sysctl.d/99-hardening.conf
      systemctl enable fail2ban && systemctl restart fail2ban
      sed -Ei 's/(.+rotate).+/\1 180/' /etc/logrotate.d/rsyslog

      # ── Locale (required for Mosh) ──────────────
      locale-gen en_US.UTF-8
      update-locale LANG=en_US.UTF-8

      # ── GitHub CLI ─────────────────────────────
      if has_app gh; then
        echo "--- Installing GitHub CLI ---"
        curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
          | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
          > /etc/apt/sources.list.d/github-cli.list
        apt-get update -qq
        apt-get install -y gh
        echo "gh installed (auth + clone handled post-setup over Tailscale)"
      else
        echo "--- Skipping GitHub CLI (not in BOOTSTRAP_APPS) ---"
      fi

      # ── Claude Code ─────────────────────────────
      if has_app claude-code; then
        echo "--- Installing Claude Code ---"
        sudo -u __SSH_USER__ bash -c 'curl -fsSL https://claude.ai/install.sh | bash'
      else
        echo "--- Skipping Claude Code (not in BOOTSTRAP_APPS) ---"
      fi

      # ── Done ───────────────────────────────────
      echo "SETUP_COMPLETE $(date -Iseconds)" > /var/log/hetzner-setup-done
      echo "=== Setup Complete ==="

runcmd:
  - bash /opt/setup.sh 2>&1 | tee /var/log/hetzner-setup.log
  - rm -f /opt/setup.sh
  - |
    cat > /home/__SSH_USER__/.bash_aliases << 'ALIASES'
    alias ll='ls -alF'
    alias la='ls -A'
    alias l='ls -CF'
    ALIASES
    APPS=",__BOOTSTRAP_APPS__,"
    if echo "$APPS" | grep -q ',claude-code,'; then
      echo 'c() { claude --continue --dangerously-skip-permissions "$@"; }' >> /home/__SSH_USER__/.bash_aliases
    fi
    chown __SSH_USER__:__SSH_USER__ /home/__SSH_USER__/.bash_aliases
CIEOF

# Substitute local values into cloud-init template
sed_inplace() {
  if [[ "$OSTYPE" == darwin* ]]; then
    sed -i '' "$@"
  else
    sed -i "$@"
  fi
}

sed_inplace \
  -e "s|__SSH_USER__|${SSH_USER}|g" \
  -e "s|__SSH_PUB_KEY__|${SSH_PUB_KEY}|g" \
  -e "s|__TAILSCALE_AUTH_KEY__|${TAILSCALE_AUTH_KEY}|g" \
  -e "s|__SERVER_NAME__|${SERVER_NAME}|g" \
  -e "s|__TIMEZONE__|${TIMEZONE}|g" \
  -e "s|__CLOUDFLARE_ONLY__|${CLOUDFLARE_ONLY}|g" \
  -e "s|__BOOTSTRAP_APPS__|${BOOTSTRAP_APPS}|g" \
  -e "s|__TS_TAGS__|${TS_TAGS}|g" \
  "$CLOUD_INIT"

# ── Create Server ───────────────────────────────
echo "--- Creating server ---"
if ! hcloud server create \
  --name "$SERVER_NAME" \
  --type "$SERVER_TYPE" \
  --image ubuntu-24.04 \
  --location "$SERVER_LOCATION" \
  --firewall "$FW_NAME" \
  --ssh-key "$HCLOUD_SSH_KEY" \
  --user-data-from-file "$CLOUD_INIT" 2>&1; then
  echo ""
  echo "ERROR: Server creation failed."
  echo "  Common causes:"
  echo "    - resource_unavailable: $SERVER_LOCATION is out of $SERVER_TYPE instances"
  echo "    - uniqueness_error: server '$SERVER_NAME' already exists"
  echo ""
  echo "  Try a different location or server type:"
  echo "    HCLOUD_LOCATION=fsn1 $0 $SERVER_NAME"
  echo "    HCLOUD_LOCATION=nbg1 $0 $SERVER_NAME"
  echo "    HCLOUD_SERVER_TYPE=cx22 $0 $SERVER_NAME"
  echo ""
  echo "  Available locations: hcloud location list"
  echo "  Available types:     hcloud server-type list"
  exit 1
fi

SERVER_IP=$(hcloud server ip "$SERVER_NAME")

# ── Wait for Tailscale ──────────────────────────
echo ""
echo "--- Waiting for Tailscale to connect ---"
SECONDS=0
while true; do
  elapsed=$SECONDS
  if tailscale status 2>/dev/null | grep -q "$SERVER_NAME"; then
    printf "\r[%ds] Tailscale connected!                \n" "$elapsed"
    break
  fi
  printf "\r[%ds] Waiting for cloud-init + Tailscale..." "$elapsed"
  if [ "$elapsed" -gt 600 ]; then
    printf "\r[%ds] Timeout -- check Hetzner console for errors\n" "$elapsed"
    break
  fi
  sleep 5
done

# ── Wait for setup completion ───────────────────
SSH_IDENTITY_FILE="${HCLOUD_SSH_KEY%.pub}"
echo "--- Waiting for setup to finish ---"
SECONDS=0
while true; do
  elapsed=$SECONDS
  if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new -o BatchMode=yes \
    -i "$HOME/.ssh/${SSH_IDENTITY_FILE}" \
    "${SSH_USER}@${SERVER_NAME}" "test -f /var/log/hetzner-setup-done" 2>/dev/null; then
    printf "\r[%ds] Setup complete!                     \n" "$elapsed"
    break
  fi
  printf "\r[%ds] Waiting for setup to finish..." "$elapsed"
  if [ "$elapsed" -gt 600 ]; then
    printf "\r[%ds] Timeout -- SSH in and check /var/log/hetzner-setup.log\n" "$elapsed"
    break
  fi
  sleep 10
done

# ── Append to ~/.ssh/config-ephemeral-servers ──
SSH_EPHEMERAL="$HOME/.ssh/config-ephemeral-servers"
SSH_CONFIG="$HOME/.ssh/config"

# Ensure Include exists in main config
if ! grep -q "Include.*config-ephemeral-servers" "$SSH_CONFIG" 2>/dev/null; then
  TMPFILE=$(mktemp)
  echo "Include ~/.ssh/config-ephemeral-servers" > "$TMPFILE"
  [ -f "$SSH_CONFIG" ] && echo "" >> "$TMPFILE" && cat "$SSH_CONFIG" >> "$TMPFILE"
  mv "$TMPFILE" "$SSH_CONFIG"
  echo "Added Include to ~/.ssh/config"
fi

# Remove old entry + stale host key (robust awk-based cleanup)
if [ -f "$SSH_EPHEMERAL" ] && grep -q "^Host ${SERVER_NAME}$" "$SSH_EPHEMERAL"; then
  awk -v host="${SERVER_NAME}" '
    /^# vps auto-spawned/ { comment=$0; next }
    /^Host / {
      if ($2 == host) { comment=""; skip=1; next }
      if (comment != "") { print comment; comment="" }
    }
    skip && /^[^ \t]/ { skip=0 }
    skip { next }
    comment != "" { print comment; comment="" }
    { print }
    END { if (comment != "") print comment }
  ' "$SSH_EPHEMERAL" > "${SSH_EPHEMERAL}.tmp" && mv "${SSH_EPHEMERAL}.tmp" "$SSH_EPHEMERAL"
  ssh-keygen -R "$SERVER_NAME" 2>/dev/null || true
fi

cat >> "$SSH_EPHEMERAL" <<SSHCONF

# vps auto-spawned $(date +%Y-%m-%d)
Host ${SERVER_NAME}
    Hostname ${SERVER_NAME}
    User ${SSH_USER}
    IdentityFile ~/.ssh/${SSH_IDENTITY_FILE}
SSHCONF
echo "Added ${SERVER_NAME} to ~/.ssh/config-ephemeral-servers"

echo ""
echo "=== Server Created ==="
echo "Name:      $SERVER_NAME"
echo "Public IP: $SERVER_IP"
echo "Firewall:  $FW_NAME (80/443 only)"
echo "Apps:      tailscale, $BOOTSTRAP_APPS"
echo ""
echo "=== Connect ==="
echo "  mosh ${SSH_USER}@${SERVER_NAME}        # Mosh via Tailscale"
echo "  ssh ${SSH_USER}@${SERVER_NAME}         # SSH via Tailscale"
echo ""
echo "  Termius: add host '${SERVER_NAME}', user '${SSH_USER}', enable Mosh"
echo ""
echo "=== Verify ==="
echo "  ssh ${SSH_USER}@${SERVER_NAME} cat /var/log/hetzner-setup-done"
echo "  ssh ${SSH_USER}@${SERVER_NAME} cat /var/log/hetzner-setup.log"
echo ""
echo "=== Destroy ==="
echo "  hcloud server delete ${SERVER_NAME}"
