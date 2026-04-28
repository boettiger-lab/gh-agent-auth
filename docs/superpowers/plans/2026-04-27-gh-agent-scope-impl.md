# gh-agent-scope Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `gh-agent-scope` subprocess wrapper that mints a GitHub App installation token narrowed to specific repos and permissions, then `exec`s a command with the token in env. Like Codespaces, but for local agent runs.

**Architecture:** Two scripts work together. `bin/get-github-token` (existing) gains `--repo` and `--permissions` flags and now always prints `expires_at` to stderr. `bin/gh-agent-scope` (new) is a thin wrapper that calls `get-github-token`, then either prints the token (no `--`) or `exec`s a subprocess with `GITHUB_TOKEN`, `GH_TOKEN`, and an inline git credential-helper config in env. No persistent state; token lifetime equals subprocess lifetime.

**Tech Stack:** bash 3.2+ (works on macOS default), `openssl`, `curl`, `jq`, `git ≥ 2.31`, `age` + `age-plugin-yubikey`. No build system; tests are plain bash.

**Spec:** [`docs/superpowers/specs/2026-04-27-gh-agent-scope-design.md`](../specs/2026-04-27-gh-agent-scope-design.md)

---

## File structure

```
bin/
  get-github-token             [MODIFY] add --repo, --permissions; always emit expires_at to stderr
  gh-agent-scope               [CREATE] new wrapper, ~100 LOC
install.sh                     [MODIFY] Darwin detection
README.md                      [MODIFY] usage docs + OS support matrix
tests/
  run.sh                       [CREATE] test runner
  helpers.bash                 [CREATE] shared fakes/assertions
  test_get-github-token.sh     [CREATE] tests for get-github-token additions
  test_gh-agent-scope.sh       [CREATE] tests for gh-agent-scope
  fixtures/
    fake-key.pem               [CREATE] dummy file (openssl is mocked, content unused)
.gitignore                     [MODIFY] add tests/tmp/
```

The bin/ scripts already exist; tests/ is new.

---

## Task 1: Test scaffolding

**Files:**
- Create: `tests/run.sh`
- Create: `tests/helpers.bash`
- Create: `tests/fixtures/fake-key.pem`
- Modify: `.gitignore`

- [ ] **Step 1: Create the test fixture file**

```bash
mkdir -p tests/fixtures
echo "FAKE_KEY_CONTENT_NOT_REAL" > tests/fixtures/fake-key.pem
chmod 600 tests/fixtures/fake-key.pem
```

- [ ] **Step 2: Create `tests/helpers.bash`**

```bash
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
```

- [ ] **Step 3: Create `tests/run.sh`**

```bash
#!/usr/bin/env bash
# Run all test_*.sh files in this directory, summarize results.
set -uo pipefail

cd "$(dirname "$0")"

ANY_FAIL=0
shopt -s nullglob
for f in test_*.sh; do
  echo "=== $f ==="
  if bash "$f"; then
    :
  else
    ANY_FAIL=1
  fi
done

echo
if (( ANY_FAIL == 0 )); then
  echo "ALL TESTS PASSED"
  exit 0
else
  echo "SOME TESTS FAILED"
  exit 1
fi
```

```bash
chmod +x tests/run.sh
```

- [ ] **Step 4: Add `tests/tmp/` to `.gitignore`**

Append to `.gitignore`:

```
# Test sandbox dirs (in case any leak)
tests/tmp/
```

- [ ] **Step 5: Smoke-test the runner with no tests**

Run: `bash tests/run.sh`
Expected: prints "ALL TESTS PASSED" (no `test_*.sh` files yet, vacuously passes).

- [ ] **Step 6: Commit**

```bash
git add tests/ .gitignore
git commit -m "Add test scaffolding: bash runner, mock helpers, fixtures"
```

---

## Task 2: get-github-token — always emit expires_at to stderr

**Files:**
- Modify: `bin/get-github-token` (output block at the bottom)
- Create: `tests/test_get-github-token.sh`

The current behavior: when sourced, prints "GITHUB_TOKEN set (expires X)" to stderr and exports `GITHUB_TOKEN`. When executed, prints token to stdout, nothing on stderr. We change executed-mode to also emit `expires_at: <iso>` to stderr so callers like `gh-agent-scope` can parse it.

- [ ] **Step 1: Write the failing test**

Create `tests/test_get-github-token.sh`:

```bash
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
  trap "rm -f '$out_file' '$err_file'" EXIT

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
```

```bash
chmod +x tests/test_get-github-token.sh
```

- [ ] **Step 2: Run the test, verify it FAILS**

Run: `bash tests/run.sh`
Expected: FAIL — current `get-github-token` does not emit `expires_at:` to stderr in executed mode.

- [ ] **Step 3: Modify `bin/get-github-token`'s output block**

Find this block at the bottom of `bin/get-github-token`:

```bash
# When sourced: export GITHUB_TOKEN. When executed: print the token.
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
  export GITHUB_TOKEN="$TOKEN"
  echo "GITHUB_TOKEN set (expires $EXPIRES)" >&2
else
  echo "$TOKEN"
fi
```

Replace it with:

