# tests/helpers.bash
# Shared helpers for gh-agent-auth tests.
#
# Usage in a test_*.sh file:
#   set -uo pipefail
#   . "$(dirname "$0")/helpers.bash"
#   echo "test: name"
#   (
#     make_sandbox dir
#     mock_openssl "$dir"; mock_curl "$dir"
#     # ... assertions using ok / fail ...
#   )
#   report

# Resolve REPO_DIR from this file's location.
HELPERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$HELPERS_DIR/.." && pwd)"

# --------------------------------------------------------------------------
# Centralized EXIT cleanup.
#
# Tests run in (...) subshells for isolation. Bash subshells inherit
# variables but RESET the EXIT trap to default on entry, so a trap
# registered at source time would not fire when a subshell exits.
# Worse, an in-memory array updated by a subshell dies with the subshell,
# so the parent never sees what the subshell registered for cleanup.
#
# We sidestep both by storing cleanup paths in a FILE, identified by
# path (a regular variable, inherited by subshells just fine). Both
# parent and subshell append to the same file. A single EXIT trap at
# the parent level reads the file at the end of the run and cleans up.
# This means sandbox dirs persist on disk for the duration of the test
# file's run — fine, they're tiny.
#
# Use cleanup_path PATH... instead of writing inline `trap "rm ..." EXIT`
# (which would clobber other traps and not survive subshell exits).
# --------------------------------------------------------------------------

_CLEANUP_FILE=$(mktemp "${TMPDIR:-/tmp}/gh-agent-auth-cleanup.XXXXXX")
_run_cleanup() {
  if [[ -f "$_CLEANUP_FILE" ]]; then
    local p
    while IFS= read -r p; do
      [[ -n "$p" && -e "$p" ]] && rm -rf "$p"
    done < "$_CLEANUP_FILE"
    rm -f "$_CLEANUP_FILE"
  fi
}
trap _run_cleanup EXIT

cleanup_path() {
  local p
  for p in "$@"; do
    printf '%s\n' "$p" >> "$_CLEANUP_FILE"
  done
}

# --------------------------------------------------------------------------
# Pass/fail counters via files.
#
# Variable assignments inside `(...)` subshells don't propagate out, so
# in-memory counters can't span tests. We append a line to a file per
# event; report() counts the lines. Atomic-enough for our use.
# --------------------------------------------------------------------------

TESTS_PASS_FILE=$(mktemp "${TMPDIR:-/tmp}/gh-agent-auth-pass.XXXXXX")
TESTS_FAIL_FILE=$(mktemp "${TMPDIR:-/tmp}/gh-agent-auth-fail.XXXXXX")
cleanup_path "$TESTS_PASS_FILE" "$TESTS_FAIL_FILE"

ok()   { echo "  ok:   $*";       echo 1 >> "$TESTS_PASS_FILE"; }
fail() { echo "  FAIL: $*" >&2;   echo 1 >> "$TESTS_FAIL_FILE"; }

report() {
  local p f
  p=$(wc -l < "$TESTS_PASS_FILE" 2>/dev/null | tr -d ' ')
  f=$(wc -l < "$TESTS_FAIL_FILE" 2>/dev/null | tr -d ' ')
  echo "  ---"
  echo "  passed: ${p:-0}, failed: ${f:-0}"
  [[ ${f:-0} -eq 0 ]]
}

# --------------------------------------------------------------------------
# make_sandbox VAR_NAME — fresh sandbox dir, prepended to PATH, registered
# for cleanup.
#
# Must be called as a direct function call, not via `dir=$(make_sandbox)`,
# because $(...) is a subshell; PATH mutation and cleanup registration
# wouldn't reach the caller. Sets the caller's named variable via printf -v.
# --------------------------------------------------------------------------

make_sandbox() {
  local _ms_var="$1"
  local _ms_dir
  _ms_dir=$(mktemp -d "${TMPDIR:-/tmp}/gh-agent-auth-test.XXXXXX")
  cleanup_path "$_ms_dir"
  PATH="$_ms_dir:$PATH"
  printf -v "$_ms_var" '%s' "$_ms_dir"
}

# --------------------------------------------------------------------------
# Mocks. Each takes a sandbox dir and writes a fake binary into it.
# --------------------------------------------------------------------------

# Resolve real openssl/curl paths BEFORE the sandbox shadows them on PATH.
REAL_OPENSSL=$(command -v openssl)
REAL_CURL=$(command -v curl)

# Mock openssl: emit FAKE_SIG for `dgst -sign`, delegate other subcommands
# (e.g. base64) to the real openssl.
mock_openssl() {
  local dir="$1"
  cat > "$dir/openssl" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "dgst" ]]; then
  printf 'FAKE_SIG'
else
  exec "$REAL_OPENSSL" "\$@"
fi
EOF
  chmod +x "$dir/openssl"
}

# Mock curl: log every invocation (CALL: argv) and POST body (BODY: ...) to
# \$dir/curl.log; return canned JSON for the two endpoints get-github-token
# hits. Last arg is treated as the URL.
mock_curl() {
  local dir="$1"
  cat > "$dir/curl" <<EOF
#!/usr/bin/env bash
log="$dir/curl.log"
echo "CALL: \$*" >> "\$log"
for ((i=1; i<=\$#; i++)); do
  if [[ "\${!i}" == "-d" ]]; then
    j=\$((i+1))
    echo "BODY: \${!j}" >> "\$log"
  fi
done

url="\${@: -1}"
case "\$url" in
  *app/installations)
    echo '[{"id":12345,"account":{"login":"test-org"}}]'
    ;;
  *access_tokens)
    echo '{"token":"ghs_TEST_TOKEN","expires_at":"2026-04-28T00:00:00Z"}'
    ;;
  *)
    echo "MOCK CURL: unknown URL: \$url" >&2
    exit 1
    ;;
esac
EOF
  chmod +x "$dir/curl"
}

# Set the env vars get-github-token expects when running with mocks.
mock_env_for_get_token() {
  export GITHUB_APP_ID=123456
  export GITHUB_APP_ORG=test-org
  export GH_AGENT_AUTH_KEY_DECRYPTED="$REPO_DIR/tests/fixtures/fake-key.pem"
  export GH_AGENT_AUTH_CONFIG=/dev/null
}

# Read curl's last POST body from the log (returns "" if none).
last_curl_body() {
  local dir="$1"
  grep '^BODY: ' "$dir/curl.log" 2>/dev/null | tail -n1 | sed 's/^BODY: //'
}
