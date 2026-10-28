#!/data/data/com.termux/files/usr/bin/bash
# Verify that the SHA-256 pins in install.sh match the official npm tarballs
# and that npm's own sha512 integrity and sha1 shasum metadata agree.
# Requires network access, curl, openssl, python3, sha256sum, sha1sum.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

REGISTRY="https://registry.npmjs.org"
VERSION="$(sed -n 's/^readonly PINNED_VERSION="\([^"]*\)"$/\1/p' install.sh | head -n1)"
MAIN_SHA="$(sed -n 's/^readonly PINNED_MAIN_SHA256="\([^"]*\)"$/\1/p' install.sh | head -n1)"
NATIVE_SHA="$(sed -n 's/^readonly PINNED_NATIVE_SHA256="\([^"]*\)"$/\1/p' install.sh | head -n1)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/bharatcode-pins.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT

fails=0
pass() { printf '[pass] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; fails=$((fails + 1)); }

[ -n "$VERSION" ] && [ -n "$MAIN_SHA" ] && [ -n "$NATIVE_SHA" ] || {
  printf 'error: could not read pins from install.sh\n' >&2
  exit 1
}

for tool in curl openssl python3 sha256sum sha1sum; do
  command -v "$tool" >/dev/null 2>&1 || { printf 'error: missing tool: %s\n' "$tool" >&2; exit 1; }
done

verify_pkg() {
  local pkg="$1" expected_sha256="$2" meta tarball integrity shasum
  meta="$TMP/$pkg.json"
  printf 'Checking %s@%s\n' "$pkg" "$VERSION"
  if ! curl -fsSL --retry 3 --connect-timeout 20 --proto '=https' --tlsv1.2 -o "$meta" "$REGISTRY/$pkg/$VERSION"; then
    fail "$pkg: registry metadata download failed"
    return 1
  fi
  local fields
  fields="$(python3 - "$meta" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
dist = d.get("dist", {})
print(dist.get("tarball", ""))
print(dist.get("integrity", ""))
print(dist.get("shasum", ""))
PY
)" || { fail "$pkg: cannot parse registry metadata"; return 1; }
  tarball="$(printf '%s\n' "$fields" | sed -n '1p')"
  integrity="$(printf '%s\n' "$fields" | sed -n '2p')"
  shasum="$(printf '%s\n' "$fields" | sed -n '3p')"
  case "$tarball" in
    "$REGISTRY/$pkg/-/$pkg-$VERSION.tgz") pass "$pkg: tarball URL is the official registry path" ;;
    *) fail "$pkg: unexpected tarball URL: $tarball" ;;
  esac
  if [ -z "$integrity" ] || [ -z "$shasum" ]; then
    fail "$pkg: registry metadata lacks integrity/shasum"
    return 1
  fi
  if ! curl -fsSL --retry 3 --connect-timeout 20 --proto '=https' --tlsv1.2 -o "$TMP/$pkg.tgz" "$tarball"; then
    fail "$pkg: tarball download failed"
    return 1
  fi
  local got_sha256 got_sha512 got_sha1
  got_sha256="$(sha256sum "$TMP/$pkg.tgz" | cut -d' ' -f1)"
  got_sha512="sha512-$(openssl dgst -sha512 -binary "$TMP/$pkg.tgz" | openssl base64 -A)"
  got_sha1="$(sha1sum "$TMP/$pkg.tgz" | cut -d' ' -f1)"
  if [ "$got_sha256" = "$expected_sha256" ]; then
    pass "$pkg: SHA-256 matches the pin"
  else
    fail "$pkg: SHA-256 mismatch (pin $expected_sha256, got $got_sha256)"
  fi
  if [ "$got_sha512" = "$integrity" ]; then
    pass "$pkg: npm registry sha512 integrity verified"
  else
    fail "$pkg: npm registry sha512 mismatch (registry $integrity, got $got_sha512)"
  fi
  if [ "$got_sha1" = "$shasum" ]; then
    pass "$pkg: npm registry sha1 shasum verified"
  else
    fail "$pkg: npm registry sha1 mismatch (registry $shasum, got $got_sha1)"
  fi
  printf '       sha256=%s\n' "$got_sha256"
}

verify_pkg bharatcode "$MAIN_SHA"
verify_pkg bharatcode-linux-arm64 "$NATIVE_SHA"

if [ "$fails" -eq 0 ]; then
  printf '\nAll pin, integrity, and shasum checks passed for %s.\n' "$VERSION"
  exit 0
fi
printf '\n%d pin/integrity check(s) failed.\n' "$fails" >&2
exit 1
