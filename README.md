# tools.klar.ws

Install scripts and release binaries for klar tools, e.g.

```sh
curl -fsSL https://tools.klar.ws/bbs/install.sh | sh
```

```powershell
irm https://tools.klar.ws/bbs/install.ps1 | iex
```

Everything lives in a Hetzner Object Storage bucket. Dokploy runs a stateless nginx
that serves the bucket at `https://tools.klar.ws/`. Projects publish from their own
CI with the action in this repo; nothing on the server changes when a tool is added.

```
curl / irm ─▶ tools.klar.ws ─▶ Traefik ─▶ nginx (Dokploy, no volume) ─▶ bucket (fsn1)
GitHub Actions (any repo) ───────── S3 upload ───────────────────────▶ same bucket
```

## URL layout

| Path | Changes | Client cache |
|---|---|---|
| `/<tool>/install.sh`, `install.ps1`, other scripts | every publish | 5 min |
| `/<tool>/` (landing page) | every publish | 5 min |
| `/<tool>/latest` (e.g. `1.2.3`) | every stable release | 5 min |
| `/<tool>/v<version>/<file>`, `checksums.txt` | never | 1 year |
| `/` (list of tools) | every publish/retire | 5 min |

## Adding a tool

There is no registration. The first publish creates `tools.klar.ws/<tool>/`.

1. Build release archives named `<tool>-<target>.tar.gz` (Windows: `.zip`) with the
   binary inside, where `<target>` is a Rust-style triple such as
   `x86_64-unknown-linux-gnu`, `aarch64-apple-darwin` or `x86_64-pc-windows-msvc`.
2. Add the publish step to the release workflow, after the archives and
   `checksums.txt` exist:

   ```yaml
   - uses: klar-web-services/tools.klar.ws/publish@v1
     with:
       tool: mytool
       version: ${{ github.ref_name }}
       files: dist/*
       description: One line about mytool.
       bucket: ${{ secrets.TOOLS_S3_BUCKET }}
       access-key-id: ${{ secrets.TOOLS_S3_ACCESS_KEY }}
       secret-access-key: ${{ secrets.TOOLS_S3_SECRET_KEY }}
   ```

3. Give the repository access to the three `TOOLS_S3_*` org secrets
   (org settings → Secrets and variables → Actions → each secret → Repository access).
4. Tag a release.

