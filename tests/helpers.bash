# tests/helpers.bash
# Shared helpers for gh-agent-auth tests.
# Source this from each test_*.sh file.

# Resolve REPO_DIR from the location of this helpers file.
HELPERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$HELPERS_DIR/.." && pwd)"

# Counters maintained by ok/fail.
TESTS_PASS=0
TESTS_FAIL=0

ok()   { echo "  ok:   $*";       TESTS_PASS=$((TESTS_PASS+1)); }
fail() { echo "  FAIL: $*" >&2;   TESTS_FAIL=$((TESTS_FAIL+1)); }

# Run at end of every test file:
report() {
  echo "  ---"
  echo "  passed: $TESTS_PASS, failed: $TESTS_FAIL"
  [[ $TESTS_FAIL -eq 0 ]]
}

# Make a per-test sandbox dir and prepend it to PATH.
# Returns the sandbox dir; cleans up via EXIT trap.
make_sandbox() {
  local dir
  dir=$(mktemp -d "${TMPDIR:-/tmp}/gh-agent-auth-test.XXXXXX")
  trap "rm -rf '$dir'" EXIT
  PATH="$dir:$PATH"
  echo "$dir"
}

# Resolve real openssl/curl path BEFORE we shadow them.
REAL_OPENSSL=$(command -v openssl)
REAL_CURL=$(command -v curl)
export REAL_OPENSSL REAL_CURL

# Install a mock openssl that emits FAKE_SIG for `dgst -sign` and
# delegates everything else to real openssl. Args: $1 = sandbox dir.
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

# Install a mock curl that:
#   - Logs every invocation (args + body) to \$dir/curl.log
#   - Returns canned JSON for /app/installations and /access_tokens
# Args: $1 = sandbox dir
mock_curl() {
  local dir="$1"
  cat > "$dir/curl" <<EOF
#!/usr/bin/env bash
log="$dir/curl.log"
echo "CALL: \$*" >> "\$log"
body=""
for ((i=1; i<=\$#; i++)); do
  if [[ "\${!i}" == "-d" ]]; then
    j=\$((i+1))
    body="\${!j}"
    echo "BODY: \$body" >> "\$log"
  fi
done

# Last arg is the URL.
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

# Set the env vars get-github-token needs to run with mocks.
mock_env_for_get_token() {
  export GITHUB_APP_ID=123456
  export GITHUB_APP_ORG=test-org
  export GH_AGENT_AUTH_KEY_DECRYPTED="$REPO_DIR/tests/fixtures/fake-key.pem"
  # Don't load any user config:
  export GH_AGENT_AUTH_CONFIG=/dev/null
}

# Read curl's POST body from log (last BODY: line). Returns "" if none.
last_curl_body() {
  local dir="$1"
  grep '^BODY: ' "$dir/curl.log" 2>/dev/null | tail -n1 | sed 's/^BODY: //'
}
