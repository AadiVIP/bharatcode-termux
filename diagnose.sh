#!/data/data/com.termux/files/usr/bin/bash
# BharatCode on Termux - diagnostics (independent compatibility project).
# Read-only: checks the environment, runtime, installation, network, and auth
# state. It never starts a login flow and never prints credentials.
# Not affiliated with or endorsed by BharatCode.
set -uo pipefail
umask 077

readonly REPO_URL="https://github.com/AadiVIP/bharatcode-termux"
readonly MARKER="managed by AadiVIP/bharatcode-termux"
readonly DEFAULT_PREFIX="/data/data/com.termux/files/usr"
readonly MIN_FREE_KB=$((600 * 1024))

PREFIX="${PREFIX:-$DEFAULT_PREFIX}"
BC_DATA="${BHARATCODE_TERMUX_DATA:-${HOME:-}/.local/share/bharatcode-termux}"
TARGET="$PREFIX/bin/bharatcode"
FAILS=0
WARNS=0

ok()   { printf '[ ok ] %s\n' "$*"; }
warn() { printf '[warn] %s\n' "$*"; WARNS=$((WARNS + 1)); }
fail() { printf '[FAIL] %s\n' "$*"; FAILS=$((FAILS + 1)); }
note() { printf '       %s\n' "$*"; }
section() { printf '\n== %s ==\n' "$*"; }

free_kb() {
  local a s
  a="$(stat -f -c '%a' "$1" 2>/dev/null || echo 0)"
  s="$(stat -f -c '%S' "$1" 2>/dev/null || echo 0)"
  if [ "$a" -gt 0 ] && [ "$s" -gt 0 ]; then
    echo $(( a * s / 1024 ))
  else
    df -Pk "$1" 2>/dev/null | sed -n '2p' | tr -s ' ' | cut -d' ' -f4
  fi
}

run_bounded() {
  local seconds="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$seconds" "$@"
  else
    "$@"
  fi
}

check_environment() {
  section "Environment"
  if [ -n "${TERMUX_VERSION:-}" ]; then
    ok "Termux $TERMUX_VERSION"
  else
    warn "TERMUX_VERSION is not set (not running in Termux?)"
  fi
  case "$PREFIX" in
    *com.termux*) ok "Termux prefix: $PREFIX" ;;
    *) fail "PREFIX does not look like Termux: ${PREFIX:-<unset>}" ;;
  esac
  local arch abi
  arch="$(uname -m 2>/dev/null || echo unknown)"
  case "$arch" in
    aarch64|arm64) ok "CPU architecture: $arch" ;;
    *) fail "CPU architecture $arch is not arm64/aarch64" ;;
  esac
  if command -v getprop >/dev/null 2>&1; then
    abi="$(getprop ro.product.cpu.abi 2>/dev/null || true)"
    if [ -n "$abi" ]; then
      case "$abi" in arm64*) ok "Android ABI: $abi" ;; *) fail "Android ABI $abi is not arm64" ;; esac
    fi
    note "Android release $(getprop ro.build.version.release 2>/dev/null || echo '?') (SDK $(getprop ro.build.version.sdk 2>/dev/null || echo '?'))"
  fi
  if [ -n "${TMPDIR:-}" ] && [ -d "${TMPDIR:-/nonexistent}" ] && [ -w "${TMPDIR:-/nonexistent}" ]; then
    ok "TMPDIR is writable: $TMPDIR"
  elif [ -d "$PREFIX/tmp" ] && [ -w "$PREFIX/tmp" ]; then
    warn "TMPDIR is unset or unusable; the wrapper falls back to $PREFIX/tmp"
  else
    fail "no writable temporary directory (TMPDIR and $PREFIX/tmp are unusable)"
  fi
  local probe="$BC_DATA"
  [ -d "$probe" ] || probe="${HOME:-$PREFIX}"
  local avail
  avail="$(free_kb "$probe")"
  if [ -n "$avail" ] && [ "$avail" -gt 0 ]; then
    if [ "$avail" -ge "$MIN_FREE_KB" ]; then
      ok "Free storage: $((avail / 1024)) MiB"
    elif [ "$avail" -ge 200 ]; then
      warn "Free storage is low: $((avail / 1024)) MiB (installer wants $((MIN_FREE_KB / 1024)) MiB)"
    else
      fail "Very low free storage: $((avail / 1024)) MiB"
    fi
  else
    warn "could not determine free storage"
  fi
}