```bash
# Always emit expiry to stderr so callers can capture it.
echo "expires_at: $EXPIRES" >&2

# When sourced: export GITHUB_TOKEN. When executed: print the token to stdout.
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
  export GITHUB_TOKEN="$TOKEN"
else
  echo "$TOKEN"
fi
```

- [ ] **Step 4: Run the test, verify it PASSES**

Run: `bash tests/run.sh`
Expected: PASS, both ok lines.

- [ ] **Step 5: Commit**

```bash
git add bin/get-github-token tests/test_get-github-token.sh
git commit -m "get-github-token: always emit expires_at to stderr

Previously expiry only appeared when sourced. Callers like gh-agent-scope
that capture the token via command substitution need the expiry too."
```

---

## Task 3: get-github-token — `--repo` flag

**Files:**
- Modify: `bin/get-github-token` (add flag parsing + body construction)
- Modify: `tests/test_get-github-token.sh` (add new test)

- [ ] **Step 1: Write the failing test**

Append to `tests/test_get-github-token.sh` (before the final `report`):

```bash
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
  trap "rm -f '$err_file'" EXIT

  if "$REPO_DIR/bin/get-github-token" --repo other-org/foo >/dev/null 2>"$err_file"; then
    fail "expected non-zero exit for cross-org repo"
  else
    grep -qi 'other-org' "$err_file" \
      && ok "error message mentions cross-org repo" \
      || fail "error did not mention 'other-org': $(cat "$err_file")"
  fi
)
```

- [ ] **Step 2: Run, verify both new tests FAIL**

Run: `bash tests/run.sh`
Expected: 2 FAILs (existing tests still pass; the two new tests fail because no flag parsing yet).

- [ ] **Step 3: Add flag parsing to `bin/get-github-token`**

Find the section right after the config-file sourcing block (before "Validate inputs"). Insert this flag-parsing block:

```bash
# --------------------------------------------------------------------------
# Parse flags
# --------------------------------------------------------------------------

REPOS=()
PERMS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      [[ $# -ge 2 ]] || { echo "ERROR: --repo requires an argument" >&2; exit 1; }
      REPOS+=("$2"); shift 2 ;;
    --permissions)
      [[ $# -ge 2 ]] || { echo "ERROR: --permissions requires an argument" >&2; exit 1; }
      PERMS="$2"; shift 2 ;;
    -h|--help)
      cat <<'EOF'
Usage: get-github-token [--repo OWNER/REPO]... [--permissions key=level,...]

Mints a GitHub App installation token. Prints token to stdout and
"expires_at: <iso>" to stderr.

Without flags, mints a token with the App's full installation scope.
With --repo, scopes to the listed repos (must be in $GITHUB_APP_ORG).
With --permissions, narrows to the listed permissions (must be a subset
of the App installation's permissions; GitHub returns 422 otherwise).
EOF
      exit 0 ;;
    *)
      echo "ERROR: unknown argument: $1" >&2; exit 1 ;;
  esac
done
```

- [ ] **Step 4: Add body construction for --repo**

Find the section that does the access_tokens POST. The current code looks like:

```bash
RESPONSE=$(curl -s -X POST \
  -H "Authorization: Bearer $JWT" \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/app/installations/${INSTALLATION_ID}/access_tokens")
```

Replace it with:

```bash
# Build POST body from --repo / --permissions flags.
BODY="{}"

if [[ ${#REPOS[@]} -gt 0 ]]; then
  REPO_NAMES=()
  for r in "${REPOS[@]}"; do
    case "$r" in
      "$APP_ORG"/*)
        REPO_NAMES+=("${r#*/}") ;;
      */*)
        die "repo $r is not in $APP_ORG (App is installed there). Pass repos owned by $APP_ORG only." ;;
      *)
        REPO_NAMES+=("$r") ;;  # bare name, assume same org
    esac
  done
  REPOS_JSON=$(printf '%s\n' "${REPO_NAMES[@]}" | jq -R . | jq -s .)
  BODY=$(printf '%s' "$BODY" | jq --argjson repos "$REPOS_JSON" '.repositories = $repos')
fi

CURL_ARGS=(-fsS -X POST
  -H "Authorization: Bearer $JWT"
  -H "Accept: application/vnd.github+json"
  -H "X-GitHub-Api-Version: 2022-11-28")

if [[ "$BODY" != "{}" ]]; then
  CURL_ARGS+=(-H "Content-Type: application/json" -d "$BODY")
fi

RESPONSE=$(curl "${CURL_ARGS[@]}" \
  "https://api.github.com/app/installations/${INSTALLATION_ID}/access_tokens")
```

Note: change the curl flag from `-s` to `-fsS` so HTTP errors surface.

- [ ] **Step 5: Run tests, verify all PASS**

Run: `bash tests/run.sh`
Expected: all 4 ok lines pass (the 2 from Task 2 and the 2 added here).

- [ ] **Step 6: Commit**

```bash
git add bin/get-github-token tests/test_get-github-token.sh
git commit -m "get-github-token: --repo flag for repo-scoped tokens

Repeatable --repo OWNER/REPO flag adds repositories[] to the access_tokens
POST body. Cross-org repos are rejected. Bare repo names are accepted and
assumed to belong to \$GITHUB_APP_ORG."
```

