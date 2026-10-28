#!/data/data/com.termux/files/usr/bin/bash
# Real on-device end-to-end tests for BharatCode on Termux.
# Requires Termux/arm64, the Termux glibc runtime, and network access unless the
# engine is already installed. WARNING: this suite installs or repairs
# BharatCode in the real Termux prefix. --with-uninstall removes and reinstalls
# it; account/session data is never touched.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
# shellcheck source=../lib/common.sh
source lib/common.sh
SERVE_PID=""
cleanup() {
  if [ -n "${SERVE_PID:-}" ] && kill -0 "$SERVE_PID" 2>/dev/null; then
    kill -TERM "$SERVE_PID" 2>/dev/null || true
    sleep 1
    kill -KILL "$SERVE_PID" 2>/dev/null || true
  fi
  cleanup_tmpdirs
}
trap cleanup EXIT

WITH_UNINSTALL=0
WITH_AUTH=0
SKIP_TUI=0
WITH_NETWORK=0

usage() {
  cat <<EOF
BharatCode on Termux - real device test suite

Usage: tests/device.sh [options]

Options:
  --with-uninstall   Also uninstall, verify removal/idempotency, then reinstall.
  --with-auth        Start (but never complete) 'auth login' for 20 seconds and
                     verify the official flow launches. No credentials are sent.
  --with-network     Run 'bharatcode models' (network) and require success.
  --skip-tui         Skip the PTY-based TUI launch test.
  -h, --help         Show this help.

Requires: Termux on arm64, the Termux glibc runtime, curl, and (for TUI)
python3. The suite installs the pinned version if it is not already present.
EOF
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --with-uninstall) WITH_UNINSTALL=1 ;;
      --with-auth) WITH_AUTH=1 ;;
      --with-network) WITH_NETWORK=1 ;;
      --skip-tui) SKIP_TUI=1 ;;
      -h|--help) usage; exit 0 ;;
      *) printf 'error: unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
    shift
  done
}

LAST_OUT=""
LAST_STATUS=0
run_sub() { LAST_OUT="$("$@" 2>&1)"; LAST_STATUS=$?; }
expect_status() {
  local expected="$1" msg="$2"
  if [ "$LAST_STATUS" -eq "$expected" ]; then
    pass "$msg"
  else
    fail "$msg (exit $LAST_STATUS, expected $expected; output: $(printf '%s' "$LAST_OUT" | sanitize_log | head -c 400))"
  fi
}

EXPECTED_VERSION="$(sed -n 's/^readonly PINNED_VERSION="\([^"]*\)"$/\1/p' install.sh | head -n1)"

require_device() {
  if [ -z "${TERMUX_VERSION:-}" ]; then
    printf 'error: these tests must run inside Termux on Android\n' >&2
    exit 2
  fi
  case "$(uname -m)" in
    aarch64|arm64) ;;
    *) printf 'error: arm64/aarch64 is required\n' >&2; exit 2 ;;
  esac
  local loader="${BHARATCODE_TERMUX_GLIBC_DIR:-${PREFIX:-/data/data/com.termux/files/usr}/glibc}/lib/ld-linux-aarch64.so.1"
  if [ ! -x "$loader" ]; then
    printf 'error: glibc runtime missing at %s; run install.sh first\n' "$loader" >&2
    exit 2
  fi
  [ -n "$EXPECTED_VERSION" ] || { printf 'error: cannot read PINNED_VERSION from install.sh\n' >&2; exit 2; }
}

ensure_installed() {
  local current=""
  if command -v bharatcode >/dev/null 2>&1; then
    current="$(timeout 120 bharatcode --version 2>/dev/null | sed -n '1p' | tr -d '\r')"
  fi
  if [ "$current" = "$EXPECTED_VERSION" ] && grep -qF "managed by AadiVIP/bharatcode-termux" "${PREFIX}/bin/bharatcode" 2>/dev/null; then
    pass "BharatCode $EXPECTED_VERSION already installed"
    return 0
  fi
  printf 'Installing BharatCode %s (this may download ~60 MB)...\n' "$EXPECTED_VERSION"
  run_sub bash install.sh
  expect_status 0 "installer exits 0"
  if [ "$LAST_STATUS" -ne 0 ]; then
    printf '%s\n' "$LAST_OUT" | sanitize_log | tail -20 >&2
    return 1
  fi
  run_sub timeout 120 bharatcode --version
  expect_status 0 "installed launcher runs"
  assert_eq "$EXPECTED_VERSION" "$(printf '%s' "$LAST_OUT" | sed -n '1p' | tr -d '\r')" "installed version is the pinned version"
}

test_version_help() {
  printf '\n-- version/help --\n'
  run_sub timeout 120 bharatcode --version
  expect_status 0 "bharatcode --version exits 0"
  assert_eq "$EXPECTED_VERSION" "$(printf '%s' "$LAST_OUT" | sed -n '1p' | tr -d '\r')" "version output matches the pin"
  run_sub timeout 120 bharatcode --help
  expect_status 0 "bharatcode --help exits 0"
  assert_contains "$LAST_OUT" "Commands:" "help lists commands"
}

