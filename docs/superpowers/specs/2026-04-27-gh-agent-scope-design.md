# gh-agent-scope — Codespaces-style Scoped Tokens

**Status:** approved design, ready for implementation plan
**Date:** 2026-04-27

## Motivation

The current `gh-agent-auth` tools mint installation tokens with the App's
*full* permissions across *all* repos in the installation. That's fine for an
interactive human who knows what they're doing, but it's the wrong default
for autonomous coding agents:

- **Blast radius.** A misbehaving agent in `~/projects/foo` can push to
  `bar`, `baz`, or any other repo the App is installed on.
- **Lifetime.** Tokens persist for an hour after the agent exits, sitting in
  `/dev/shm` until expiry or explicit lock.
- **Permission scope.** Even when the agent only needs to read code and open
  an issue, it gets full read/write across the App's permission set.

GitHub Codespaces solves this elegantly: each codespace gets a token scoped
to its single source repo, with permissions narrower than the App's full
grant, alive for the codespace's lifetime, gone afterwards.

This design ports that pattern to local agent runs.

## Non-goals

- **Token refresh.** GitHub installation tokens are 1-hour, hard limit. We do
  not implement refresh. Long-running agents must be restarted.
- **Replacing the unlock/credential-helper flow.** That stays for interactive
  Linux users who want frictionless `git push` all day. The new tool is
  additive (Path Y of the brainstorming alternatives).
- **Daemon-style token caching.** No background process. Each invocation is
  self-contained.

## Command surface

```
gh-agent-scope [--repo OWNER/REPO]... [--permissions key=level,...] [-- COMMAND [ARGS...]]
```

| Flag | Repeatable | Default | Purpose |
|---|---|---|---|
| `--repo OWNER/REPO` | yes | cwd's `origin` remote (parsed for `github.com/OWNER/REPO`) | Repos the token is scoped to |
| `--permissions key=level,...` | no | App installation's full permissions | Permission narrowing (subset of installation grant) |
| `--` then `COMMAND ARGS...` | n/a | none | Subprocess to exec with token in env |

Behavior depends on whether `-- COMMAND` is given:

- **With `--`**: exec the subprocess with `GITHUB_TOKEN`, `GH_TOKEN`, and an
  inline git credential-helper config in its environment. The original
  process is replaced via `exec`.
- **Without `--`**: print the token to stdout, expiry to stderr. Used as a
  shell building block: `token=$(gh-agent-scope --repo owner/foo)`.

If the cwd is not a git repo and `--repo` is not given, error with a
message pointing at both fixes.

If `--permissions` is supplied but a key isn't in the App's installation
permissions, GitHub will reject the token request (HTTP 422). Surface that
error verbatim — don't try to pre-validate.

### Examples

```bash
# Run an agent in cwd's repo, full installation perms
gh-agent-scope -- claude

# Read-only token for a test runner
gh-agent-scope --permissions contents=read,metadata=read -- pytest tests

# Multi-repo (must all be in the same installation)
gh-agent-scope --repo myorg/foo --repo myorg/bar -- agent

# Print token (no subprocess) — for ad-hoc API calls
token=$(gh-agent-scope --repo owner/foo)
curl -H "Authorization: Bearer $token" https://api.github.com/repos/owner/foo
```

## Implementation

### Token minting (extends existing `bin/get-github-token`)

The existing `get-github-token` script mints an installation token. Two new
flags extend it:

| Flag | Repeatable | Effect |
|---|---|---|
| `--repo OWNER/REPO` | yes | Adds to `repositories[]` in the access_tokens POST body |
| `--permissions key=level,...` | no | Parsed into `permissions{}` in the POST body |

Both are optional; with neither, behavior is unchanged (full installation
token, current behavior preserved). The credential helper in
`bin/git-credential-github-app` continues to call `get-github-token` with no
flags and gets the same full-scope token it does today.

One small behavior change to `get-github-token` is required: when *executed*
(not sourced), it currently prints the token to stdout and nothing else.
We extend it to also print `expires_at` to stderr in both modes, so callers
like `gh-agent-scope` can capture the expiry without parsing the token.

The POST body:
```json
{
  "repositories": ["foo", "bar"],
  "permissions": {"contents": "write", "metadata": "read"}
}
```

