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

echo "test: --repo flag adds repositories[] to POST body"
(
  make_sandbox dir
  mock_openssl "$dir"
  mock_curl "$dir"
  mock_env_for_get_token

  "$REPO_DIR/bin/get-github-token" --repo test-org/foo --repo test-org/bar \
    >/dev/null 2>&1 || fail "exited non-zero"

  body=$(last_curl_body "$dir")
  if [[ -z "$body" ]]; then
    fail "curl was not called with -d (no body in log)"
  else
    repos=$(echo "$body" | jq -c '.repositories // []')
    if [[ "$repos" == '["foo","bar"]' ]]; then
      ok "POST body has correct repositories array: $repos"
    else
      fail "expected repositories=[\"foo\",\"bar\"], got: $repos (full body: $body)"
    fi
  fi
)

echo "test: --repo with cross-org value errors out"
(
  make_sandbox dir
  mock_openssl "$dir"
  mock_curl "$dir"
  mock_env_for_get_token

  err_file=$(mktemp)
  cleanup_path "$err_file"

  if "$REPO_DIR/bin/get-github-token" --repo other-org/foo >/dev/null 2>"$err_file"; then
    fail "expected non-zero exit for cross-org repo"
  else
    grep -qi 'other-org' "$err_file" \
      && ok "error message mentions cross-org repo" \
      || fail "error did not mention 'other-org': $(cat "$err_file")"
  fi
)

echo "test: --repo with bare name (no slash) is rejected"
(
  make_sandbox dir
  mock_openssl "$dir"
  mock_curl "$dir"
  mock_env_for_get_token

  err_file=$(mktemp)
  cleanup_path "$err_file"

  if "$REPO_DIR/bin/get-github-token" --repo solo-name >/dev/null 2>"$err_file"; then
    fail "expected non-zero exit for bare repo name"
  else
    grep -qi 'OWNER/REPO' "$err_file" \
      && ok "error message points at the OWNER/REPO form requirement" \
      || fail "error did not mention OWNER/REPO form: $(cat "$err_file")"
  fi
)

echo "test: --permissions flag adds permissions{} to POST body"
(
  make_sandbox dir
  mock_openssl "$dir"
  mock_curl "$dir"
  mock_env_for_get_token

  "$REPO_DIR/bin/get-github-token" --permissions contents=read,issues=write \
    >/dev/null 2>&1 || fail "exited non-zero"

  body=$(last_curl_body "$dir")
  perms=$(echo "$body" | jq -c '.permissions // {}')
  if [[ "$perms" == '{"contents":"read","issues":"write"}' ]]; then
    ok "POST body has correct permissions object: $perms"
  else
    fail "expected permissions={\"contents\":\"read\",\"issues\":\"write\"}, got: $perms"
  fi
)

echo "test: --repo and --permissions combine in body"
(
  make_sandbox dir
  mock_openssl "$dir"
  mock_curl "$dir"
  mock_env_for_get_token

  "$REPO_DIR/bin/get-github-token" --repo test-org/foo --permissions contents=read \
    >/dev/null 2>&1 || fail "exited non-zero"

  body=$(last_curl_body "$dir")
  has_both=$(echo "$body" | jq -c '{r: .repositories, p: .permissions}')
  if [[ "$has_both" == '{"r":["foo"],"p":{"contents":"read"}}' ]]; then
    ok "body has both repositories and permissions: $has_both"
  else
    fail "expected both keys, got: $has_both"
  fi
)

echo "test: cold-start decrypts via age when KEY_DECRYPTED is missing"
(
  make_sandbox dir
  mock_openssl "$dir"
  mock_curl "$dir"
  mock_age "$dir"

  echo "ENCRYPTED_DATA" > "$dir/key.age"

  export GITHUB_APP_ID=123456
  export GITHUB_APP_ORG=test-org
  export GH_AGENT_AUTH_KEY_DECRYPTED="$dir/does-not-exist"
  export GH_AGENT_AUTH_KEY_ENCRYPTED="$dir/key.age"
  export GH_AGENT_AUTH_CONFIG=/dev/null

  "$REPO_DIR/bin/get-github-token" >/dev/null 2>&1 \
    || fail "get-github-token failed in cold-start mode"

  if [[ -f "$dir/age.log" ]]; then
    grep -q '^AGE_CALLED: ' "$dir/age.log" \
      && ok "age was invoked for decryption" \
      || fail "age log exists but no AGE_CALLED line"
  else
    fail "age was not invoked"
  fi
)

echo "test: errors clearly when neither decrypted nor encrypted key is available"
(
  make_sandbox dir
  mock_openssl "$dir"
  mock_curl "$dir"

  export GITHUB_APP_ID=123456
  export GITHUB_APP_ORG=test-org
  export GH_AGENT_AUTH_KEY_DECRYPTED="$dir/does-not-exist"
  unset GH_AGENT_AUTH_KEY_ENCRYPTED
  export GH_AGENT_AUTH_CONFIG=/dev/null

  err_file=$(mktemp)
  cleanup_path "$err_file"

  if "$REPO_DIR/bin/get-github-token" >/dev/null 2>"$err_file"; then
    fail "expected non-zero exit when no key available"
  else
    grep -qi 'gh-agent-unlock\|GH_AGENT_AUTH_KEY_ENCRYPTED' "$err_file" \
      && ok "error message points at the two recovery paths" \
      || fail "error not actionable: $(cat "$err_file")"
  fi
)

report
