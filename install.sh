#!/usr/bin/env bash
# Install gh-agent-auth scripts into ~/.local/bin and wire git's credential
# helper chain so the GitHub App helper is consulted first, with `gh auth
# git-credential` as the personal fallback.
#
# Idempotent: safe to re-run.
set -euo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
CONFIG_DIR="${GH_AGENT_AUTH_CONFIG_DIR:-$HOME/.config/gh-agent-auth}"

mkdir -p "$BIN_DIR" "$CONFIG_DIR"

# --------------------------------------------------------------------------
# Copy scripts to BIN_DIR
# --------------------------------------------------------------------------

for script in gh-agent-unlock gh-agent-lock get-github-token git-credential-github-app; do
  install -m 0755 "$REPO_DIR/bin/$script" "$BIN_DIR/$script"
  echo "Installed $BIN_DIR/$script"
done

# --------------------------------------------------------------------------
# Seed config file if absent
# --------------------------------------------------------------------------

CONFIG_FILE="$CONFIG_DIR/config"
if [[ ! -f "$CONFIG_FILE" ]]; then
  cat > "$CONFIG_FILE" <<'EOF'
# gh-agent-auth configuration. Sourced by all gh-agent-auth scripts.
# All values can also be supplied via environment variables.

# Required: numeric GitHub App ID (visible on the App's settings page)
# GITHUB_APP_ID=

# Required: org or user account where the App is installed
# GITHUB_APP_ORG=

# Required: path to the age-encrypted App private key
# GH_AGENT_AUTH_KEY_ENCRYPTED="$HOME/.config/gh-agent-auth/key.pem.age"

# Optional overrides (defaults shown)
# GH_AGENT_AUTH_KEY_DECRYPTED=/dev/shm/github-app-private-key.pem
# GH_AGENT_AUTH_TOKEN_PATH=/dev/shm/github-app-token
# GH_AGENT_AUTH_EXPIRY_PATH=/dev/shm/github-app-token-expiry
EOF
  chmod 600 "$CONFIG_FILE"
  echo "Created $CONFIG_FILE — fill in GITHUB_APP_ID, GITHUB_APP_ORG, and GH_AGENT_AUTH_KEY_ENCRYPTED."
else
  echo "Config already exists at $CONFIG_FILE — leaving untouched."
fi

# --------------------------------------------------------------------------
# Wire git credential helper chain for github.com
#
# Desired chain:
#   helper = ""                                ← clear inherited helpers
#   helper = github-app                        ← App auth (no-op when locked)
#   helper = !gh auth git-credential           ← personal gh fallback
# --------------------------------------------------------------------------

GH_BIN="$(command -v gh || true)"
if [[ -z "$GH_BIN" ]]; then
  echo "WARNING: gh CLI not found on PATH; skipping personal-fallback wiring." >&2
  FALLBACK_HELPER=""
else
  FALLBACK_HELPER="!$GH_BIN auth git-credential"
fi

git config --global --unset-all 'credential.https://github.com.helper' 2>/dev/null || true
git config --global  'credential.https://github.com.helper' ''
git config --global --add 'credential.https://github.com.helper' 'github-app'
[[ -n "$FALLBACK_HELPER" ]] && \
  git config --global --add 'credential.https://github.com.helper' "$FALLBACK_HELPER"

echo ""
echo "Done. Make sure $BIN_DIR is on your PATH, then:"
echo "  1. Edit $CONFIG_FILE with your App ID, org, and encrypted-key path."
echo "  2. Encrypt your App's .pem with age + age-plugin-yubikey:"
echo "       age -r 'age1yubikey1...' -o key.pem.age private-key.pem"
echo "  3. gh-agent-unlock   (once per session)"
echo "  4. Use git and gh normally — the helper handles tokens transparently."