check_tools() {
  section "Basic tools"
  local t missing=0
  for t in bash curl tar sha256sum od stat mktemp timeout readlink sed grep cut; do
    if command -v "$t" >/dev/null 2>&1; then
      :
    else
      warn "missing tool: $t"
      missing=$((missing + 1))
    fi
  done
  [ "$missing" -eq 0 ] && ok "all tools found"
}

check_glibc() {
  section "Termux glibc runtime"
  local gdir loader
  gdir="${BHARATCODE_TERMUX_GLIBC_DIR:-$PREFIX/glibc}"
  loader="$gdir/lib/ld-linux-aarch64.so.1"
  if [ -x "$loader" ]; then
    ok "loader present: $loader"
  else
    fail "glibc loader missing or not executable: $loader"
    return 0
  fi
  local gv
  gv="$( (unset LD_PRELOAD LD_LIBRARY_PATH LD_AUDIT LD_DEBUG; "$loader" --version 2>/dev/null) | sed -n '1p' )"
  if [ -n "$gv" ]; then
    ok "$gv"
  else
    fail "glibc loader does not run (try: pkg reinstall glibc)"
  fi
  if [ -f "$gdir/lib/libc.so.6" ]; then
    ok "libc.so.6 present"
  else
    fail "libc.so.6 missing in $gdir/lib"
  fi
  if [ -f "$gdir/lib/libtermux-exec.so" ]; then
    ok "termux-exec-glibc preload present (shebang rewriting enabled)"
  else
    warn "libtermux-exec.so missing; helper shebangs may not use Termux paths"
  fi
  if command -v dpkg >/dev/null 2>&1; then
    local pkgver
    pkgver="$(dpkg -l glibc 2>/dev/null | awk '$1=="ii" {print $3}' | head -n1)"
    [ -n "$pkgver" ] && note "glibc package version: $pkgver"
  fi
}

state_value() {
  local key="$1"
  sed -n "s/^$key=//p" "$BC_DATA/state/install.env" 2>/dev/null | head -n1
}

check_installation() {
  section "Installation"
  if [ -f "$TARGET" ]; then
    ok "launcher exists: $TARGET"
  else
    fail "launcher missing: $TARGET (run install.sh)"
  fi
  if [ -f "$TARGET" ] && grep -qF "$MARKER" "$TARGET" 2>/dev/null; then
    ok "launcher is managed by this project"
  elif [ -f "$TARGET" ]; then
    warn "launcher exists but is not this project's wrapper"
  fi
  if [ -f "$TARGET" ] && [ -x "$TARGET" ]; then
    ok "launcher is executable"
  fi
  local interp
  interp="$(sed -n '1s/^#!//p' "$TARGET" 2>/dev/null || true)"
  if [ -n "$interp" ]; then
    if [ -x "$interp" ]; then ok "launcher interpreter: $interp"; else fail "launcher interpreter missing: $interp"; fi
  fi
  local found
  found="$(command -v bharatcode 2>/dev/null || true)"
  if [ -n "$found" ]; then
    if [ "$found" = "$TARGET" ]; then
      ok "'bharatcode' resolves to the managed launcher"
    else
      warn "'bharatcode' resolves to $found instead of $TARGET (PATH shadowing)"
    fi
  else
    warn "'bharatcode' is not on PATH; add $PREFIX/bin to PATH or open a new shell"
  fi

  if [ -d "$BC_DATA" ]; then
    ok "install directory: $BC_DATA"
  else
    fail "install directory missing: $BC_DATA"
    return 0
  fi
  if [ -f "$BC_DATA/.managed-by" ] && grep -qxF "$MARKER" "$BC_DATA/.managed-by" 2>/dev/null; then
    ok "install directory marker present"
  else
    warn "install directory marker missing; re-run install.sh to refresh it"
  fi
  if [ -L "$BC_DATA/current" ]; then
    ok "current -> $(readlink "$BC_DATA/current" 2>/dev/null || echo '?')"
  else
    fail "$BC_DATA/current is missing or not a symlink"
  fi
  local engine="$BC_DATA/current/bharatcode" ver eng_sha actual
  ver="$(state_value version)"
  if [ -n "$ver" ]; then ok "installed version (state): $ver"; else warn "installed version is not recorded in state"; fi
  if [ -f "$engine" ]; then
    ok "engine binary present"
    if [ -x "$engine" ]; then ok "engine binary executable"; else fail "engine binary is not executable"; fi
    eng_sha="$(state_value engine_sha256)"
    actual="$(sha256sum "$engine" 2>/dev/null | cut -d' ' -f1)"
    if [ -n "$eng_sha" ] && [ "$eng_sha" != "unknown" ]; then
      if [ "$actual" = "$eng_sha" ]; then
        ok "engine SHA-256 matches the recorded install"
      else
        fail "engine SHA-256 mismatch (expected $eng_sha, got ${actual:-?})"
      fi
    else
      warn "engine SHA-256 was not recorded; re-run install.sh --force to add it"
    fi
  else
    fail "engine binary missing: $engine"
  fi
  [ -f "$BC_DATA/current/LICENSE" ] && ok "official LICENSE retained" || warn "LICENSE missing from install directory"
  if [ -f "$BC_DATA/state/launcher-backup" ]; then
    note "previous launcher backup recorded: $(cat "$BC_DATA/state/launcher-backup" 2>/dev/null || echo '?')"
  fi
}

