#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "$0")/helpers.bash"

echo "test: executed mode emits expires_at to stderr"
(
  make_sandbox dir
  mock_openssl "$dir"
  mock_curl "$dir"
  mock_env_for_get_token

  out_file=$(mktemp)
  err_file=$(mktemp)
  cleanup_path "$out_file" "$err_file"

  if "$REPO_DIR/bin/get-github-token" >"$out_file" 2>"$err_file"; then
    grep -q '^expires_at: 2026-04-28T00:00:00Z$' "$err_file" \
      && ok "stderr contains expires_at line" \
      || fail "stderr did not contain expires_at; got: $(cat "$err_file")"

    grep -q '^ghs_TEST_TOKEN$' "$out_file" \
      && ok "stdout contains the token" \
      || fail "stdout missing token; got: $(cat "$out_file")"
  else
    fail "get-github-token exited non-zero. stderr: $(cat "$err_file")"
  fi
)

report
