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