check_runtime() {
  section "Runtime"
  if [ ! -x "$TARGET" ]; then
    fail "cannot run the launcher (missing or not executable)"
    return 0
  fi
  local expected out status
  expected="$(state_value version)"
  out="$(run_bounded 120 "$TARGET" --version 2>&1)"
  status=$?
  out="$(printf '%s' "$out" | sed -n '1p' | tr -d '\r')"
  if [ "$status" -eq 0 ] && [ -n "$out" ]; then
    ok "bharatcode --version -> $out (exit 0)"
    if [ -n "$expected" ] && [ "$out" != "$expected" ]; then
      fail "version mismatch: launcher reported $out, state says $expected"
    fi
  else
    fail "bharatcode --version failed (exit $status): $out"
    return 0
  fi
  local auth_out auth_status
  auth_out="$(run_bounded 60 "$TARGET" auth status 2>&1)"
  auth_status=$?
  if printf '%s' "$auth_out" | grep -qi 'signed out'; then
    ok "BharatCode account: signed out (run 'bharatcode auth login' to sign in)"
  elif printf '%s' "$auth_out" | grep -qi 'signed in'; then
    ok "BharatCode account: signed in"
  else
    warn "could not determine account state from 'auth status' (exit $auth_status)"
  fi
}

check_network() {
  section "Network"
  if ! command -v curl >/dev/null 2>&1; then
    warn "curl is missing; skipping network checks"
    return 0
  fi
  local code
  code="$(curl -fsS -o /dev/null -w '%{http_code}' --max-time 20 \
    "https://registry.npmjs.org/bharatcode" 2>/dev/null || echo 000)"
  if [ "$code" = "200" ]; then
    ok "npm registry reachable over HTTPS"
  else
    warn "npm registry check returned HTTP ${code:-000} (captive portal, DNS, or offline?)"
  fi
  code="$(curl -fsS -o /dev/null -w '%{http_code}' --max-time 20 \
    "https://auth.bharatcode.ai" 2>/dev/null || echo 000)"
  if [ "$code" = "200" ] || [ "$code" = "301" ] || [ "$code" = "302" ] || [ "$code" = "404" ]; then
    ok "BharatCode auth endpoint reachable over HTTPS (HTTP $code)"
  else
    warn "BharatCode auth endpoint check returned HTTP ${code:-000}"
  fi
}

check_notes() {
  section "Notes"
  if [ -n "${LD_PRELOAD:-}" ]; then
    note "LD_PRELOAD is set in this shell (Termux uses it for Bionic); the wrapper unsets it for the glibc engine."
  fi
  if [ -d "$HOME/.local/share/BharatCode" ]; then
    note "BharatCode account/session data: $HOME/.local/share/BharatCode"
  fi
  note "Do not use the engine's built-in 'bharatcode uninstall' command for this installation;"
  note "use $REPO_URL#uninstalling instead."
}

main() {
  if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    cat <<EOF
BharatCode on Termux diagnostics (read-only)

Usage: diagnose.sh [--help]

Checks Termux environment, arm64 ABI, storage, tools, glibc runtime, launcher,
install integrity, runtime version, account state, and network reachability.
Exit status: 0 if no critical failures, 1 if any critical check failed.
EOF
    exit 0
  fi
  [ $# -eq 0 ] || { printf 'error: unknown option: %s\n' "$1" >&2; exit 2; }
  printf 'BharatCode on Termux diagnostics\nProject: %s\n' "$REPO_URL"
  check_environment
  check_tools
  check_glibc
  check_installation
  check_runtime
  check_network
  check_notes
  section "Summary"
  if [ "$FAILS" -gt 0 ]; then
    printf '%d critical failure(s), %d warning(s).\n' "$FAILS" "$WARNS"
    printf 'Try reinstalling: curl -fsSL %s/raw/main/install.sh | bash\n' "$REPO_URL"
    exit 1
  fi
  printf 'All critical checks passed (%d warning(s)).\n' "$WARNS"
  exit 0
}

if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  main "$@"
fi
