#!/usr/bin/env bash
# End-to-end test: local S3 (RustFS) + the production nginx config + toolsctl +
# the generated installers, covering publish, rollback, retire, purge, unretire.
# Needs docker, aws, curl, python3. Set KEEP=1 to leave the containers running.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
COMPOSE=(docker compose -f test/compose.yml)
export E2E_PROXY_PORT=${E2E_PROXY_PORT:-38080} E2E_S3_PORT=${E2E_S3_PORT:-39000}
PROXY=http://127.0.0.1:$E2E_PROXY_PORT
PWSH_IMAGE=mcr.microsoft.com/powershell:latest

export TOOLS_S3_ENDPOINT=http://127.0.0.1:$E2E_S3_PORT TOOLS_S3_BUCKET=tools-test TOOLS_S3_REGION=us-east-1
export TOOLS_S3_ACCESS_KEY=e2e-access TOOLS_S3_SECRET_KEY=e2e-secret-key
export AWS_ACCESS_KEY_ID=$TOOLS_S3_ACCESS_KEY AWS_SECRET_ACCESS_KEY=$TOOLS_S3_SECRET_KEY AWS_DEFAULT_REGION=us-east-1
export TOOLS_PUBLIC_URL=$PROXY

work=$(mktemp -d)
cleanup() {
	if [ -z "${KEEP:-}" ]; then "${COMPOSE[@]}" down -v >/dev/null 2>&1 || true; fi
	rm -rf "$work"
}
trap cleanup EXIT

passed=0
step() { printf '\n== %s\n' "$*"; }
ok() { passed=$((passed + 1)); printf '  ok   %s\n' "$*"; }
fail() { printf '  FAIL %s\n' "$*" >&2; exit 1; }
toolsctl() { "$ROOT/bin/toolsctl" "$@"; }
status_code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
header() { curl -s -D - -o /dev/null "$1" | tr -d '\r' | awk -v h="$2" -F': ' 'tolower($1) == tolower(h) { print $2 }'; }
expect_eq() { if [ "$1" = "$2" ]; then ok "$3"; else fail "$3: expected '$2', got '$1'"; fi; }
expect_has() { case $1 in *"$2"*) ok "$3" ;; *) fail "$3: '$2' not found in: $1" ;; esac; }
expect_lacks() { case $1 in *"$2"*) fail "$3: unexpected '$2'" ;; *) ok "$3" ;; esac; }
expect_fail() { # expect_fail DESCRIPTION EXPECTED_TEXT CMD...
	local desc=$1 text=$2 out
	shift 2
	if out=$("$@" 2>&1); then fail "$desc: command succeeded"; fi
	expect_has "$out" "$text" "$desc"
}
settle() { sleep 2.2; } # objects are reused for 1s, which nginx tracks in whole seconds

lint() {
	if command -v shellcheck >/dev/null 2>&1; then
		shellcheck "$@"
	else
		docker run --rm -v "$work:$work" -w "$work" koalaman/shellcheck:stable "$@"
	fi
}

pwsh_run() { # pwsh_run SCRIPT [VAR=VALUE...]
	local script=$1 envs=() e
	shift
	if command -v pwsh >/dev/null 2>&1; then
		env "$@" pwsh -NoProfile -NonInteractive -Command "$script"
	else
		for e in "$@"; do envs+=(-e "$e"); done
		docker run --rm --network host "${envs[@]}" "$PWSH_IMAGE" pwsh -NoProfile -NonInteractive -Command "$script"
	fi
}

make_release() { # make_release VERSION DIR [EXTRA]: fake multi-platform release of "demo"
	local v=$1 d=$2 extra=${3:-} t
	mkdir -p "$d/build"
	printf '#!/bin/sh\necho "demo %s%s"\n' "$v" "$extra" >"$d/build/demo"
	chmod +x "$d/build/demo"
	for t in x86_64-unknown-linux-gnu aarch64-unknown-linux-gnu x86_64-apple-darwin aarch64-apple-darwin; do
		tar -czf "$d/demo-$t.tar.gz" -C "$d/build" demo
	done
	printf 'fake exe %s\n' "$v" >"$d/build/demo.exe"
	(cd "$d/build" && python3 -m zipfile -c ../demo-x86_64-pc-windows-msvc.zip demo.exe)
	rm -rf "$d/build"
	(cd "$d" && sha256sum -- *.tar.gz *.zip >checksums.txt)
}