test_auth_status() {
  printf '\n-- account status --\n'
  run_sub timeout 60 bharatcode auth status
  expect_status 0 "auth status exits 0"
  case "$LAST_OUT" in
    *"Signed out"*|*"signed out"*) pass "account is signed out (no credential test)" ;;
    *"Signed in"*|*"signed in"*) pass "account is signed in" ;;
    *) fail "auth status output was not recognized" ;;
  esac
}

test_exit_and_argv() {
  printf '\n-- argument and exit-code forwarding --\n'
  run_sub timeout 60 bharatcode --definitely-not-an-option
  [ "$LAST_STATUS" -ne 0 ] && pass "invalid CLI option returns a non-zero exit ($LAST_STATUS)" || fail "invalid CLI option returned 0"
  run_sub timeout 60 bharatcode debug paths
  expect_status 0 "debug paths exits 0"
  assert_contains "$LAST_OUT" "data" "debug paths output flows through the wrapper"
  run_sub timeout 60 bharatcode run --help
  expect_status 0 "subcommand --help exits 0 (arguments reach the engine)"
  assert_contains "$LAST_OUT" "bharatcode run" "subcommand help is rendered by the engine"
}

test_stdio() {
  printf '\n-- stdio --\n'
  local out err
  out="$(new_tmpdir)"
  err="$(new_tmpdir)"
  timeout 120 bharatcode --version >"$out/stdout" 2>"$err/stderr"
  local status=$?
  if [ "$status" -eq 0 ]; then pass "version exits 0 with redirected stdio"; else fail "version failed under redirection (exit $status)"; fi
  assert_eq "$EXPECTED_VERSION" "$(sed -n '1p' "$out/stdout" | tr -d '\r')" "version goes to stdout"
  assert_eq "0" "$(wc -c < "$err/stderr" | tr -d ' ')" "version writes nothing to stderr"
}

test_clean_shell() {
  printf '\n-- shell restart/persistence --\n'
  run_sub env -i HOME="$HOME" TERM=xterm-256color "$PREFIX/bin/bash" -lc 'command -v bharatcode && bharatcode --version'
  expect_status 0 "clean login shell finds and runs bharatcode"
  assert_contains "$LAST_OUT" "$EXPECTED_VERSION" "clean login shell reports the pinned version"
}

test_serve_signal() {
  printf '\n-- headless server and SIGTERM --\n'
  local port=$(( 44000 + (RANDOM % 500) ))
  local logdir
  logdir="$(new_tmpdir)"
  bharatcode serve --hostname 127.0.0.1 --port "$port" >"$logdir/stdout" 2>"$logdir/stderr" &
  SERVE_PID=$!
  local code=000 i
  for i in $(seq 1 120); do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 1 "http://127.0.0.1:$port/config" 2>/dev/null || true)"
    [ "$code" = "200" ] && break
    kill -0 "$SERVE_PID" 2>/dev/null || break
    sleep 0.5
  done
  if [ "$code" = "200" ]; then
    pass "headless server answers GET /config with 200"
  else
    fail "headless server did not answer (last HTTP ${code:-000})"
    printf '%s\n' "$(sanitize_log < "$logdir/stdout")" | tail -10 >&2
    kill -TERM "$SERVE_PID" 2>/dev/null || true
    wait "$SERVE_PID" 2>/dev/null
    SERVE_PID=""
    return 0
  fi
  kill -TERM "$SERVE_PID" 2>/dev/null || true
  local waited=0
  while kill -0 "$SERVE_PID" 2>/dev/null && [ "$waited" -lt 40 ]; do
    sleep 0.25
    waited=$((waited + 1))
  done
  if kill -0 "$SERVE_PID" 2>/dev/null; then
    fail "server did not exit within 10s of SIGTERM"
    kill -KILL "$SERVE_PID" 2>/dev/null || true
    wait "$SERVE_PID" 2>/dev/null
  else
    wait "$SERVE_PID"
    local status=$?
    assert_eq "143" "$status" "SIGTERM is forwarded to the engine (wait status 143)"
  fi
  SERVE_PID=""
}

test_tui() {
  printf '\n-- TUI launch under a PTY --\n'
  if [ "$SKIP_TUI" -eq 1 ]; then skip "TUI test disabled by --skip-tui"; return 0; fi
  if ! command -v python3 >/dev/null 2>&1; then skip "python3 unavailable; TUI PTY test skipped"; return 0; fi
  local dir out
  dir="$(new_tmpdir)"
  mkdir -p "$dir/project"
  out="$dir/tui.bin"
  (
    cd "$dir/project" || exit 1
    timeout 90 python3 "$REPO_ROOT/tests/pty_run.py" "$out" 25 '\x03' -- bharatcode .
  ) > "$dir/driver.json" 2>&1
  local status=$?
  assert_eq "0" "$status" "PTY driver exits 0"
  assert_contains "$(cat "$dir/driver.json")" '"exit": 0' "TUI exits 0 after Ctrl+C"
  assert_not_contains "$(cat "$dir/driver.json")" '"signaled": true' "TUI shuts down gracefully (not killed)"
  if [ -s "$out" ]; then pass "TUI produced terminal output"; else fail "TUI produced no output"; fi
  if grep -aq "BharatCode" "$out"; then pass "TUI rendered BharatCode UI or sign-in screen"; else fail "TUI output did not mention BharatCode"; fi
}

