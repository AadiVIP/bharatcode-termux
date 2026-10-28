#!/data/data/com.termux/files/usr/bin/bash
# BharatCode on Termux - update/repair helper (independent compatibility project).
# Runs the project installer, which installs the pinned, tested version and
# repairs a broken installation. Arguments are forwarded to install.sh.
# Not affiliated with or endorsed by BharatCode.
set -Eeuo pipefail
umask 077

readonly REPO_URL="https://github.com/AadiVIP/bharatcode-termux"
readonly INSTALL_MARKER="BharatCode on Termux installer"
readonly DEFAULT_PREFIX="/data/data/com.termux/files/usr"

PREFIX="${PREFIX:-$DEFAULT_PREFIX}"
TMP_FILE=""

log()  { printf '==> %s\n' "$*" >&2; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

cleanup() {
  [ -n "$TMP_FILE" ] && [ -f "$TMP_FILE" ] && rm -f "$TMP_FILE" || true
}

usage() {
  cat <<EOF
BharatCode on Termux updater (independent compatibility project)

Usage: update.sh [installer options]

Runs install.sh from this checkout when present, otherwise downloads the
current installer from:
  https://raw.githubusercontent.com/AadiVIP/bharatcode-termux/main/install.sh

Installer options (forwarded):
  --force             Reinstall the pinned version even if present.
  --version X.Y.Z     Try a specific version (requires --allow-untested
                      unless it is the pinned version).
  --allow-untested    Allow a non-pinned version (rollback on smoke failure).

Environment:
  BHARATCODE_TERMUX_INSTALL_URL   Override the installer URL.
  BHARATCODE_TERMUX_DATA          Install directory.
  BHARATCODE_TERMUX_GLIBC_DIR     Override the glibc runtime directory.

Updates install the version pinned and tested by this project; they do not
authenticate, and they never delete BharatCode account or session data.
EOF
}

before_version() {
  if command -v bharatcode >/dev/null 2>&1; then
    local v
    v="$(timeout 120 bharatcode --version 2>/dev/null | sed -n '1p' || true)"
    [ -n "$v" ] && log "Currently installed: $v"
  else
    log "Currently installed: none found on PATH"
  fi
}

script_dir() {
  local src="${BASH_SOURCE[0]:-}"
  if [ -n "$src" ] && [ -f "$src" ]; then
    cd "$(dirname "$src")" && pwd
  else
    pwd
  fi
}

main() {
  case "${1:-}" in
    -h|--help) usage; exit 0 ;;
  esac

  local dir local_installer=""
  dir="$(script_dir)"
  if [ -f "$dir/install.sh" ] && grep -qF "$INSTALL_MARKER" "$dir/install.sh" 2>/dev/null; then
    local_installer="$dir/install.sh"
  fi

  before_version

  if [ -n "$local_installer" ]; then
    log "Using local installer: $local_installer"
    bash "$local_installer" "$@"
    exit $?
  fi

  command -v curl >/dev/null 2>&1 || die "curl is required to download the installer"
  local url="${BHARATCODE_TERMUX_INSTALL_URL:-$REPO_URL/raw/main/install.sh}"
  local tmpdir="${TMPDIR:-$PREFIX/tmp}"
  [ -d "$tmpdir" ] && [ -w "$tmpdir" ] || tmpdir="${HOME:-$PREFIX}"
  TMP_FILE="$(mktemp "$tmpdir/bharatcode-update.XXXXXX")" || die "cannot create a temporary file"
  trap cleanup EXIT INT TERM HUP

  log "Downloading installer: $url"
  curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 20 --proto '=https' --tlsv1.2 \
    -o "$TMP_FILE" "$url" || die "could not download the installer"
  grep -qF "$INSTALL_MARKER" "$TMP_FILE" 2>/dev/null \
    || die "downloaded file does not look like the BharatCode Termux installer"

  bash "$TMP_FILE" "$@"
  local status=$?
  cleanup
  TMP_FILE=""
  exit "$status"
}

if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  main "$@"
fi