`repositories` takes bare repo names (not `OWNER/REPO`) — they must all
belong to the installation owner. We strip the owner prefix and validate it
matches `$GITHUB_APP_ORG`.

### JWT signing — two paths for the private key

**Linux fast path.** If `$GH_AGENT_AUTH_KEY_DECRYPTED` (default
`/dev/shm/github-app-private-key.pem`) exists from a prior `gh-agent-unlock`,
use it directly:

```bash
openssl dgst -sha256 -sign "$KEY_DECRYPTED"
```

No YubiKey touch needed.

**Cold start / macOS.** Use process substitution so the decrypted key never
hits disk:

```bash
openssl dgst -sha256 -sign \
  <(age --decrypt -i <(age-plugin-yubikey --identity) "$KEY_ENCRYPTED")
```

This costs one YubiKey touch per `gh-agent-scope` invocation. Acceptable for
agent launches (one touch per agent run, like Codespaces requires one auth
event per codespace creation).

Process substitution gives openssl a `/dev/fd/N` path for a one-pass FIFO.
openssl reads the key once during signing — no seeking needed. Verified
working on bash 3.2 (macOS default) and bash 5.x (Linux).

### Subprocess wrapper (`bin/gh-agent-scope`)

Pseudocode (real script will be careful with arg arrays — pseudocode glosses
over array-vs-string detail):

```bash
parse_flags                                    # --repo (repeatable), --permissions, --
[[ ${#repos[@]} -eq 0 ]] && repos+=("$(detect_repo_from_cwd)")

# Build a flat arg list: --repo a --repo b ...
gh_args=()
for r in "${repos[@]}"; do gh_args+=(--repo "$r"); done
[[ -n "$perms" ]] && gh_args+=(--permissions "$perms")

# get-github-token prints the token on stdout, "expires_at: <iso>" on stderr.
# Capture both:
exec 3>&1
expiry_line=$(get-github-token "${gh_args[@]}" 2>&1 >&3) || exit
exec 3>&-
token=...                                      # captured from stdout via process substitution
expiry=${expiry_line#expires_at: }

if [[ ${#cmd[@]} -eq 0 ]]; then
  echo "$token"
  echo "expires_at: $expiry" >&2
  exit 0
fi

git_cred_helper='!f(){echo username=x-access-token;echo "password=$GITHUB_TOKEN";};f'
exec env \
  GITHUB_TOKEN="$token" \
  GH_TOKEN="$token" \
  GIT_CONFIG_COUNT=2 \
  GIT_CONFIG_KEY_0='credential.https://github.com.helper' \
  GIT_CONFIG_VALUE_0='' \
  GIT_CONFIG_KEY_1='credential.https://github.com.helper' \
  GIT_CONFIG_VALUE_1="$git_cred_helper" \
  -- "$@"
```

**Why the empty `helper=''` first.** Git's credential-helper config is a
list. Without clearing inherited helpers, the parent shell's
`git-credential-github-app` helper (when the persistent key is unlocked)
would intercept first and mint a *full-permission* token, silently undoing
the scoping. The empty helper resets the chain.

**Why `GIT_CONFIG_COUNT` instead of writing a tmpfile config.** Inheritable
through the subprocess tree without on-disk artifacts to clean up; works
identically on Linux and macOS; standard since git 2.31 (2021-03).

**Why both `GITHUB_TOKEN` and `GH_TOKEN`.** `gh` CLI prefers `GH_TOKEN` and
warns when only `GITHUB_TOKEN` is set; the inline git credential helper reads
`GITHUB_TOKEN`. Set both to the same value.

### Repo detection from cwd

```bash
url=$(git -C "$PWD" remote get-url origin 2>/dev/null) || die "..."
case "$url" in
  https://github.com/*/*) repo=${url#https://github.com/}; repo=${repo%.git} ;;
  git@github.com:*/*)     repo=${url#git@github.com:};      repo=${repo%.git} ;;
  *) die "origin is not a github.com remote: $url" ;;
esac
```

## Portability matrix