test_update_idempotent() {
  printf '\n-- update/repair path --\n'
  run_sub bash update.sh
  expect_status 0 "update.sh exits 0 when the pinned version is current"
  assert_contains "$LAST_OUT" "already installed" "update.sh reuses the idempotent installer path"
}

test_auth_launch() {
  printf '\n-- official auth flow launch (no credentials submitted) --\n'
  if [ "$WITH_AUTH" -eq 0 ]; then skip "auth-launch test disabled by default (use --with-auth)"; return 0; fi
  local dir
  dir="$(new_tmpdir)"
  timeout 20 bharatcode auth login >"$dir/auth.log" 2>&1
  local status=$?
  if [ "$status" -eq 124 ]; then
    pass "auth login stayed in the official waiting state (timeout killed it)"
  elif [ "$status" -eq 0 ] && grep -aqE 'already|signed in' "$dir/auth.log"; then
    pass "auth login reports an existing session"
  else
    fail "auth login did not launch the expected flow (exit $status)"
  fi
  if grep -aq "Open this URL" "$dir/auth.log"; then
    pass "auth login printed the official authorization URL"
  elif grep -aqE 'already|signed in' "$dir/auth.log"; then
    pass "auth login short-circuited for an existing session"
  else
    fail "auth login did not print an authorization URL"
  fi
  if grep -aqi "signed in successfully" "$dir/auth.log"; then
    pass "note: the CLI reports an existing signed-in session"
  fi
  printf '       (authorization URLs are retained only in the test temp dir and are not printed)\n'
}

test_network() {
  printf '\n-- network models --\n'
  if [ "$WITH_NETWORK" -eq 0 ]; then skip "network test disabled by default (use --with-network)"; return 0; fi
  run_sub timeout 90 bharatcode models
  expect_status 0 "bharatcode models exits 0"
  [ -n "$LAST_OUT" ] && pass "models output is non-empty" || fail "models output was empty"
}

test_uninstall_safety() {
  printf '\n-- uninstall safety --\n'
  local dir
  dir="$(new_tmpdir)"
  mkdir -p "$dir/unmarked"
  printf 'keep-me\n' > "$dir/unmarked/keep.txt"
  LAST_OUT="$(BHARATCODE_TERMUX_DATA="$dir/unmarked" bash uninstall.sh 2>&1)"
  LAST_STATUS=$?
  [ "$LAST_STATUS" -ne 0 ] && pass "uninstall refuses an unmarked data directory" || fail "uninstall accepted an unmarked data directory"
  assert_contains "$LAST_OUT" "refusing to remove unmarked directory" "unmarked-directory refusal is explicit"
  [ -f "$dir/unmarked/keep.txt" ] && pass "unmarked directory contents preserved" || fail "unmarked directory contents were deleted"
  [ -x "$PREFIX/bin/bharatcode" ] && pass "managed launcher untouched after refusal" || fail "managed launcher was removed after refusal"
}

test_uninstall_cycle() {
  printf '\n-- uninstall and reinstall --\n'
  if [ "$WITH_UNINSTALL" -eq 0 ]; then skip "uninstall cycle disabled by default (use --with-uninstall)"; return 0; fi
  run_sub bash uninstall.sh
  expect_status 0 "uninstall.sh exits 0"
  [ ! -e "$PREFIX/bin/bharatcode" ] && pass "wrapper removed" || fail "wrapper still present after uninstall"
  [ ! -d "$HOME/.local/share/bharatcode-termux" ] && pass "install directory removed" || fail "install directory still present after uninstall"
  run_sub bash uninstall.sh
  expect_status 0 "second uninstall is a safe no-op"
  assert_contains "$LAST_OUT" "is not installed" "second uninstall reports nothing to remove"
  run_sub bash install.sh
  expect_status 0 "reinstall after uninstall exits 0"
  run_sub timeout 120 bharatcode --version
  expect_status 0 "reinstalled launcher runs"
  assert_eq "$EXPECTED_VERSION" "$(printf '%s' "$LAST_OUT" | sed -n '1p' | tr -d '\r')" "reinstalled version matches the pin"
}

main() {
  parse_args "$@"
  require_device
  printf 'REAL DEVICE TESTS: Termux %s, %s, Android %s\n' \
    "$TERMUX_VERSION" "$(uname -m)" "$(getprop ro.build.version.release 2>/dev/null || echo '?')"
  printf 'Expected BharatCode version: %s\n' "$EXPECTED_VERSION"
  ensure_installed || { printf '\nInstallation failed; aborting device tests.\n' >&2; exit 1; }
  test_version_help
  test_auth_status
  test_exit_and_argv
  test_stdio
  test_clean_shell
  test_update_idempotent
  test_serve_signal
  test_tui
  test_network
  test_auth_launch
  test_uninstall_safety
  test_uninstall_cycle
  summary
}

if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  main "$@"
fi
