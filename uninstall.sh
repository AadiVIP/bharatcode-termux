#!/data/data/com.termux/files/usr/bin/bash
# BharatCode on Termux - uninstaller (independent compatibility project).
# Removes the wrapper and engine installed by install.sh. It never touches
# BharatCode account data, sessions, or the Termux glibc runtime.
# Not affiliated with or endorsed by BharatCode.
set -Eeuo pipefail
umask 077

readonly REPO_URL="https://github.com/AadiVIP/bharatcode-termux"
readonly MARKER="managed by AadiVIP/bharatcode-termux"
readonly DEFAULT_PREFIX="/data/data/com.termux/files/usr"

PREFIX="${PREFIX:-$DEFAULT_PREFIX}"
BC_DATA="${BHARATCODE_TERMUX_DATA:-${HOME:-}/.local/share/bharatcode-termux}"
TARGET="$PREFIX/bin/bharatcode"
FORCE=0

log()  { printf '==> %s\n' "$*" >&2; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
BharatCode on Termux uninstaller (independent compatibility project)

Usage: uninstall.sh [--force]

Options:
  --force     Proceed even if the install directory lacks this project's
              marker. The default refuses to delete unmarked directories.
  -h, --help  Show this help.

Environment:
  BHARATCODE_TERMUX_DATA   Install directory
                           (default: \$HOME/.local/share/bharatcode-termux)

Removes: $PREFIX/bin/bharatcode (only if it is this project's wrapper) and the
install directory. Restores a launcher backed up by install.sh when possible.
Keeps:   BharatCode account/session data and the Termux glibc packages.
EOF
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --force) FORCE=1 ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown option: $1 (see --help)" ;;
    esac
    shift
  done
}

require_termux() {
  if [ -z "${TERMUX_VERSION:-}" ] && [[ "$PREFIX" != *com.termux* ]]; then
    die "this uninstaller only runs inside Termux on Android. See $REPO_URL"
  fi
}

assert_safe_data_dir() {
  [ -n "$BC_DATA" ] || die "install directory is empty; refusing to continue"
  [ "$BC_DATA" != "/" ] || die "refusing to operate on /"
  [ "$BC_DATA" != "$HOME" ] || die "refusing to operate on the home directory"
  [ "$BC_DATA" != "$PREFIX" ] || die "refusing to operate on the Termux prefix"
}

data_dir_marked() {
  [ -f "$BC_DATA/.managed-by" ] && grep -qxF "$MARKER" "$BC_DATA/.managed-by" 2>/dev/null
}

has_backup() {
  [ -f "$BC_DATA/state/launcher-backup" ]
}

restore_backup() {
  local backup
  backup="$(cat "$BC_DATA/state/launcher-backup" 2>/dev/null || true)"
  if [ -z "$backup" ] || [ ! -f "$backup" ]; then
    warn "a launcher backup was recorded but the file is missing; nothing to restore"
    return 0
  fi
  if [ -e "$TARGET" ] || [ -L "$TARGET" ]; then
    warn "not restoring $backup because $TARGET already exists"
    return 0
  fi
  mv "$backup" "$TARGET"
  log "Restored the previous launcher to $TARGET"
}

warn_running() {
  local pids=""
  if command -v ps >/dev/null 2>&1; then
    pids="$(ps -ef 2>/dev/null | grep -F "$BC_DATA" | grep -v grep | awk '{print $2}' | tr '\n' ' ' || true)"
  fi
  if [ -n "$pids" ]; then
    warn "BharatCode-related processes appear to be running (pids: $pids); stop them first if files cannot be removed"
  fi
}

main() {
  parse_args "$@"
  require_termux
  assert_safe_data_dir

  local wrapper_present=0 data_present=0
  if [ -e "$TARGET" ] || [ -L "$TARGET" ]; then wrapper_present=1; fi
  if [ -e "$BC_DATA" ]; then data_present=1; fi

  if [ "$wrapper_present" -eq 0 ] && [ "$data_present" -eq 0 ]; then
    log "BharatCode (this installer) is not installed at $TARGET"
    exit 0
  fi

  if [ "$data_present" -eq 1 ] && ! data_dir_marked && [ "$FORCE" -eq 0 ]; then
    die "refusing to remove unmarked directory $BC_DATA (use --force if you are sure)"
  fi

  if [ "$wrapper_present" -eq 1 ] && ! grep -qF "$MARKER" "$TARGET" 2>/dev/null; then
    die "$TARGET is not this project's wrapper; remove it manually if appropriate (nothing was changed)"
  fi

  warn_running

  if [ "$wrapper_present" -eq 1 ]; then
    rm -f "$TARGET"
    log "Removed $TARGET"
  fi

  if [ "$data_present" -eq 1 ]; then
    if has_backup; then restore_backup; fi
    rm -rf -- "$BC_DATA"
    log "Removed $BC_DATA"
  fi

  cat >&2 <<EOF

BharatCode has been removed from this Termux installation.

Kept on purpose:
  - BharatCode account and session data:
      \$HOME/.local/share/BharatCode
      \$HOME/.config/BharatCode
      \$HOME/.local/state/BharatCode
      \$HOME/.cache/BharatCode
    Delete those directories manually only if you want to erase your data.
  - Termux glibc packages (glibc, termux-exec-glibc, glibc-repo). They may be
    used by other software; remove them with 'pkg uninstall' only if unused.

Reinstall with:
  curl -fsSL $REPO_URL/raw/main/install.sh | bash
EOF
}

if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  main "$@"
fi
