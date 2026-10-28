#!/data/data/com.termux/files/usr/bin/bash
# Test entry point. Without arguments, runs mocked/unit tests only (CI-safe,
# no Android device, no network). With --device, also runs the real on-device
# suite (which may install/repair BharatCode).
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

MODE=unit
DEVICE_ARGS=()

usage() {
  cat <<EOF
Usage: tests/run-tests.sh [--device [device-test options]]

Without --device: mocked/unit tests only. Safe for CI and any Linux shell.
With --device:    real Termux/Android end-to-end tests; see
                  tests/device.sh --help for options (--with-uninstall,
                  --with-auth, --with-network, --skip-tui).
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --device) MODE=device; shift; DEVICE_ARGS=("$@"); break ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'error: unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

printf '=== Mocked/unit tests (no Android device required) ===\n'
bash tests/unit.sh
unit_status=$?

device_status=0
if [ "$MODE" = "device" ]; then
  printf '\n=== REAL DEVICE tests (Android/Termux) ===\n'
  bash tests/device.sh "${DEVICE_ARGS[@]}"
  device_status=$?
fi

printf '\n=== Result ===\n'
if [ "$unit_status" -eq 0 ] && [ "$device_status" -eq 0 ]; then
  if [ "$MODE" = "device" ]; then
    printf 'PASS: unit tests and real-device tests succeeded.\n'
  else
    printf 'PASS: unit tests succeeded (device suite not requested).\n'
  fi
  exit 0
fi
printf 'FAIL: unit exit %d, device exit %d.\n' "$unit_status" "$device_status"
exit 1
