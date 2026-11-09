# tools.klar.ws

Install scripts and release binaries for klar-web-services tools, for example:

```sh
curl -fsSL https://tools.klar.ws/bbs/install.sh | sh
```

```powershell
irm https://tools.klar.ws/bbs/install.ps1 | iex
```

This repository contains the GitHub Action that klar-web-services projects publish
their releases with, the installers it generates, and the read-only proxy that serves
them.

## Installers

The generated installers check the release's SHA-256 checksums before installing
anything. These environment variables change what they do (`<TOOL>` is the tool name in
upper case, with dashes as underscores, e.g. `BBS_VERSION`):

| Variable | Default |
|---|---|
| `<TOOL>_VERSION` | the latest release |
| `<TOOL>_INSTALL_DIR` | `~/.local/bin`, on Windows `%LOCALAPPDATA%\Programs\<tool>` |
| `<TOOL>_BASE_URL` | `https://tools.klar.ws/<tool>` |

## Publishing

For klar-web-services repositories; it needs the organization's credentials. Add this
to the release workflow once the archives (`<tool>-<target>.tar.gz`, on Windows `.zip`)
exist. The inputs are documented in [`publish/action.yml`](publish/action.yml).

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

## Testing

```sh
test/e2e.sh
```

Runs the proxy and a local S3 stand-in in Docker, then publishes, installs, rolls back,
retires and purges a fake tool.