---

## Task 4: get-github-token — `--permissions` flag

**Files:**
- Modify: `bin/get-github-token` (extend body construction)
- Modify: `tests/test_get-github-token.sh` (add test)

- [ ] **Step 1: Write the failing test**

Append to `tests/test_get-github-token.sh` (before the final `report`):

```bash
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
```

- [ ] **Step 2: Run, verify new tests FAIL**

Run: `bash tests/run.sh`
Expected: 2 new FAILs (no --permissions handling yet).

- [ ] **Step 3: Extend body construction**

In `bin/get-github-token`, find the body-construction block from Task 3. After the `if [[ ${#REPOS[@]} -gt 0 ]]; then ... fi` block but before the `CURL_ARGS=(...)` block, add:

```bash
if [[ -n "$PERMS" ]]; then
  # Convert "key=val,key=val" into a JSON object.
  PERMS_JSON=$(printf '%s\n' "$PERMS" | tr ',' '\n' \
    | jq -R 'select(length > 0) | split("=") | {(.[0]): .[1]}' \
    | jq -s 'add // {}')
  BODY=$(printf '%s' "$BODY" | jq --argjson perms "$PERMS_JSON" '.permissions = $perms')
fi
```

- [ ] **Step 4: Run tests, verify all PASS**

Run: `bash tests/run.sh`
Expected: all 6 ok lines pass.

- [ ] **Step 5: Commit**

```bash
git add bin/get-github-token tests/test_get-github-token.sh
git commit -m "get-github-token: --permissions flag for narrowing token scope

Comma-separated key=level pairs become permissions{} in the access_tokens
POST body. GitHub validates the keys match a subset of the App's grant
and returns 422 otherwise — we surface that error verbatim."
```

---

## Task 5: get-github-token — cold-start decryption via process substitution

**Files:**
- Modify: `bin/get-github-token` (the JWT-signing block)
- Modify: `tests/test_get-github-token.sh` (add test)
- Modify: `tests/helpers.bash` (add `mock_age` helper)

The spec specifies two paths for the App private key. The fast path (use the
already-unlocked `/dev/shm` key) is what `get-github-token` does today. The
cold-start path — decrypt via age+age-plugin-yubikey transiently using
process substitution — is the macOS path. Without it, macOS users have no
way to use `gh-agent-scope` directly.

- [ ] **Step 1: Add `mock_age` to `tests/helpers.bash`**

Append to `tests/helpers.bash`:

```bash
# Install mock age + age-plugin-yubikey that emit fake outputs and log calls.
# Args: $1 = sandbox dir
mock_age() {
  local dir="$1"
  cat > "$dir/age" <<EOF
#!/usr/bin/env bash
echo "AGE_CALLED: \$*" >> "$dir/age.log"
# Emit fake decrypted key content. openssl is mocked too, so contents don't matter.
echo "FAKE_DECRYPTED_KEY"
EOF
  chmod +x "$dir/age"

  cat > "$dir/age-plugin-yubikey" <<EOF
#!/usr/bin/env bash
echo "AGE_PLUGIN_CALLED: \$*" >> "$dir/age.log"
echo "FAKE_IDENTITY"
EOF
  chmod +x "$dir/age-plugin-yubikey"
}
```

- [ ] **Step 2: Write the failing test**

Append to `tests/test_get-github-token.sh` (before `report`):

```bash
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
  trap "rm -f '$err_file'" EXIT

  if "$REPO_DIR/bin/get-github-token" >/dev/null 2>"$err_file"; then
    fail "expected non-zero exit when no key available"
  else
    grep -qi 'gh-agent-unlock\|GH_AGENT_AUTH_KEY_ENCRYPTED' "$err_file" \
      && ok "error message points at the two recovery paths" \
      || fail "error not actionable: $(cat "$err_file")"
  fi
)
```

- [ ] **Step 3: Run, verify the new tests FAIL**

Run: `bash tests/run.sh`
Expected: 2 new FAILs in `test_get-github-token.sh`. The current script just dies when `$KEY_PATH` is missing; it has no fallback.

- [ ] **Step 4: Modify the JWT-signing block in `bin/get-github-token`**

Find the existing block:

```bash
[[ -f "$KEY_PATH" ]] || die "Private key not found at $KEY_PATH.
Decrypt it first:
  age --decrypt -i <(age-plugin-yubikey --identity) \\
    /path/to/github-app-private-key.pem.age \\
    > /dev/shm/github-app-private-key.pem"
```

Replace with:

```bash
KEY_ENCRYPTED="${GH_AGENT_AUTH_KEY_ENCRYPTED:-}"

if [[ ! -f "$KEY_PATH" && ! -f "$KEY_ENCRYPTED" ]]; then
  die "No private key available.
Either unlock the persistent key:
  gh-agent-unlock
or set GH_AGENT_AUTH_KEY_ENCRYPTED to the path of your age-encrypted .pem
in $CONFIG_FILE or your environment."
fi
```

Then find the existing signing block:

```bash
SIG=$(printf '%s' "${HEADER}.${PAYLOAD}" \
  | openssl dgst -sha256 -sign "$KEY_PATH" \
  | base64url)
```

