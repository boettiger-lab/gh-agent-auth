# gh-agent-auth

YubiKey-protected GitHub App credentials for git, gh, and coding agents —
on Linux and macOS.

A small set of bash scripts that let `git`, `gh`, and autonomous coding
agents authenticate as a GitHub App installation. The App's private key
sits encrypted at rest, gated by a hardware YubiKey. Two usage modes:

- **Ephemeral scoped tokens** (`gh-agent-scope`) — Codespaces-style. Mints
  a token narrowed to a specific repo and permission set, runs your
  command with it in env, token vanishes when the command exits. Works
  on Linux and macOS. The recommended default, especially for agents.
- **All-day unlock** (`gh-agent-unlock` + git credential helper) —
  Linux only. One YubiKey touch in the morning; `git push` and `gh`
  commands transparently authenticated as the App for the rest of the
  day. Optional power-user flow.

No personal access tokens. No long-lived secrets in shell history. No
credentials to rotate when a teammate leaves the org.

## Why GitHub Apps over PATs

Personal access tokens are bearer credentials with broad scope and
indefinite lifetime. GitHub Apps are a better primitive: per-installation,
fine-grained permissions, short-lived (1-hour) tokens, auditable as a
distinct actor. The historical friction was the App's *private key* — a
`.pem` that grants impersonation if leaked. This repo's pattern:

1. The `.pem` is encrypted at rest with [`age`](https://age-encryption.org/)
   plus [`age-plugin-yubikey`](https://github.com/str4d/age-plugin-yubikey),
   so decryption requires a physical YubiKey + PIN + touch.
2. Decryption is transient: either into RAM-backed `/dev/shm` (Linux
   all-day flow) or via process substitution into a single
   `openssl dgst` invocation (macOS / agent flow). The decrypted key
   never lands on disk.
3. Tokens are 1-hour installation tokens with the permissions and repo
   scope you ask for at mint time.

## Prerequisites

- `bash` (3.2+ — the macOS default works), `openssl`, `curl`, `jq`
- [`age`](https://age-encryption.org/) and
  [`age-plugin-yubikey`](https://github.com/str4d/age-plugin-yubikey)
- `git ≥ 2.31` (for `gh-agent-scope`'s subprocess credential injection;
  macOS Sonoma ships 2.39, current Linux distros are well past)
- `gh` CLI (optional — used as personal fallback in the all-day flow)
- A YubiKey 5 with a usable PIV applet
- A GitHub App you administer, installed on the user or org account whose
  repos you want to access

Linux and macOS are both supported. The all-day-unlock flow is
Linux-only; the scoped-token flow works everywhere.

## Install

```bash
git clone https://github.com/boettiger-lab/gh-agent-auth.git
cd gh-agent-auth
./install.sh
```

`install.sh` is OS-aware:

| | Linux | macOS |
|---|---|---|
| Installs `gh-agent-scope`, `get-github-token` | ✓ | ✓ |
| Installs `gh-agent-unlock`, `gh-agent-lock`, `git-credential-github-app` | ✓ | (skipped) |
| Wires the global git credential-helper chain for `github.com` | ✓ | (skipped) |
| Seeds `~/.config/gh-agent-auth/config` | ✓ | ✓ |

It's idempotent — safe to re-run.

## One-time setup

1. **Create or pick a GitHub App** with the permissions you want it to
   have (e.g. *Contents: Read & Write*, *Pull requests: Read & Write*,
   *Issues: Read & Write*). Install it on the user or org account whose
   repos it should reach. Note the App's numeric *App ID*.

2. **Provision a YubiKey age identity** (skip if you already have one):
   ```bash
   age-plugin-yubikey --generate
   # note the recipient (age1yubikey1...) it prints
   ```

3. **Encrypt the App's private key** to your YubiKey:
   ```bash
   age -r 'age1yubikey1...' \
       -o ~/.config/gh-agent-auth/key.pem.age \
       /path/to/downloaded-app-private-key.pem
   shred -u /path/to/downloaded-app-private-key.pem  # or rm -P on macOS
   ```

4. **Fill in the config file** (`~/.config/gh-agent-auth/config`):
   ```bash
   GITHUB_APP_ID=123456
   GITHUB_APP_ORG=your-org-or-username
   GH_AGENT_AUTH_KEY_ENCRYPTED="$HOME/.config/gh-agent-auth/key.pem.age"
   ```

5. **Verify the setup** by walking through
   [`docs/integration-test.md`](docs/integration-test.md). It's a short
   manual checklist that exercises every code path with your real
   YubiKey + App.

## Which flow do I use?

| If you... | Use |
|---|---|
| ...are on macOS | `gh-agent-scope` (only choice) |
| ...are launching an autonomous coding agent (anywhere) | `gh-agent-scope` |
| ...want a token for one specific operation, scoped to one repo | `gh-agent-scope` |
| ...are on Linux and want frictionless `git push` / `gh` all day from your shell | `gh-agent-unlock` + the credential helper |

Both flows can coexist on the same Linux machine. They don't conflict.

## Usage: scoped tokens with `gh-agent-scope`

Mints a token narrowed to specific repos and permissions, then either
prints it or `exec`s a subprocess with it in env. Token lifetime equals
subprocess lifetime — when the command exits, the token is gone.

```bash
# Run an agent in cwd's repo, full installation perms.
# (Auto-detects OWNER/REPO from the cwd's `origin` remote.)
gh-agent-scope -- claude

# Read-only token for a test runner.
gh-agent-scope --permissions contents=read,metadata=read -- pytest tests

# Multi-repo (must all be in the same App installation).
gh-agent-scope --repo myorg/foo --repo myorg/bar -- agent

# Print token to stdout instead of execing — for ad-hoc API calls.
token=$(gh-agent-scope --repo owner/foo)
curl -H "Authorization: Bearer $token" https://api.github.com/repos/owner/foo
```

Inside the subprocess, both `git push` and `gh pr create` see only the
scoped token — the parent shell's auth state is unchanged. This is the
recommended pattern for autonomous coding agents: a misbehaving agent
in `~/projects/foo` can only touch `foo`, not `bar` or `baz`.

Each `gh-agent-scope` invocation requires one YubiKey touch *unless* the
all-day-unlock key is already in `/dev/shm` from `gh-agent-unlock` — in
which case no touch is needed (silent fast path).

`gh-agent-scope --help` for the full flag reference.

## Usage: all-day unlock (Linux, optional)

```bash
gh-agent-unlock     # YubiKey PIN + touch — once per session
git push            # uses the App identity automatically
gh pr create        # same
gh-agent-lock       # wipe key + cached token from RAM
                    # (optional; auto-clears on reboot)
```

Behind the scenes, `gh-agent-unlock` decrypts the App key into
`/dev/shm/github-app-private-key.pem` (RAM-backed tmpfs). A git
credential helper consults that key on demand, mints a 1-hour
installation token, and caches it in `/dev/shm`. Both files clear on
reboot or via `gh-agent-lock`.

To mint a raw token for ad-hoc API calls (no scoping):

```bash
token=$(get-github-token)
curl -H "Authorization: Bearer $token" https://api.github.com/repos/your-org/your-repo
```

## Reference

### `gh-agent-scope`

```
Usage: gh-agent-scope [--repo OWNER/REPO]... [--permissions K=V,...] [-- COMMAND [ARGS...]]

  --repo OWNER/REPO       Scope to this repo. Repeatable.
                          Default: cwd's origin remote, if it's github.com.
  --permissions K=V,...   Narrow to a subset of the App's permissions
                          (e.g. contents=read,issues=write).
  -h, --help              Show this help.
```

With `-- COMMAND`: execs COMMAND with `GITHUB_TOKEN`, `GH_TOKEN`, and an
inline git credential helper in its env. Without `--`: prints token to
stdout, `expires_at: <iso>` to stderr.

### `get-github-token`

```
Usage: get-github-token [--repo OWNER/REPO]... [--permissions K=V,...]
```

Lower-level token minting. Without flags, mints a token with the App's
full installation scope. With `--repo`/`--permissions`, narrows. Prints
token to stdout, `expires_at: <iso>` to stderr in both executed and
sourced modes (sourced mode also exports `GITHUB_TOKEN`).

### Configuration variables

All scripts read `$GH_AGENT_AUTH_CONFIG` (default
`~/.config/gh-agent-auth/config`) at startup; environment variables
override anything in the file.

| Variable | Required | Default | Purpose |
|---|---|---|---|
| `GITHUB_APP_ID` | yes | — | Numeric App ID |
| `GITHUB_APP_ORG` | yes | — | Org or user where the App is installed |
| `GH_AGENT_AUTH_KEY_ENCRYPTED` | yes | — | Path to age-encrypted `.pem` |
| `GH_AGENT_AUTH_KEY_DECRYPTED` | no | `/dev/shm/github-app-private-key.pem` | Where the unlocked key lives (Linux all-day flow) |
| `GH_AGENT_AUTH_TOKEN_PATH` | no | `/dev/shm/github-app-token` | Where cached tokens live (Linux all-day flow) |
| `GH_AGENT_AUTH_EXPIRY_PATH` | no | `/dev/shm/github-app-token-expiry` | Cached token expiry (Linux all-day flow) |

## How it works

### Scoped tokens (`gh-agent-scope`)

1. Parse flags; resolve target repo from `--repo` or cwd's `origin`.
2. Call `get-github-token` with those flags. If the persistent key is
   already unlocked in `/dev/shm`, sign with it directly (no YubiKey
   touch). Otherwise, decrypt the encrypted key via `age` +
   `age-plugin-yubikey` through process substitution — the decrypted
   key is read once by `openssl dgst` from `/dev/fd/N` and never lands
   on disk. (One YubiKey touch.)
3. POST to `/app/installations/{id}/access_tokens` with the requested
   `repositories` and `permissions`. GitHub returns a clamped 1-hour
   token.
4. **Without `-- COMMAND`**: print token to stdout, expiry to stderr.
5. **With `-- COMMAND`**: `exec env ... COMMAND`. The injected env:
   - `GITHUB_TOKEN`, `GH_TOKEN` — the scoped token
   - `GIT_CONFIG_COUNT=2` plus a pair of `GIT_CONFIG_KEY_n` /
     `GIT_CONFIG_VALUE_n` entries that (a) clear any inherited
     credential helper for github.com and (b) install an inline helper
     reading `GITHUB_TOKEN` from env.

The clear-inherited-helper step is critical: without it, a parent shell
that has the all-day App helper enabled would intercept the subprocess's
git operations and silently mint a *full-permission* token, undoing the
scoping.

### All-day unlock (Linux)

`install.sh` configures git globally for `https://github.com`:

```
helper =                                      ← clear inherited helpers
helper = github-app                           ← this repo's App helper
helper = !gh auth git-credential              ← personal fallback
```

When `/dev/shm/github-app-private-key.pem` exists, the
`git-credential-github-app` helper mints a 1-hour token (caching it in
`/dev/shm/github-app-token`) and serves it to git. When the key is
absent (locked, or never unlocked), the helper exits silently and git
falls through to your personal `gh` auth. So the same machine handles
App-authenticated org work *and* personal-account work without
juggling tokens.

## Security model

**Key at rest** — encrypted with a YubiKey-bound age recipient. Loss
of the encrypted file is non-catastrophic; loss of the YubiKey + PIN
is. Anyone with both can mint App tokens.

**Key in use, scoped-tokens flow** — never on disk. Decrypted via
process substitution, read once by `openssl dgst` from `/dev/fd/N`,
gone when the signing pipe closes. The kernel pipe buffer is the only
memory holding plaintext, briefly.

**Key in use, all-day-unlock flow (Linux)** — lives in
`/dev/shm/github-app-private-key.pem` (tmpfs, RAM-backed, mode 0600)
for the session. Cleared on reboot or via `gh-agent-lock`. Other
processes on the machine running as your UID can read it; treat
unlock as roughly equivalent to "I'm signed in for the day."

**Tokens** — 1-hour GitHub installation tokens. The all-day flow
caches them in `/dev/shm`; the scoped flow keeps them only in the
subprocess's env (and exits with the subprocess).

**Scope** — limited to the App's installed permissions and target
repos. With `gh-agent-scope --permissions ...`, narrowable further:
GitHub clamps the request to the intersection with the App's grant
and returns 422 on requests outside it.

## Troubleshooting

**`ERROR: GITHUB_APP_ID is not set`** — Edit `~/.config/gh-agent-auth/config`
or export `GITHUB_APP_ID` in your shell. The App ID is a number, visible
on the App's settings page on GitHub.

**`No installation found for '<org>'`** — The App isn't installed on
that account, or `GITHUB_APP_ORG` is misspelled. Check
`https://github.com/organizations/<org>/settings/installations` (org)
or `https://github.com/settings/installations` (user).

**`No private key available`** — Either the persistent key isn't
unlocked yet (run `gh-agent-unlock`) or `GH_AGENT_AUTH_KEY_ENCRYPTED`
isn't set / points at a missing file. The error message tells you both
recovery paths.

**`age: Touch your YubiKey...` hangs** — Tap the YubiKey. If nothing
happens, check `age-plugin-yubikey --list` to confirm the device is
visible.

**`repo X/Y is not in <org>`** — `gh-agent-scope` only lets you scope
to repos owned by `$GITHUB_APP_ORG`. If you need a different org,
either install the App there or use a separate config file
(`GH_AGENT_AUTH_CONFIG=path/to/other-config gh-agent-scope ...`).

**`repo 'foo' must be in OWNER/REPO form`** — Bare repo names are
rejected for clarity. Pass `--repo OWNER/foo` or `cd` into a clone of
the repo and let auto-detect from `origin` handle it.

**`git $version is too old; need git ≥ 2.31`** — `gh-agent-scope`'s
subprocess mode uses `GIT_CONFIG_COUNT`-based credential injection
which requires git 2.31+. Upgrade git, or use the print-token mode
(`token=$(gh-agent-scope ...)`) which has no git dependency.

**GitHub returns 422 from a `--permissions` request** — You asked for
a permission key not in the App's installation grant. The error body
from GitHub is surfaced verbatim; check the App's permissions page on
GitHub, or drop the offending key.

**`gh-agent-scope` is silent on Linux but takes a YubiKey touch on
macOS** — Expected. Linux can use the unlocked persistent key as a
fast path; macOS doesn't have `/dev/shm`, so every invocation does its
own decrypt. To avoid the touch on Linux too, run `gh-agent-unlock`
first.

## Platform support

| Component | Linux | macOS | Notes |
|---|---|---|---|
| `gh-agent-scope` | ✓ | ✓ | Primary tool; works everywhere |
| `get-github-token` | ✓ | ✓ | Works everywhere |
| `gh-agent-unlock` / `gh-agent-lock` | ✓ | ✗ | Use `/dev/shm` for the persistent key |
| `git-credential-github-app` | ✓ | ✗ | Reads from `/dev/shm` |

## Project layout

```
bin/
  gh-agent-scope             primary tool (cross-platform)
  get-github-token           lower-level token minting
  gh-agent-unlock            unlock persistent key (Linux all-day flow)
  gh-agent-lock              wipe persistent key (Linux all-day flow)
  git-credential-github-app  git credential helper (Linux all-day flow)
install.sh                   OS-aware installer
tests/                       19 bash tests; run with bash tests/run.sh
docs/
  integration-test.md        manual smoke-test checklist
  superpowers/specs/         design spec
  superpowers/plans/         implementation plan
```

## License

MIT — see [LICENSE](LICENSE).
