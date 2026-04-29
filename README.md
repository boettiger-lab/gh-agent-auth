# gh-agent-auth

YubiKey-protected GitHub App credentials for shared dev machines and coding agents.

A small set of bash scripts that let `git` and `gh` authenticate as a GitHub App
installation — with the App's private key encrypted to a hardware YubiKey at
rest, decrypted into RAM (`/dev/shm`) for the duration of a session, and never
written to disk. No personal access tokens, no long-lived secrets in your
shell history, no credentials to rotate when a teammate leaves.

## Why

Personal access tokens are bearer credentials with broad scope and indefinite
lifetime. GitHub Apps are a better primitive: per-installation, fine-grained
permissions, short-lived (1 hour) tokens, auditable as a distinct actor.

The friction has always been the App's *private key* — a `.pem` file that, if
leaked, lets anyone impersonate the App. This repo's pattern:

1. The `.pem` is encrypted at rest with [`age`](https://age-encryption.org/) +
   [`age-plugin-yubikey`](https://github.com/str4d/age-plugin-yubikey),
   so decryption requires a physical YubiKey, PIN, and touch.
2. `gh-agent-unlock` decrypts it into `/dev/shm` (tmpfs — never hits disk).
3. A git credential helper consults the unlocked key only when present, mints a
   1-hour installation token on demand, and caches it in `/dev/shm`.
4. `gh-agent-lock` wipes the key and any cached token from RAM.

The result: a session is gated on a YubiKey touch; everything in between is
transparent. `git push`, `gh pr create`, `curl api.github.com` all just work,
authenticated as the App.

## Prerequisites

- `bash`, `openssl`, `curl`, `jq`
- `age` and `age-plugin-yubikey`
- `gh` CLI (optional but recommended — used as personal fallback)
- A YubiKey 5 (firmware ≥ 5.2.3, with the PIV applet usable)
- A GitHub App you administer, installed on the org or user account whose
  repos you want to access

Linux is the primary target. macOS works if you replace `/dev/shm` with a
tmpfs path (configurable; see below).

## Install

```bash
git clone https://github.com/boettiger-lab/gh-agent-auth.git
cd gh-agent-auth
./install.sh
```

`install.sh` copies the four scripts into `~/.local/bin/`, seeds a config file
at `~/.config/gh-agent-auth/config`, and wires the global git credential
helper chain for `github.com`.

## One-time setup

1. **Create or pick a GitHub App** with the permissions you want it to have
   (e.g. *Contents: Read & Write*, *Pull requests: Read & Write*, *Issues:
   Read & Write*). Install it on the org or user account whose repos it
   should reach.

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
   shred -u /path/to/downloaded-app-private-key.pem
   ```

4. **Fill in the config file** (`~/.config/gh-agent-auth/config`):
   ```bash
   GITHUB_APP_ID=123456
   GITHUB_APP_ORG=your-org-or-username
   GH_AGENT_AUTH_KEY_ENCRYPTED="$HOME/.config/gh-agent-auth/key.pem.age"
   ```

## Daily usage (Linux, optional)

```bash
gh-agent-unlock     # YubiKey PIN + touch — once per session
git push            # uses the App identity automatically
gh pr create        # same
gh-agent-lock       # wipe key and cached token from RAM (optional; auto-clears on reboot)
```

To mint a raw token for ad-hoc API calls:

```bash
token=$(get-github-token)
curl -H "Authorization: Bearer $token" https://api.github.com/repos/your-org/your-repo
```

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

## How the credential chain works

`install.sh` configures git with this chain for `https://github.com`:

```
helper =                                    # clear any inherited helpers
helper = github-app                         # this repo's App helper
helper = !gh auth git-credential            # personal fallback
```

When the key is unlocked (`/dev/shm/github-app-private-key.pem` exists), the
App helper mints/serves a token. When the key is locked, the App helper exits
with no output and git falls through to your personal `gh` auth.

This means the same machine can do App-authenticated work on org repos *and*
personal-account work without juggling tokens.

## Security model

- **Key at rest**: encrypted with a YubiKey-bound age recipient. Loss of the
  encrypted file is non-catastrophic; loss of the YubiKey + PIN is.
- **Key in use**: lives in `/dev/shm` (tmpfs, RAM-backed, mode 0600). Never
  written to disk. Cleared on reboot or via `gh-agent-lock`.
- **Tokens**: 1-hour installation tokens, also in `/dev/shm`, refreshed on
  expiry by the credential helper.
- **Scope**: limited to the App's installed permissions and target repos —
  not your full personal account.

## Configuration reference

All scripts read `$GH_AGENT_AUTH_CONFIG` (default
`~/.config/gh-agent-auth/config`) and let environment variables override.

| Variable | Required | Default | Purpose |
|---|---|---|---|
| `GITHUB_APP_ID` | yes | — | Numeric App ID |
| `GITHUB_APP_ORG` | yes | — | Org or user account where the App is installed |
| `GH_AGENT_AUTH_KEY_ENCRYPTED` | yes | — | Path to age-encrypted `.pem` |
| `GH_AGENT_AUTH_KEY_DECRYPTED` | no | `/dev/shm/github-app-private-key.pem` | Where the unlocked key lives |
| `GH_AGENT_AUTH_TOKEN_PATH` | no | `/dev/shm/github-app-token` | Where cached tokens live |
| `GH_AGENT_AUTH_EXPIRY_PATH` | no | `/dev/shm/github-app-token-expiry` | Cached token expiry |

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

## License

MIT — see [LICENSE](LICENSE).