Replace with:

```bash
if [[ -f "$KEY_PATH" ]]; then
  # Fast path: persistent key already unlocked
  SIG=$(printf '%s' "${HEADER}.${PAYLOAD}" \
    | openssl dgst -sha256 -sign "$KEY_PATH" \
    | base64url)
else
  # Cold start: decrypt via age + age-plugin-yubikey through process
  # substitution so the decrypted key never lands on disk.
  command -v age              >/dev/null || die "age not on PATH (needed for cold-start decryption)"
  command -v age-plugin-yubikey >/dev/null || die "age-plugin-yubikey not on PATH"

  SIG=$(printf '%s' "${HEADER}.${PAYLOAD}" \
    | openssl dgst -sha256 -sign <(age --decrypt -i <(age-plugin-yubikey --identity) "$KEY_ENCRYPTED") \
    | base64url)
fi
```

- [ ] **Step 5: Run tests, verify all PASS**

Run: `bash tests/run.sh`
Expected: all green (the previous 6 ok lines plus 2 new ones).

- [ ] **Step 6: Commit**

```bash
git add bin/get-github-token tests/helpers.bash tests/test_get-github-token.sh
git commit -m "get-github-token: cold-start decryption via process substitution

When the persistent /dev/shm key isn't unlocked but
GH_AGENT_AUTH_KEY_ENCRYPTED points at an age-encrypted .pem, decrypt
transiently via process substitution. The decrypted key never lands
on disk — openssl reads it from /dev/fd/N during one signing pass.

This is the macOS path: gh-agent-scope works without a persistent
unlock, at the cost of one YubiKey touch per invocation."
```

---

## Task 6: gh-agent-scope skeleton with flag parsing and repo auto-detect

**Files:**
- Create: `bin/gh-agent-scope`
- Create: `tests/test_gh-agent-scope.sh`

- [ ] **Step 1: Write the failing test**

Create `tests/test_gh-agent-scope.sh`:

```bash
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

report
```

```bash
chmod +x tests/test_gh-agent-scope.sh
```

- [ ] **Step 2: Run, verify ALL gh-agent-scope tests FAIL**