| Component | Linux | macOS | Reason |
|---|---|---|---|
| `gh-agent-scope` | ✓ | ✓ | No `/dev/shm` dependency |
| `get-github-token` | ✓ | ✓ | Process-substitution path covers macOS |
| `gh-agent-unlock` | ✓ | ✗ | Uses `/dev/shm` for persistent key |
| `gh-agent-lock` | ✓ | ✗ | Wipes `/dev/shm` files |
| `git-credential-github-app` | ✓ | ✗ | Reads from `/dev/shm` |

macOS users use only `gh-agent-scope` (and indirectly `get-github-token`).
Linux users get both the scope tool and the optional all-day-unlock flow.

### macOS install behavior

`install.sh` detects Darwin via `uname` and:

- Installs `bin/gh-agent-scope` and `bin/get-github-token` to `~/.local/bin`.
- Skips installing `gh-agent-unlock`, `gh-agent-lock`, and
  `git-credential-github-app`.
- Skips wiring the global git credential-helper chain (since the App helper
  isn't installed).
- Seeds `~/.config/gh-agent-auth/config` the same way.

### Bash compatibility

All scripts use `#!/usr/bin/env bash` and avoid bash-4-only features
(associative arrays, `${var,,}`, `printf '%(...)T'`). Verified compatible
with bash 3.2 (macOS default).

### git version requirement

`GIT_CONFIG_COUNT` requires git ≥ 2.31 (March 2021). macOS Sonoma ships
2.39. Linux distros are well past this. Document the requirement in README;
fail the subprocess wrapper with a clear error if `git --version` reports
older.

## Error handling

| Scenario | Behavior |
|---|---|
| No `--repo` and cwd not a git repo | Exit 1 with message: "no --repo given; cwd is not a git repo. Pass --repo OWNER/REPO." |
| Cwd's `origin` not a github.com URL | Exit 1 with the URL and a hint to pass `--repo` explicitly. |
| `--repo` from a different org than `$GITHUB_APP_ORG` | Exit 1 with message identifying the mismatch. |
| Permission key not in App's installation grant | GitHub returns 422; surface stderr verbatim. |
| YubiKey not present / age decrypt fails | `age` writes to stderr; we exit non-zero. |
| Subprocess exits non-zero | `gh-agent-scope` exits with same code (via `exec`). |
| `git --version` < 2.31 in subprocess wrapper mode | Exit 1 with the version found and a link to upgrade docs. |

## Testing

A pragmatic test plan, given that real signing requires a YubiKey:

1. **Unit-style** (no real key): mock `get-github-token` with a stub that
   echoes a fake token. Exercise `gh-agent-scope`'s flag parsing, repo
   detection, and env construction. Assert the right `env` invocation. This
   catches the bulk of the wrapper logic.

2. **Integration** (with a YubiKey, manual): run
   `gh-agent-scope --repo boettiger-lab/gh-agent-auth -- bash -c 'gh api user'`
   and confirm it works. Run with a wrong repo and confirm GitHub's 422 is
   surfaced cleanly.

3. **Cross-platform**: smoke-test on macOS (a group member) before
   announcing.

## Repo structure changes

```
bin/
  gh-agent-unlock              [unchanged, Linux-only]
  gh-agent-lock                [unchanged, Linux-only]
  get-github-token             [extended: --repo, --permissions flags]
  git-credential-github-app    [unchanged, Linux-only]
  gh-agent-scope               [NEW: ~50-80 LOC]
install.sh                     [updated: Darwin detection]
README.md                      [updated: agent-run section, OS support matrix]
LICENSE                        [unchanged]
.gitignore                     [unchanged]
docs/superpowers/specs/2026-04-27-gh-agent-scope-design.md  [this file]
```

## Open questions deferred to later

- **Homebrew formula.** A `boettiger-lab/tap/gh-agent-auth` formula would
  smooth macOS install. Out of scope for first cut; revisit if group adoption
  takes off.
- **Permission profiles.** A YAML/JSON file of named permission sets
  (`--profile readonly`, `--profile codegen`) would be ergonomic. Defer until
  we have ≥3 distinct permission profiles in use.
- **Multi-installation support.** Currently we assume one `GITHUB_APP_ORG`
  per config. Supporting a single user across multiple installations would
  require an `--installation` flag. Defer until requested.
