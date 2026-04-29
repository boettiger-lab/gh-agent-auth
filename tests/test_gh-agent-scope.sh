#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "$0")/helpers.bash"

# Mock that captures argv to a log so we can assert what gh-agent-scope passed.
# Args: $1 = sandbox dir, $2 = optional canned token (default ghs_FAKE)
mock_get_github_token() {
  local dir="$1"
  local token="${2:-ghs_FAKE}"
  cat > "$dir/get-github-token" <<EOF
#!/usr/bin/env bash
echo "ARGS: \$*" >> "$dir/gtt.log"
echo "$token"
echo "expires_at: 2026-04-28T00:00:00Z" >&2
EOF
  chmod +x "$dir/get-github-token"
}

echo "test: --help prints usage and exits 0"
(
  out=$("$REPO_DIR/bin/gh-agent-scope" --help 2>&1) \
    && [[ "$out" == *"Usage: gh-agent-scope"* ]] \
    && ok "help output looks right" \
    || fail "help failed or wrong; got: $out"
)

echo "test: explicit --repo passes through to get-github-token"
(
  make_sandbox dir
  mock_get_github_token "$dir"

  "$REPO_DIR/bin/gh-agent-scope" --repo my-org/foo >/dev/null 2>&1 \
    || fail "non-zero exit"

  args=$(cat "$dir/gtt.log")
  [[ "$args" == "ARGS: --repo my-org/foo" ]] \
    && ok "passed --repo through correctly" \
    || fail "expected ARGS: --repo my-org/foo, got: $args"
)

echo "test: auto-detects repo from origin remote"
(
  make_sandbox dir
  mock_get_github_token "$dir"

  # Make a fake repo with a github.com origin
  repo_dir="$dir/clone"
  mkdir -p "$repo_dir"
  ( cd "$repo_dir" && git init -q && git remote add origin https://github.com/auto-org/auto-repo.git )

  ( cd "$repo_dir" && "$REPO_DIR/bin/gh-agent-scope" >/dev/null 2>&1 ) \
    || fail "non-zero exit"

  args=$(cat "$dir/gtt.log")
  [[ "$args" == "ARGS: --repo auto-org/auto-repo" ]] \
    && ok "auto-detected repo from origin" \
    || fail "expected --repo auto-org/auto-repo, got: $args"
)

echo "test: handles SSH-style origin URL"
(
  make_sandbox dir
  mock_get_github_token "$dir"

  repo_dir="$dir/clone"
  mkdir -p "$repo_dir"
  ( cd "$repo_dir" && git init -q && git remote add origin git@github.com:ssh-org/ssh-repo.git )

  ( cd "$repo_dir" && "$REPO_DIR/bin/gh-agent-scope" >/dev/null 2>&1 ) \
    || fail "non-zero exit"

  args=$(cat "$dir/gtt.log")
  [[ "$args" == "ARGS: --repo ssh-org/ssh-repo" ]] \
    && ok "auto-detected from SSH origin" \
    || fail "expected --repo ssh-org/ssh-repo, got: $args"
)

echo "test: print-only mode prints token to stdout, expires_at to stderr"
(
  make_sandbox dir
  mock_get_github_token "$dir" "ghs_PRINTONLY_TOKEN"

  out=$("$REPO_DIR/bin/gh-agent-scope" --repo test-org/foo 2>/dev/null)
  err=$("$REPO_DIR/bin/gh-agent-scope" --repo test-org/foo 2>&1 >/dev/null)

  [[ "$out" == "ghs_PRINTONLY_TOKEN" ]] \
    && ok "stdout is just the token" \
    || fail "stdout=[$out]"

  [[ "$err" == *"expires_at: 2026-04-28T00:00:00Z"* ]] \
    && ok "stderr has expires_at" \
    || fail "stderr=[$err]"
)

echo "test: --permissions flag is passed through"
(
  make_sandbox dir
  mock_get_github_token "$dir"

  "$REPO_DIR/bin/gh-agent-scope" --repo o/r --permissions contents=read >/dev/null 2>&1 \
    || fail "non-zero exit"

  args=$(cat "$dir/gtt.log")
  [[ "$args" == "ARGS: --repo o/r --permissions contents=read" ]] \
    && ok "permissions flag passed through" \
    || fail "got: $args"
)

echo "test: multiple --repo flags are passed through individually"
(
  make_sandbox dir
  mock_get_github_token "$dir"

  "$REPO_DIR/bin/gh-agent-scope" --repo o/r1 --repo o/r2 >/dev/null 2>&1 \
    || fail "non-zero exit"

  args=$(cat "$dir/gtt.log")
  [[ "$args" == "ARGS: --repo o/r1 --repo o/r2" ]] \
    && ok "both --repo flags passed" \
    || fail "got: $args"
)

echo "test: -- COMMAND runs subprocess with GITHUB_TOKEN, GH_TOKEN in env"
(
  make_sandbox dir
  mock_get_github_token "$dir" "ghs_EXEC_TOKEN"

  out=$("$REPO_DIR/bin/gh-agent-scope" --repo o/r -- env 2>/dev/null) \
    || fail "non-zero exit from subprocess"

  echo "$out" | grep -q '^GITHUB_TOKEN=ghs_EXEC_TOKEN$' \
    && ok "GITHUB_TOKEN in env" \
    || fail "GITHUB_TOKEN not set in subprocess env"

  echo "$out" | grep -q '^GH_TOKEN=ghs_EXEC_TOKEN$' \
    && ok "GH_TOKEN in env" \
    || fail "GH_TOKEN not set in subprocess env"
)

echo "test: -- COMMAND injects GIT_CONFIG_COUNT credential helper chain"
(
  make_sandbox dir
  mock_get_github_token "$dir" "ghs_GIT_TOKEN"

  out=$("$REPO_DIR/bin/gh-agent-scope" --repo o/r -- env 2>/dev/null) \
    || fail "non-zero exit"

  echo "$out" | grep -q '^GIT_CONFIG_COUNT=2$' \
    && ok "GIT_CONFIG_COUNT=2" \
    || fail "GIT_CONFIG_COUNT not set"

  echo "$out" | grep -q '^GIT_CONFIG_KEY_0=credential.https://github.com.helper$' \
    && ok "key 0 is credential helper key" \
    || fail "GIT_CONFIG_KEY_0 wrong"

  # Value 0 should be empty (clears inherited helpers)
  echo "$out" | grep -q '^GIT_CONFIG_VALUE_0=$' \
    && ok "value 0 is empty (clears inherited helpers)" \
    || fail "GIT_CONFIG_VALUE_0 not empty"

  echo "$out" | grep -q '^GIT_CONFIG_KEY_1=credential.https://github.com.helper$' \
    && ok "key 1 is credential helper key" \
    || fail "GIT_CONFIG_KEY_1 wrong"

  echo "$out" | grep -q '^GIT_CONFIG_VALUE_1=!f(){' \
    && ok "value 1 contains inline helper function" \
    || fail "GIT_CONFIG_VALUE_1 not the inline helper"
)

echo "test: subprocess inherits exit code"
(
  make_sandbox dir
  mock_get_github_token "$dir"

  if "$REPO_DIR/bin/gh-agent-scope" --repo o/r -- bash -c 'exit 42' 2>/dev/null; then
    fail "expected non-zero exit"
  else
    rc=$?
    [[ $rc -eq 42 ]] \
      && ok "exit code 42 propagated" \
      || fail "expected 42, got $rc"
  fi
)

report