install_sh() { # install_sh DIR [VAR=VALUE...]: run the published installer like a user would
	local dir=$1
	shift
	curl -fsSL "$PROXY/demo/install.sh" | env DEMO_INSTALL_DIR="$dir" "$@" sh
}

# ---------------------------------------------------------------------------------
step "start local S3 and proxy"
"${COMPOSE[@]}" up -d --quiet-pull
for _ in $(seq 60); do
	aws --endpoint-url "$TOOLS_S3_ENDPOINT" s3api list-buckets >/dev/null 2>&1 && break
	sleep 1
done
aws --endpoint-url "$TOOLS_S3_ENDPOINT" s3api create-bucket --bucket tools-test >/dev/null
toolsctl apply-policy
for _ in $(seq 30); do [ "$(status_code "$PROXY/healthz")" = 200 ] && break; sleep 1; done
expect_eq "$(status_code "$PROXY/healthz")" 200 "proxy is up"
expect_eq "$(status_code "$TOOLS_S3_ENDPOINT/tools-test/")" 403 "anonymous users cannot list the bucket"

step "publish demo 0.1.0 with generated installers"
make_release 0.1.0 "$work/r010"
toolsctl publish --tool demo --version v0.1.0 --description 'Demo <tool> & co' \
	--repo-url 'https://github.com/example/demo?a=1&b=2' -- "$work"/r010/*
expect_eq "$(curl -fsS "$PROXY/demo/latest")" 0.1.0 "latest is 0.1.0"
expect_eq "$(header "$PROXY/demo/install.sh" content-type)" "text/plain; charset=utf-8" "install.sh is text/plain"
expect_eq "$(header "$PROXY/demo/install.ps1" content-type)" "text/plain; charset=utf-8" "install.ps1 is text/plain (irm | iex needs text)"
expect_eq "$(header "$PROXY/demo/install.sh" cache-control)" "public, max-age=300" "scripts cache for 5 minutes"
expect_eq "$(header "$PROXY/demo/v0.1.0/checksums.txt" cache-control)" "public, max-age=31536000, immutable" "release files are immutable"
expect_eq "$(header "$PROXY/demo/v0.1.0/demo-x86_64-pc-windows-msvc.zip" content-type)" "application/zip" "zip content type"
expect_eq "$(status_code "$PROXY/demo")" 301 "/demo redirects"
expect_eq "$(header "$PROXY/demo" location)" "/demo/" "... to /demo/"
page=$(curl -fsS "$PROXY/demo/")
expect_has "$page" "curl -fsSL $PROXY/demo/install.sh | sh" "landing page shows the install command"
expect_has "$page" "Demo &lt;tool&gt; &amp; co" "description is HTML-escaped"
expect_has "$page" 'href="https://github.com/example/demo?a=1&amp;b=2"' "repo link is escaped"
root=$(curl -fsS "$PROXY/")
expect_has "$root" '<a href="/demo/">demo</a> <span>0.1.0</span>' "root index lists demo"
expect_eq "$(status_code "$PROXY/demo/nope")" 404 "missing file is 404 (bucket says 403)"
expect_eq "$(status_code "$PROXY/nope/")" 404 "unknown tool is 404"
expect_eq "$(header "$PROXY/nope/" content-type)" "text/plain; charset=utf-8" "404s are plain text"
expect_lacks "$(curl -s -D - "$PROXY/demo/nope")" "$TOOLS_S3_BUCKET" "a 404 does not reveal the bucket"
expect_lacks "$(curl -s -D - "$PROXY/demo/install.sh")" "$TOOLS_S3_BUCKET" "normal responses do not reveal the bucket"
expect_eq "$(status_code -X POST "$PROXY/demo/install.sh")" 405 "writes are rejected"
expect_lacks "$(curl -s "$PROXY/?list-type=2")" "ListBucketResult" "query strings never reach the bucket"

step "install with the generated installers"
curl -fsSL "$PROXY/demo/install.sh" -o "$work/install.sh"
if lint -s sh "$work/install.sh"; then ok "generated install.sh passes shellcheck"; else fail "shellcheck: install.sh"; fi
install_sh "$work/bin" >/dev/null 2>&1
expect_eq "$("$work/bin/demo")" "demo 0.1.0" "curl | sh installs 0.1.0"
out=$(pwsh_run "irm $PROXY/demo/install.ps1 | iex; Get-Content /tmp/pwbin/demo.exe" DEMO_INSTALL_DIR=/tmp/pwbin 2>&1)
expect_has "$out" "fake exe 0.1.0" "irm | iex installs 0.1.0"

step "versions are immutable"
out=$(toolsctl publish --tool demo --version 0.1.0 -- "$work"/r010/* 2>&1)
expect_has "$out" "already published with identical files" "re-running an identical publish is a no-op"
make_release 0.1.0 "$work/r010b" " (changed)"
expect_fail "different files for a published version are refused" "versions are immutable" \
	toolsctl publish --tool demo --version 0.1.0 -- "$work"/r010b/*
mkdir "$work/bad" && cp "$work"/r010b/*.tar.gz "$work/bad/" && cp "$work/r010/checksums.txt" "$work/bad/"
expect_fail "a checksums.txt that does not match the files is refused" "no matching entry" \
	toolsctl publish --tool demo --version 0.1.9 -- "$work"/bad/*

step "pre-release, release, pinned install, rollback"
make_release 0.2.0-rc.1 "$work/rc"
toolsctl publish --tool demo --version v0.2.0-rc.1 -- "$work"/rc/* 2>/dev/null
settle
expect_eq "$(curl -fsS "$PROXY/demo/latest")" 0.1.0 "pre-release leaves latest alone"
make_release 0.2.0 "$work/r020"
toolsctl publish --tool demo --version v0.2.0 -- "$work"/r020/* 2>/dev/null
settle
expect_eq "$(curl -fsS "$PROXY/demo/latest")" 0.2.0 "release moves latest"
install_sh "$work/bin" >/dev/null 2>&1
expect_eq "$("$work/bin/demo")" "demo 0.2.0" "installer picks up 0.2.0"
install_sh "$work/bin" DEMO_VERSION=0.1.0 >/dev/null 2>&1
expect_eq "$("$work/bin/demo")" "demo 0.1.0" "DEMO_VERSION pins a version"
toolsctl set-latest --tool demo --version 0.1.0 2>/dev/null
settle
expect_eq "$(curl -fsS "$PROXY/demo/latest")" 0.1.0 "set-latest rolls back"
expect_fail "set-latest refuses unknown versions" "not published" toolsctl set-latest --tool demo --version 9.9.9
toolsctl set-latest --tool demo --version 0.2.0 2>/dev/null

step "script-only tool"
mkdir -p "$work/setup-scripts"
printf '#!/bin/sh\necho setting things up\n' >"$work/setup-scripts/setup.sh"
toolsctl publish --tool setup-thing --scripts "$work/setup-scripts" 2>/dev/null
expect_eq "$(curl -fsS "$PROXY/setup-thing/setup.sh" | sh)" "setting things up" "setup.sh is served"
expect_eq "$(status_code "$PROXY/setup-thing/latest")" 404 "no latest for script-only tools"
settle
expect_has "$(curl -fsS "$PROXY/")" '<a href="/setup-thing/">setup-thing</a></li>' "root index lists it without a version"

step "proxy cache: hit, stale on bucket outage, emptied by restart"
f="$PROXY/demo/v0.2.0/checksums.txt"
curl -fsS -o /dev/null "$f"
expect_eq "$(header "$f" x-cache)" HIT "second request is served from the cache"
"${COMPOSE[@]}" stop s3 >/dev/null 2>&1
settle
resp=$(curl -s -D - -o /dev/null "$f" | tr -d '\r')
expect_has "$resp" "HTTP/1.1 200" "cached file still downloads while the bucket is down"
expect_has "$resp" "X-Cache: STALE" "... served as stale"
resp=$(curl -s -D - "$PROXY/demo/v0.2.0/demo-aarch64-apple-darwin.tar.gz" | tr -d '\r')
expect_has "$resp" "HTTP/1.1 503" "uncached file during the outage is a plain 503"
expect_lacks "$resp" "$TOOLS_S3_BUCKET" "... that does not reveal the bucket"
"${COMPOSE[@]}" start s3 >/dev/null 2>&1
for _ in $(seq 30); do aws --endpoint-url "$TOOLS_S3_ENDPOINT" s3api head-bucket --bucket tools-test >/dev/null 2>&1 && break; sleep 1; done
"${COMPOSE[@]}" restart proxy >/dev/null 2>&1
for _ in $(seq 30); do [ "$(status_code "$PROXY/healthz")" = 200 ] && break; sleep 1; done
expect_eq "$(header "$f" x-cache)" MISS "restarting the proxy empties the cache"

step "retire"
msg=$'Use "newdemo" instead: https://example.com/newdemo?a=1&b=2\nQuotes \' and `$HOME` and <b>tags</b> stay literal.'
toolsctl retire --tool demo --message "$msg"
settle
if out=$(curl -fsSL "$PROXY/demo/install.sh" | sh 2>&1); then fail "retired install.sh should exit non-zero"; fi
expect_has "$out" "demo is no longer distributed here" "curl | sh prints the retirement notice"
# shellcheck disable=SC2016 # literal on purpose: the notice must not expand anything
expect_has "$out" 'Quotes '"'"' and `$HOME` and <b>tags</b> stay literal.' "the message is printed verbatim"
curl -fsSL "$PROXY/demo/install.sh" -o "$work/retired.sh"
if lint -s sh "$work/retired.sh"; then ok "retired stub passes shellcheck"; else fail "shellcheck: retired stub"; fi
if out=$(pwsh_run "irm $PROXY/demo/install.ps1 | iex" 2>&1); then fail "retired install.ps1 should fail"; fi
expect_has "$out" 'Use "newdemo" instead' "irm | iex prints the notice"
expect_has "$out" "demo has been retired" "... and stops with an error"
expect_has "$(curl -fsS "$PROXY/demo/")" "&lt;b&gt;tags&lt;/b&gt;" "landing page shows the escaped notice"
expect_eq "$(status_code "$PROXY/demo/latest")" 404 "latest is gone"
expect_eq "$(status_code "$PROXY/demo/v0.2.0/demo-x86_64-unknown-linux-gnu.tar.gz")" 200 "release files stay downloadable"
expect_lacks "$(curl -fsS "$PROXY/")" '/demo/' "root index no longer lists demo"
expect_fail "publishing a retired tool is refused" "is retired" \
	toolsctl publish --tool demo --version 0.3.0 -- "$work"/r020/*
expect_has "$(toolsctl status --tool demo)" "retired" "status shows retired"

step "purge"
expect_fail "purge needs --yes" "re-run with --yes" toolsctl purge --tool demo
expect_fail "purge needs a retired tool" "not retired" toolsctl purge --tool setup-thing --yes
toolsctl purge --tool demo --yes 2>/dev/null
settle
expect_eq "$(status_code "$PROXY/demo/v0.2.0/demo-x86_64-unknown-linux-gnu.tar.gz")" 404 "release files are deleted"
if out=$(curl -fsSL "$PROXY/demo/install.sh" | sh 2>&1); then fail "notice should remain after purge"; fi
expect_has "$out" "no longer distributed" "the notice stays after purge"

step "unretire and publish again"
toolsctl unretire --tool demo 2>/dev/null
make_release 0.3.0 "$work/r030"
toolsctl publish --tool demo --version v0.3.0 -- "$work"/r030/* 2>/dev/null
settle
install_sh "$work/bin" >/dev/null 2>&1
expect_eq "$("$work/bin/demo")" "demo 0.3.0" "demo installs again"
expect_has "$(curl -fsS "$PROXY/")" '<a href="/demo/">demo</a> <span>0.3.0</span>' "root index lists demo again"

step "status"
toolsctl status

printf '\nAll %d checks passed.\n' "$passed"