A tool that already has GitHub releases can be copied over once with the `import`
command (see [Managing tools](#managing-tools)).

Without `scripts:`, the action generates `install.sh`, `install.ps1` and `index.html`
from [`templates/`](templates/). They verify checksums, install to `~/.local/bin` or
`%LOCALAPPDATA%\Programs\<tool>`, and honour `<TOOL>_VERSION`, `<TOOL>_INSTALL_DIR`
and `<TOOL>_BASE_URL` (e.g. `BBS_VERSION=0.6.0`).

Tools with other archive layouts, or extra scripts, bring their own: `scripts: scripts/`
publishes every top-level file of that directory as `/<tool>/<name>`. A script-only tool
(a setup script, no binaries) passes only `scripts:`.

### Action inputs

| Input | Default | |
|---|---|---|
| `tool` | required | URL path, lowercase letters, digits, dashes |
| `version` | | Tag or version; required with `files`. A leading `v` is dropped. |
| `files` | | Paths or globs, one per line |
| `scripts` | | Directory of scripts to publish instead of the generated ones |
| `binary` | tool name | Binary inside the archives, for the generated installers |
| `description` | | Landing page text |
| `repo-url` | this repository | Landing page source link |
| `latest` | `auto` | `auto` moves `latest` unless the version has a `-` (pre-release); `always`; `never` |
| `bucket`, `access-key-id`, `secret-access-key` | required | Org secrets `TOOLS_S3_BUCKET`, `TOOLS_S3_ACCESS_KEY`, `TOOLS_S3_SECRET_KEY` |

### Publishing rules

- A version is complete once its `checksums.txt` is uploaded, which happens last.
- A published version is never overwritten. Re-running an identical publish is a
  no-op, so failed workflows can simply be re-run; different files are refused.
- If the project ships a `checksums.txt`, it must list every uploaded file with the
  right hash; it is uploaded as-is so it matches the GitHub release byte for byte.
- `latest` moves only after the files and scripts are uploaded.

## Managing tools

Use **Actions → Manage a tool → Run workflow** in this repository, or run
`bin/toolsctl` locally with `TOOLS_S3_BUCKET`, `TOOLS_S3_ACCESS_KEY` and
`TOOLS_S3_SECRET_KEY` set (needs the AWS CLI).

| Command | Effect |
|---|---|
| `status [--tool T]` | Tools, state, versions |
| `import` (workflow only: tool, repo, version) | Copy an existing GitHub release into the bucket, with generated installers |
| `set-latest --tool T --version V` | Roll `latest` back or forward to a published version |
| `retire --tool T --message TEXT` | Retire a tool (below) |
| `purge --tool T --yes` | Delete all release files of a retired tool |
| `unretire --tool T` | Allow publishing again; the next publish restores the scripts |
| `apply-policy` | Allow anonymous downloads of objects (no listing); run once per bucket |

### Retiring a tool

`retire`:

1. writes `/<tool>/RETIRED`; from then on every publish of that tool is refused,
   so a stray tag push cannot bring it back;
2. replaces every top-level `.sh`/`.ps1` with a notice that prints the message and
   exits with an error (`throw` in PowerShell, so `irm | iex` does not close the
   window), and the landing page with the same notice;
3. deletes `latest` and removes the tool from the root page.

Release files stay downloadable, so anything pinned to a direct URL keeps working
while people move off. After a grace period, `purge` deletes them. The notices and
the tombstone stay for good: old install commands keep explaining what happened,
and the name stays taken.

Why notices instead of deleting the scripts: `curl -f` turns a 404 into an empty pipe,
so users would only see `curl: (22)`. A notice served normally is the only way the
explanation reaches them.

**Emergency (compromised release):** `retire`, then `purge --yes`, then restart the
`tools` service in Dokploy. nginx re-checks objects every minute anyway; the restart
empties its cache immediately.

## The proxy

[`nginx/default.conf.template`](nginx/default.conf.template), deployed by
[`docker-compose.yml`](docker-compose.yml):

- forwards only `GET`/`HEAD`, without query strings or client credentials;
- serves `/<tool>/` as `index.html` and maps the bucket's 403 for missing keys to 404;
- replaces every error from the bucket with a plain 404 or 503 and hides S3 headers,
  so responses never reveal the bucket name;
- sets cache headers by path (table above);
- keeps a small cache on a tmpfs: objects are re-checked after `S3_CACHE_VALID` (1m),
  and served stale for up to 7 days if the bucket is down (after a 5 s connect timeout).

## One-time setup

The bucket name is kept out of this repository: it lives in the org secret
`TOOLS_S3_BUCKET` (masked in the public Actions logs) and in Dokploy's environment.

1. **Hetzner:** a private bucket in Falkenstein (`fsn1`, same location as the Dokploy
   host) and an S3 key pair. S3 keys can reach every bucket in their Hetzner project,
   so keep any other bucket (backups, for example) in a different project.
2. **GitHub:** org secrets `TOOLS_S3_BUCKET`, `TOOLS_S3_ACCESS_KEY` and
   `TOOLS_S3_SECRET_KEY`, with repository access for this repository and each tool
   repository. On the Free plan, org secrets reach public repositories only.
3. **Public read:** run the `apply-policy` command once. It allows anonymous
   `GetObject` only. Check: an object URL loads, the bucket URL returns `AccessDenied`.
4. Tag this repository `v1` so `publish@v1` resolves.
5. **Dokploy:** point the `tools` compose service at this repository, set
   `S3_ORIGIN=https://<bucket>.fsn1.your-objectstorage.com` in its environment, and
   route the domain `tools.klar.ws`, path `/`, to service `proxy`, port 80.

## Testing

```sh
test/e2e.sh
```

Starts RustFS (standing in for the bucket) and the real nginx config in Docker, then
publishes, installs (with `curl | sh` and `irm | iex`), rolls back, retires, purges and
unretires a fake tool. Needs Docker, the AWS CLI, curl and python3; uses PowerShell and
shellcheck from containers if they aren't installed. Ports: `E2E_PROXY_PORT` (38080),
`E2E_S3_PORT` (39000). `KEEP=1` leaves the containers running.
