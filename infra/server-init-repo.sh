#!/usr/bin/env bash
# ──────────────────────────────────────────────────
# Initialize a repo on a remote server
#
# Authenticates gh CLI and clones a repo over SSH.
# Works with any server reachable via SSH (Hetzner, AWS, etc.)
#
# ── Usage ────────────────────────────────────────
#
#   # Auth + clone (token passed over SSH, never stored locally on server disk)
#   GH_TOKEN=ghp_... bash infra/server-init-repo.sh <server-name> <owner/repo>
#
#   # Clone to already-authenticated server
#   bash infra/server-init-repo.sh <server-name> <owner/repo>
#
#   # Re-auth with new token (e.g. after expiry)
#   GH_TOKEN=ghp_... bash infra/server-init-repo.sh <server-name>
#
#   # After hetzner-setup.sh
#   bash infra/hetzner-setup.sh my-prod
#   GH_TOKEN=ghp_... bash infra/server-init-repo.sh my-prod owner/repo
#
# ── Config ───────────────────────────────────────
#
#   Variable     Default   Description
#   ──────────   ───────   ──────────────────────────────────────
#   GH_TOKEN     (none)    GitHub token for gh auth (optional if already authed)
#   SSH_USER     evios     Server username
#   REPO_DIR     ~/repos   Directory to clone into
#
# ── Creating a GH_TOKEN ─────────────────────────
#
#   Use a fine-grained token scoped to a single repo:
#
#   1. https://github.com/settings/personal-access-tokens/new
#   2. Token name: e.g. "server-my-prod"
#   3. Expiration: 7 days (shorter is safer)
#   4. Resource owner: your user or org
#   5. Repository access: "Only select repositories" → pick one repo
#   6. Permissions → Repository permissions:
#        Contents: Read and write  (clone + push)
#        Metadata: Read-only       (auto-selected)
#   7. Generate token → copy ghp_... value
#
#   After expiry, re-auth:
#     GH_TOKEN=ghp_new_token bash infra/server-init-repo.sh my-prod
#
# ──────────────────────────────────────────────────
set -eo pipefail

SERVER_NAME="${1:?Usage: bash infra/server-init-repo.sh <server-name> [owner/repo]}"
GH_REPO="${2:-}"
SSH_USER="${SSH_USER:-evios}"
REPO_DIR="${REPO_DIR:-~/repos}"
GH_TOKEN="${GH_TOKEN:-}"

# SSH into server
remote() {
  ssh -o ConnectTimeout=10 -o BatchMode=yes "${SSH_USER}@${SERVER_NAME}" "$@"
}

# ── Validate ────────────────────────────────────
echo "--- Connecting to ${SSH_USER}@${SERVER_NAME} ---"
if ! remote "true" 2>/dev/null; then
  echo "ERROR: Cannot SSH into ${SSH_USER}@${SERVER_NAME}"
  echo "  Check: ssh ${SSH_USER}@${SERVER_NAME}"
  exit 1
fi

if ! remote "command -v gh" &>/dev/null; then
  echo "ERROR: gh CLI not installed on ${SERVER_NAME}"
  echo "  Install: ssh ${SSH_USER}@${SERVER_NAME} 'sudo apt-get install -y gh'"
  exit 1
fi

# ── Auth ────────────────────────────────────────
if [ -n "$GH_TOKEN" ]; then
  echo "--- Authenticating gh CLI ---"
  echo "$GH_TOKEN" | remote "gh auth login --with-token && gh auth setup-git"
  echo "gh authenticated"
else
  # Check if already authed
  if ! remote "gh auth status" &>/dev/null; then
    echo "ERROR: gh not authenticated and no GH_TOKEN provided"
    echo "  Either: GH_TOKEN=ghp_... bash infra/server-init-repo.sh ${SERVER_NAME} ${GH_REPO}"
    echo "  Or:     ssh ${SSH_USER}@${SERVER_NAME} 'gh auth login'"
    exit 1
  fi
  echo "gh already authenticated"
fi

# ── Clone ───────────────────────────────────────
if [ -n "$GH_REPO" ]; then
  REPO_NAME="${GH_REPO##*/}"
  echo "--- Cloning $GH_REPO ---"

  if remote "test -d ${REPO_DIR}/${REPO_NAME}/.git" 2>/dev/null; then
    echo "Repo already exists at ${REPO_DIR}/${REPO_NAME} — pulling latest"
    remote "cd ${REPO_DIR}/${REPO_NAME} && git pull"
  else
    remote "mkdir -p ${REPO_DIR} && gh repo clone '${GH_REPO}' ${REPO_DIR}/'${REPO_NAME}'"
    echo "Cloned $GH_REPO → ${REPO_DIR}/$REPO_NAME"
  fi
fi

echo ""
echo "=== Done ==="
echo "  ssh ${SSH_USER}@${SERVER_NAME}"
[ -n "$GH_REPO" ] && echo "  cd ${REPO_DIR}/${GH_REPO##*/}"
