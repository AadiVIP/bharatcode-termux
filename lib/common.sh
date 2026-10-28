#!/data/data/com.termux/files/usr/bin/bash
# Shared helpers for the BharatCode-on-Termux test suite.
# Sourced by tests/*.sh; not used by the production scripts, which stay
# self-contained so that 'curl | bash' installation remains a single file.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TESTS_DIR="$REPO_ROOT/tests"

PASS=0
FAIL=0
SKIP=0
TMP_DIRS=()

pass() { PASS=$((PASS + 1)); printf '[pass] %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf '[FAIL] %s\n' "$*" >&2; }
skip() { SKIP=$((SKIP + 1)); printf '[skip] %s\n' "$*"; }

assert_eq() {
  local expected="$1" actual="$2" msg="$3"
  if [ "$expected" = "$actual" ]; then
    pass "$msg"
  else
    fail "$msg (expected [$expected], got [$actual])"
  fi
}

assert_ne() {
  local unexpected="$1" actual="$2" msg="$3"
  if [ "$unexpected" != "$actual" ]; then
    pass "$msg"
  else
    fail "$msg (did not expect [$actual])"
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" msg="$3"
  case "$haystack" in
    *"$needle"*) pass "$msg" ;;
    *) fail "$msg (missing [$needle])" ;;
  esac
}

assert_not_contains() {
  local haystack="$1" needle="$2" msg="$3"
  case "$haystack" in
    *"$needle"*) fail "$msg (unexpectedly found [$needle])" ;;
    *) pass "$msg" ;;
  esac
}

assert_file() { [ -f "$1" ] && pass "${2:-file exists: $1}" || fail "${2:-file missing: $1}"; }
assert_dir()  { [ -d "$1" ] && pass "${2:-directory exists: $1}" || fail "${2:-directory missing: $1}"; }
assert_exec() { [ -x "$1" ] && pass "${2:-executable: $1}" || fail "${2:-not executable: $1}"; }

new_tmpdir() {
  local d
  d="$(mktemp -d "${TMPDIR:-/tmp}/bharatcode-test.XXXXXX")" || { printf 'cannot create temp dir\n' >&2; exit 1; }
  TMP_DIRS+=("$d")
  printf '%s\n' "$d"
}

cleanup_tmpdirs() {
  local d
  for d in "${TMP_DIRS[@]:-}"; do
    [ -n "$d" ] && [ -d "$d" ] && rm -rf "$d"
  done
  TMP_DIRS=()
}

sanitize_log() {
  sed -E \
    -e 's#https://auth\.bharatcode\.ai/[^[:space:]]+#<AUTH_URL_REDACTED>#g' \
    -e 's#https://registry\.npmjs\.org/[^[:space:]]+#<REGISTRY_URL>#g' \
    -e 's/(token|secret|password|code_challenge|state)=[^&[:space:]]+/\1=<REDACTED>/Ig' \
    -e "s#$HOME#<HOME>#g"
}

summary() {
  printf '\n%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
  [ "$FAIL" -eq 0 ]
}