Run: `bash tests/run.sh`
Expected: 4 FAILs in `test_gh-agent-scope.sh` (script doesn't exist yet); `test_get-github-token.sh` still all-pass.

- [ ] **Step 3: Create the skeleton `bin/gh-agent-scope`**

```bash
#!/usr/bin/env bash
# gh-agent-scope — mint a GitHub App installation token narrowed to specific
# repos and permissions, then either print it (no -- COMMAND) or exec a
# subprocess with it in env. Codespaces-style ephemeral credentials.
set -euo pipefail

CONFIG_FILE="${GH_AGENT_AUTH_CONFIG:-$HOME/.config/gh-agent-auth/config}"
[[ -f "$CONFIG_FILE" ]] && . "$CONFIG_FILE"

die() { echo "ERROR: $*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: gh-agent-scope [--repo OWNER/REPO]... [--permissions key=level,...] [-- COMMAND [ARGS...]]

Mint a GitHub App installation token scoped to specific repos and/or
permissions. With -- COMMAND, exec the command with the token in env
(GITHUB_TOKEN, GH_TOKEN, plus an inline git credential helper).
Without -- COMMAND, print the token to stdout (expiry to stderr).

Options:
  --repo OWNER/REPO       Scope to this repo. Repeatable.
                          Default: cwd's origin remote, if it's github.com.
  --permissions K=V,...   Narrow to a subset of the App's permissions
                          (e.g. contents=read,issues=write).
  -h, --help              Show this help.
EOF
}

# --------------------------------------------------------------------------
# Parse flags
# --------------------------------------------------------------------------

REPOS=()
PERMS=""
CMD=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      [[ $# -ge 2 ]] || die "--repo requires an argument"
      REPOS+=("$2"); shift 2 ;;
    --permissions)
      [[ $# -ge 2 ]] || die "--permissions requires an argument"
      PERMS="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    --)
      shift; CMD=("$@"); break ;;
    -*)
      die "unknown flag: $1 (use --help for usage)" ;;
    *)
      die "unexpected positional argument: $1 (use -- to separate the command)" ;;
  esac
done

# --------------------------------------------------------------------------
# Resolve the target repo set
# --------------------------------------------------------------------------

if [[ ${#REPOS[@]} -eq 0 ]]; then
  url=$(git remote get-url origin 2>/dev/null) \
    || die "no --repo given and not in a git repo (or no 'origin' remote). Pass --repo OWNER/REPO."

  case "$url" in
    https://github.com/*)
      repo=${url#https://github.com/}; repo=${repo%.git} ;;
    git@github.com:*)
      repo=${url#git@github.com:}; repo=${repo%.git} ;;
    *)
      die "origin is not a github.com remote: $url. Pass --repo OWNER/REPO explicitly." ;;
  esac
  REPOS+=("$repo")
fi

# --------------------------------------------------------------------------
# Mint the token
# --------------------------------------------------------------------------

gh_args=()
for r in "${REPOS[@]}"; do gh_args+=(--repo "$r"); done
[[ -n "$PERMS" ]] && gh_args+=(--permissions "$PERMS")

err_file=$(mktemp)
trap 'rm -f "$err_file"' EXIT

TOKEN=$(get-github-token "${gh_args[@]}" 2>"$err_file") || {
  cat "$err_file" >&2
  exit 1
}

EXPIRY_LINE=$(grep '^expires_at: ' "$err_file" | tail -n1 || true)
EXPIRY=${EXPIRY_LINE#expires_at: }

# --------------------------------------------------------------------------
# Print-only mode
# --------------------------------------------------------------------------

if [[ ${#CMD[@]} -eq 0 ]]; then
  echo "$TOKEN"
  echo "expires_at: $EXPIRY" >&2
  exit 0
fi

# --------------------------------------------------------------------------
# Subprocess exec mode (filled in in Task 8)
# --------------------------------------------------------------------------

die "subprocess exec mode not implemented yet"
```

```bash
chmod +x bin/gh-agent-scope
```

- [ ] **Step 4: Run tests, verify Task 6 tests PASS**

Run: `bash tests/run.sh`
Expected: 4 ok lines for `test_gh-agent-scope.sh` (help, explicit --repo, auto-detect HTTPS, auto-detect SSH). `test_get-github-token.sh` all 6 still pass.

- [ ] **Step 5: Commit**

```bash
git add bin/gh-agent-scope tests/test_gh-agent-scope.sh
git commit -m "gh-agent-scope: skeleton with flag parsing and repo auto-detect

Parses --repo (repeatable), --permissions, --help, and -- command.
Auto-detects repo from cwd's origin remote (https://github.com/X/Y or
git@github.com:X/Y). Calls get-github-token with the right flags.
Print-only mode (no -- COMMAND) is functional. Subprocess mode comes next."
```

---

## Task 7: gh-agent-scope — print-only mode end-to-end test

**Files:**
- Modify: `tests/test_gh-agent-scope.sh` (add tests)

This task adds a test for the existing print-only behavior to lock it in before we add the subprocess-exec branch in Task 8.

- [ ] **Step 1: Write the failing test**

Append to `tests/test_gh-agent-scope.sh` (before `report`):

```bash
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
```

- [ ] **Step 2: Run, verify the new tests PASS already (they exercise existing code)**

Run: `bash tests/run.sh`
Expected: all green; 3 new ok lines.

This is a passing-test-on-first-run case because the print-only path is already implemented in Task 6. The TDD cycle shifts here: the test locks in behavior we just shipped, before we add the next feature.

- [ ] **Step 3: Commit**

```bash
git add tests/test_gh-agent-scope.sh
git commit -m "Test gh-agent-scope print-only mode and flag passthrough"
```

---

## Task 8: gh-agent-scope — subprocess exec mode with env injection

**Files:**
- Modify: `bin/gh-agent-scope` (replace the "not implemented yet" stub)
- Modify: `tests/test_gh-agent-scope.sh` (add tests)

- [ ] **Step 1: Write the failing test**

Append to `tests/test_gh-agent-scope.sh` (before `report`):

```bash
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
```

- [ ] **Step 2: Run, verify the new tests FAIL**

Run: `bash tests/run.sh`
Expected: `gh-agent-scope` errors out with "subprocess exec mode not implemented yet" → tests fail.

- [ ] **Step 3: Replace the stub in `bin/gh-agent-scope`**

Find the block at the bottom of `bin/gh-agent-scope`:

```bash
# --------------------------------------------------------------------------
# Subprocess exec mode (filled in in Task 8)
# --------------------------------------------------------------------------

die "subprocess exec mode not implemented yet"
```

Replace with:

```bash
# --------------------------------------------------------------------------
# Subprocess exec mode
# --------------------------------------------------------------------------

# git ≥ 2.31 is required for GIT_CONFIG_COUNT.
if command -v git >/dev/null; then
  git_ver=$(git --version | awk '{print $3}')
  git_major=${git_ver%%.*}
  rest=${git_ver#*.}
  git_minor=${rest%%.*}
  if (( git_major < 2 || (git_major == 2 && git_minor < 31) )); then
    die "git $git_ver is too old; need git ≥ 2.31 for GIT_CONFIG_COUNT support."
  fi
fi

# Inline git credential helper that reads GITHUB_TOKEN from the environment.
# The empty helper='' first clears any inherited helper chain so the parent
# shell's git-credential-github-app (full-permission) doesn't intercept.
GIT_CRED='!f() { echo username=x-access-token; echo "password=$GITHUB_TOKEN"; }; f'

exec env \
  GITHUB_TOKEN="$TOKEN" \
  GH_TOKEN="$TOKEN" \
  GIT_CONFIG_COUNT=2 \
  GIT_CONFIG_KEY_0='credential.https://github.com.helper' \
  GIT_CONFIG_VALUE_0='' \
  GIT_CONFIG_KEY_1='credential.https://github.com.helper' \
  GIT_CONFIG_VALUE_1="$GIT_CRED" \
  -- "${CMD[@]}"
```

- [ ] **Step 4: Run tests, verify all PASS**

Run: `bash tests/run.sh`
Expected: all ok lines pass across both test files.

- [ ] **Step 5: Commit**

```bash
git add bin/gh-agent-scope tests/test_gh-agent-scope.sh
git commit -m "gh-agent-scope: subprocess exec mode with env injection

Sets GITHUB_TOKEN, GH_TOKEN, and an inline git credential helper via
GIT_CONFIG_COUNT (git 2.31+). The inherited credential helper chain is
explicitly cleared with an empty helper='' first, so the parent shell's
gh-agent-auth helper can't intercept and silently mint a full-permission
token. The subprocess inherits exit code via exec."
```

---

## Task 9: gh-agent-scope — error handling for old git and bad URLs

**Files:**
- Modify: `tests/test_gh-agent-scope.sh` (add tests)

The git version check and bad-URL handling were added in earlier tasks; this task locks them in with tests. No code changes to `gh-agent-scope` should be needed.

- [ ] **Step 1: Write the tests**

Append to `tests/test_gh-agent-scope.sh` (before `report`):

```bash
echo "test: errors when not in a git repo and no --repo given"
(
  make_sandbox dir
  mock_get_github_token "$dir"
  cd "$dir"  # not a git repo

  err_file=$(mktemp)
  trap "rm -f '$err_file'" EXIT

  if "$REPO_DIR/bin/gh-agent-scope" -- env >/dev/null 2>"$err_file"; then
    fail "expected non-zero exit"
  else
    grep -qi 'no --repo' "$err_file" \
      && ok "error mentions --repo" \
      || fail "stderr=[$(cat "$err_file")]"
  fi
)

echo "test: errors when origin is not a github.com remote"
(
  make_sandbox dir
  mock_get_github_token "$dir"

  repo_dir="$dir/clone"
  mkdir -p "$repo_dir"
  ( cd "$repo_dir" && git init -q && git remote add origin https://gitlab.com/foo/bar.git )

  err_file=$(mktemp)
  trap "rm -f '$err_file'" EXIT

  if ( cd "$repo_dir" && "$REPO_DIR/bin/gh-agent-scope" -- env ) >/dev/null 2>"$err_file"; then
    fail "expected non-zero exit"
  else
    grep -qi 'github.com' "$err_file" \
      && ok "error mentions github.com" \
      || fail "stderr=[$(cat "$err_file")]"
  fi
)

echo "test: errors on unknown flag"
(
  err_file=$(mktemp)
  trap "rm -f '$err_file'" EXIT

  if "$REPO_DIR/bin/gh-agent-scope" --bogus >/dev/null 2>"$err_file"; then
    fail "expected non-zero exit"
  else
    grep -qi 'unknown flag' "$err_file" \
      && ok "error mentions unknown flag" \
      || fail "stderr=[$(cat "$err_file")]"
  fi
)
```

- [ ] **Step 2: Run, verify the new tests PASS**

Run: `bash tests/run.sh`
Expected: 3 new ok lines pass.

- [ ] **Step 3: Commit**

```bash
git add tests/test_gh-agent-scope.sh
git commit -m "Test gh-agent-scope error paths: missing repo, non-github origin, bad flag"
```

---

## Task 10: install.sh — Darwin support

**Files:**
- Modify: `install.sh`
- Modify: `bin/get-github-token` install (add to the for-loop)
- Add: `bin/gh-agent-scope` install (add to the for-loop)

`install.sh` already exists; we extend it to:
- Always install `gh-agent-scope` and `get-github-token`.
- Skip Linux-only scripts (`gh-agent-unlock`, `gh-agent-lock`, `git-credential-github-app`) on macOS.
- Skip the global git credential-helper wiring on macOS (since the App helper isn't installed).

- [ ] **Step 1: Read current install.sh to see the exact for-loop**

```bash
cat install.sh | head -40
```

Expected: the install loop iterates `gh-agent-unlock gh-agent-lock get-github-token git-credential-github-app`. Confirm before editing.

- [ ] **Step 2: Modify the install loop**

Find this block in `install.sh`:

```bash
for script in gh-agent-unlock gh-agent-lock get-github-token git-credential-github-app; do
  install -m 0755 "$REPO_DIR/bin/$script" "$BIN_DIR/$script"
  echo "Installed $BIN_DIR/$script"
done
```

Replace with:

```bash
PORTABLE_SCRIPTS=(get-github-token gh-agent-scope)
LINUX_ONLY_SCRIPTS=(gh-agent-unlock gh-agent-lock git-credential-github-app)

for script in "${PORTABLE_SCRIPTS[@]}"; do
  install -m 0755 "$REPO_DIR/bin/$script" "$BIN_DIR/$script"
  echo "Installed $BIN_DIR/$script"
done

if [[ "$(uname)" == "Linux" ]]; then
  for script in "${LINUX_ONLY_SCRIPTS[@]}"; do
    install -m 0755 "$REPO_DIR/bin/$script" "$BIN_DIR/$script"
    echo "Installed $BIN_DIR/$script"
  done
else
  echo "Detected $(uname); skipping Linux-only scripts: ${LINUX_ONLY_SCRIPTS[*]}"
fi
```

- [ ] **Step 3: Wrap the git-credential-helper wiring in a Linux check**

Find the block in `install.sh` that runs `git config --global ... credential.https://github.com.helper ...`. Wrap the entire block in:

```bash
if [[ "$(uname)" == "Linux" ]]; then
  # ... existing git config commands ...
else
  echo "Skipping git credential-helper wiring on $(uname) (no persistent App helper installed)."
fi
```

To be specific, find:

```bash
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
```

Wrap that whole block:

```bash
if [[ "$(uname)" == "Linux" ]]; then
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
else
  echo "Skipping git credential-helper wiring on $(uname) (use gh-agent-scope instead)."
fi
```

- [ ] **Step 4: Smoke-test install.sh in a sandbox dir**

```bash
sandbox=$(mktemp -d)
BIN_DIR="$sandbox/bin" GH_AGENT_AUTH_CONFIG_DIR="$sandbox/config" bash install.sh
ls "$sandbox/bin/"
```

Expected on Linux: 5 scripts installed. Expected on macOS: 2 scripts (`get-github-token`, `gh-agent-scope`).

- [ ] **Step 5: Commit**

```bash
git add install.sh
git commit -m "install.sh: Darwin support — install only portable scripts on macOS

On Linux, install all 5 scripts and wire the global git credential-helper
chain. On non-Linux, install only get-github-token and gh-agent-scope and
skip the credential-helper wiring (the App helper depends on /dev/shm and
isn't shipped on macOS)."
```

---

## Task 11: README — usage docs and OS support matrix

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Read the current README**

```bash
cat README.md | head -60
```

Confirm the structure: it has Why, Prerequisites, Install, One-time setup, Daily usage, How the credential chain works, Security model, Configuration reference, License.

- [ ] **Step 2: Add a "For agent runs (everyone)" section after "Daily usage"**

Find the `## Daily usage` section. After its code block ends, but before the next `## How the credential chain works`, insert:

````markdown
## For agent runs (everyone, including macOS)

`gh-agent-scope` mints a token narrowed to specific repos and permissions,
then runs a command with that token in env. The token's lifetime equals
the command's lifetime — when the agent exits, the token is gone.

```bash
# Run an agent in cwd's repo, full installation perms
gh-agent-scope -- claude

# Read-only token for a test runner
gh-agent-scope --permissions contents=read,metadata=read -- pytest tests

# Multi-repo (must all be in the same App installation)
gh-agent-scope --repo myorg/foo --repo myorg/bar -- agent

# Print token (no subprocess) — for ad-hoc API calls
token=$(gh-agent-scope --repo owner/foo)
curl -H "Authorization: Bearer $token" https://api.github.com/repos/owner/foo
```

Inside the subprocess, both `git push` and `gh pr create` see only the
scoped token — the parent shell's auth state is unchanged. This is the
recommended pattern for autonomous coding agents: a misbehaving agent in
`~/projects/foo` can only touch `foo`, not `bar` or `baz`.

`gh-agent-scope` requires `git ≥ 2.31` (for `GIT_CONFIG_COUNT`-based
inline credential helper injection). macOS Sonoma ships 2.39, current
Linux distros are well past this.
````

- [ ] **Step 3: Add an OS support matrix section before "License"**

Find `## License` near the bottom. Just before it, insert:

````markdown
## Platform support

| Component | Linux | macOS | Notes |
|---|---|---|---|
| `gh-agent-scope` | ✓ | ✓ | Primary tool; works everywhere |
| `get-github-token` | ✓ | ✓ | Works everywhere |
| `gh-agent-unlock` / `gh-agent-lock` | ✓ | ✗ | Use `/dev/shm` for persistent key |
| `git-credential-github-app` | ✓ | ✗ | Reads from `/dev/shm` |

macOS users use `gh-agent-scope` for everything. Each invocation requires
one YubiKey touch — clean parallel to launching a Codespace.

Linux users get the same `gh-agent-scope` tool *plus* an optional
"unlock once, push all day" workflow via the persistent helper. The
two flows are independent and can be used together.

````

- [ ] **Step 4: Update the existing "Daily usage" section heading**

Change `## Daily usage` to `## Daily usage (Linux, optional)` to make the audience explicit.

- [ ] **Step 5: Visual check**

```bash
cat README.md | head -200
```

Confirm sections flow: Why → Prerequisites → Install → One-time setup → Daily usage (Linux, optional) → For agent runs → How the credential chain → Security → Configuration → Platform support → License.

- [ ] **Step 6: Commit**

```bash
git add README.md
git commit -m "README: document gh-agent-scope and add platform support matrix"
```

---

## Task 12: Manual integration test (no automation)

**Files:**
- Create: `docs/integration-test.md`

Automated tests cover flag parsing, body construction, env injection. Real
end-to-end signing requires a YubiKey and a configured App. This task
documents the manual smoke test for the developer (or anyone setting up
the repo for the first time).

- [ ] **Step 1: Create `docs/integration-test.md`**

```markdown
# Manual Integration Test

These steps verify the full path: YubiKey → age decrypt → JWT → GitHub →
scoped token → subprocess. Run them once after major changes.

**Prerequisites:**
- A configured `~/.config/gh-agent-auth/config` with `GITHUB_APP_ID`,
  `GITHUB_APP_ORG`, `GH_AGENT_AUTH_KEY_ENCRYPTED` set.
- The encrypted key file present.
- YubiKey plugged in.

## 1. Print-only mode, full installation scope

```bash
gh-agent-scope --repo $GITHUB_APP_ORG/gh-agent-auth
```

Expected: prints a `ghs_...` token to stdout, `expires_at: <iso>` to
stderr. One YubiKey touch.

## 2. Print-only mode, narrowed permissions

```bash
gh-agent-scope --repo $GITHUB_APP_ORG/gh-agent-auth --permissions contents=read
```

Expected: prints a token. Verify scope:

```bash
token=$(gh-agent-scope --repo $GITHUB_APP_ORG/gh-agent-auth --permissions contents=read 2>/dev/null)
curl -fsS -H "Authorization: Bearer $token" \
  https://api.github.com/installation/repositories \
  | jq '.repositories[].full_name'
```

Expected: only `<org>/gh-agent-auth` listed.

## 3. Subprocess mode

```bash
cd ~/Documents/github/$GITHUB_APP_ORG/gh-agent-auth
gh-agent-scope -- bash -c 'echo TOKEN_LEN=${#GITHUB_TOKEN}; gh api user'
```

Expected: prints `TOKEN_LEN=` followed by ~40, then `gh api user` returns
the App's bot account JSON.

## 4. Reject cross-org repo

```bash
gh-agent-scope --repo not-your-org/anything
```

Expected: exits non-zero with "is not in $GITHUB_APP_ORG" message.

## 5. Reject permission outside App's grant

```bash
gh-agent-scope --repo $GITHUB_APP_ORG/gh-agent-auth --permissions secrets=write
```

Expected: GitHub returns 422; error message surfaces verbatim.

## 6. Subprocess inherits exit code

```bash
gh-agent-scope --repo $GITHUB_APP_ORG/gh-agent-auth -- bash -c 'exit 7'
echo "Got: $?"
```

Expected: `Got: 7`.

## 7. macOS smoke test (group member)

Same steps 1-6 on a macOS machine. Confirm:
- `install.sh` skips Linux-only scripts.
- No `/dev/shm` references in any error output.
- One YubiKey touch per `gh-agent-scope` invocation (no persistent unlock
  on macOS — that's expected).
```

- [ ] **Step 2: Commit**

```bash
git add docs/integration-test.md
git commit -m "Add manual integration test checklist"
```

---

## Final verification

After all tasks complete:

- [ ] **Run the full test suite**

```bash
bash tests/run.sh
```

Expected: all green.

- [ ] **Visual review of changed scripts**

```bash
git diff main -- bin/ install.sh README.md
```

Spot-check that nothing user-specific or org-specific leaked in.

- [ ] **Push and open PR**

```bash
git push -u origin <feature-branch>
gh pr create --title "Add gh-agent-scope: Codespaces-style scoped tokens" \
  --body "Implements docs/superpowers/specs/2026-04-27-gh-agent-scope-design.md.

See docs/integration-test.md for manual smoke-test steps before merge."
```

- [ ] **Run the manual integration test before merging**

Follow `docs/integration-test.md`. Get a macOS smoke test from a group member.

---

## Self-review notes

Spec coverage check:

- §Command surface → Tasks 6, 7, 8 ✓
- §Implementation: token minting flags → Tasks 3, 4 ✓
- §Implementation: JWT signing two paths (fast path + cold-start via process substitution) → Task 5 ✓
- §Subprocess env (GITHUB_TOKEN, GH_TOKEN, GIT_CONFIG_COUNT chain) → Task 8 ✓
- §Repo detection (HTTPS and SSH origin URLs) → Task 6 ✓
- §Portability matrix (macOS install behavior) → Task 10 ✓
- §Error handling (old git, bad URLs, missing repo) → Task 9 ✓
- §Testing (automated + manual) → Tasks 1-9 (automated) + Task 12 (manual) ✓
- §Repo structure changes → all tasks ✓
- §Bash 3.2 compatibility → no bash-4-only features used in any code block in this plan ✓
- §git ≥ 2.31 requirement → enforced in Task 8 with version check ✓

Placeholder scan: no TBD/TODO/incomplete sections. All test code is concrete; all shell edits show the exact text to find and replace.

Type consistency:
- Variable names: `REPOS`, `PERMS`, `CMD`, `TOKEN`, `EXPIRY`, `gh_args`, `err_file`, `KEY_PATH`, `KEY_ENCRYPTED` — used consistently across tasks.
- Helper function names: `die`, `usage`, `make_sandbox`, `mock_openssl`, `mock_curl`, `mock_get_github_token`, `mock_env_for_get_token`, `mock_age`, `last_curl_body`, `ok`, `fail`, `report` — all defined in Task 1 / Task 5 helpers and used consistently in subsequent tasks.
- Env var names: `GITHUB_APP_ID`, `GITHUB_APP_ORG`, `GH_AGENT_AUTH_KEY_DECRYPTED`, `GH_AGENT_AUTH_KEY_ENCRYPTED`, `GH_AGENT_AUTH_CONFIG`, `GITHUB_TOKEN`, `GH_TOKEN` — match the spec's configuration reference.
