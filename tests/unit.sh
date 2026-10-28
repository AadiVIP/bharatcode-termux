#!/data/data/com.termux/files/usr/bin/bash
# Mocked/unit tests for the BharatCode-on-Termux scripts.
# These run without Android, glibc, or network access.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
# shellcheck source=../lib/common.sh
source lib/common.sh
trap cleanup_tmpdirs EXIT

SAVED_UMASK="$(umask)"
# shellcheck source=../install.sh
source install.sh
set +e +E
umask "$SAVED_UMASK"

LAST_OUT=""
LAST_STATUS=0
run_sub() { LAST_OUT="$("$@" 2>&1)"; LAST_STATUS=$?; }
run_env() {
  local -a assigns=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do assigns+=("$1"); shift; done
  [ "$#" -gt 0 ] && shift
  LAST_OUT="$( ( if [ "${#assigns[@]}" -gt 0 ]; then export "${assigns[@]}"; fi; "$@" ) 2>&1 )"
  LAST_STATUS=$?
}
expect_status() {
  local expected="$1" msg="$2"
  if [ "$LAST_STATUS" -eq "$expected" ]; then
    pass "$msg"
  else
    fail "$msg (exit $LAST_STATUS, expected $expected; output: $(printf '%s' "$LAST_OUT" | head -c 300))"
  fi
}
expect_failure() {
  local msg="$1"
  if [ "$LAST_STATUS" -ne 0 ]; then
    pass "$msg (exit $LAST_STATUS)"
  else
    fail "$msg (unexpected success; output: $(printf '%s' "$LAST_OUT" | head -c 300))"
  fi
}

make_fake_curl() {
  local dir="$1"
  mkdir -p "$dir"
  {
    printf '#!%s\n' "$BASH"
    cat <<'EOS'
set -u
dest=""
url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) dest="$2"; shift 2 ;;
    --retry|--retry-delay|--connect-timeout|--proto) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
printf '%s\n' "$url" >> "${FAKE_CURL_LOG:-/dev/null}"
case "${FAKE_CURL_MODE:-copy}" in
  copy)
    if [ -n "$dest" ]; then cp "$FAKE_CURL_PAYLOAD" "$dest"; else cat "$FAKE_CURL_PAYLOAD"; fi
    ;;
  corrupt) printf 'corrupted-bytes' > "$dest" ;;
  partial) printf 'partial-bytes' > "$dest"; exit 18 ;;
  fail) exit 22 ;;
  *) exit 99 ;;
esac
EOS
  } > "$dir/curl"
  chmod +x "$dir/curl"
}

make_elf() {
  local file="$1" cls="${2:-2}" dat="${3:-1}" machine="${4:-b700}" size="${5:-11000000}"
  python3 - "$file" "$cls" "$dat" "$machine" "$size" <<'PY'
import sys
path, cls, dat, machine, size = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4], int(sys.argv[5])
with open(path, "wb") as f:
    f.truncate(size)
h = bytearray(20)
h[0:4] = b"\x7fELF"
h[4] = cls
h[5] = dat
h[6] = 1
h[18:20] = bytes.fromhex(machine)
with open(path, "r+b") as f:
    f.write(h)
PY
}

make_install_tarballs() {
  local main="$1" native="$2" version="${3:-9.9.9}"
  python3 - "$main" "$native" "$version" <<'PY'
import io
import json
import sys
import tarfile

main, native, version = sys.argv[1], sys.argv[2], sys.argv[3]

def add(tf, name, data, mode=0o644):
    ti = tarfile.TarInfo(name)
    ti.size = len(data)
    ti.mode = mode
    tf.addfile(ti, io.BytesIO(data))

with tarfile.open(main, "w:gz") as tf:
    add(tf, "package/package.json", json.dumps({"name": "bharatcode", "version": version}).encode())
    add(tf, "package/LICENSE", b"MIT License\n")

blob = bytearray(11_000_000)
blob[0:4] = b"\x7fELF"
blob[4] = 2
blob[5] = 1
blob[18:20] = bytes.fromhex("b700")
with tarfile.open(native, "w:gz") as tf:
    add(tf, "package/package.json", json.dumps({"name": "bharatcode-linux-arm64", "version": version}).encode())
    add(tf, "package/bin/bharatcode", bytes(blob), mode=0o755)
PY
}

printf '== unit: archive extraction ==\n'
t="$(new_tmpdir)"
mkdir -p "$t/src/package/bin"
printf '{"name":"bharatcode","version":"1.2.3"}\n' > "$t/src/package/package.json"
printf 'MIT\n' > "$t/src/package/LICENSE"
printf '#!/bin/sh\necho hi\n' > "$t/src/package/bin/tool"
tar -czf "$t/valid.tgz" -C "$t/src" package
run_sub safe_extract "$t/valid.tgz" "$t/out"
expect_status 0 "valid npm-style archive extracts"
assert_file "$t/out/package.json" "extracted package.json"
assert_file "$t/out/bin/tool" "extracted nested file"

python3 - "$t/traversal.tgz" <<'PY'
import io, sys, tarfile
with tarfile.open(sys.argv[1], "w:gz") as tf:
    ti = tarfile.TarInfo("package/../evil.txt")
    data = b"x"
    ti.size = len(data)
    tf.addfile(ti, io.BytesIO(data))
PY
run_sub safe_extract "$t/traversal.tgz" "$t/out-trav"
expect_failure "archive with .. traversal is rejected"
assert_contains "$LAST_OUT" "unsafe path" "traversal error is explicit"

python3 - "$t/absolute.tgz" <<'PY'
import io, sys, tarfile
with tarfile.open(sys.argv[1], "w:gz") as tf:
    ti = tarfile.TarInfo("/etc/evil")
    ti.size = 1
    tf.addfile(ti, io.BytesIO(b"x"))
PY
run_sub safe_extract "$t/absolute.tgz" "$t/out-abs"
expect_failure "archive with an absolute path is rejected"
assert_contains "$LAST_OUT" "unsafe path" "absolute-path error is explicit"

python3 - "$t/layout.tgz" <<'PY'
import io, sys, tarfile
with tarfile.open(sys.argv[1], "w:gz") as tf:
    ti = tarfile.TarInfo("foo/bar")
    ti.size = 1
    tf.addfile(ti, io.BytesIO(b"x"))
PY
run_sub safe_extract "$t/layout.tgz" "$t/out-layout"
expect_failure "archive without package/ prefix is rejected"
assert_contains "$LAST_OUT" "unexpected archive layout" "layout error is explicit"

python3 - "$t/symlink.tgz" <<'PY'
import sys, tarfile
with tarfile.open(sys.argv[1], "w:gz") as tf:
    ti = tarfile.TarInfo("package/link")
    ti.type = tarfile.SYMTYPE
    ti.linkname = "/etc/passwd"
    ti.size = 0
    tf.addfile(ti)
PY
run_sub safe_extract "$t/symlink.tgz" "$t/out-link"
expect_failure "archive with a symlink is rejected"
assert_contains "$LAST_OUT" "symlinks or hardlinks" "symlink error is explicit"

printf '\n== unit: manifests and ELF validation ==\n'
printf '{"name": "bharatcode", "version": "1.2.3"}\n' > "$t/pkg.json"
run_sub assert_pkg_manifest "$t/pkg.json" bharatcode 1.2.3
expect_status 0 "valid package manifest passes"
run_sub assert_pkg_manifest "$t/pkg.json" bharatcode 9.9.9
expect_failure "wrong version in manifest is rejected"
assert_contains "$LAST_OUT" "does not declare version" "version mismatch message"

make_elf "$t/good.elf"
run_sub verify_elf_arm64 "$t/good.elf"
expect_status 0 "valid AArch64 little-endian ELF passes"
make_elf "$t/bad-arch.elf" 2 1 3e00
run_sub verify_elf_arm64 "$t/bad-arch.elf"
expect_failure "x86_64 ELF is rejected"
assert_contains "$LAST_OUT" "AArch64" "arch error message"
make_elf "$t/bad-class.elf" 1 1 b700
run_sub verify_elf_arm64 "$t/bad-class.elf"
expect_failure "32-bit ELF is rejected"
make_elf "$t/bad-endian.elf" 2 2 b700
run_sub verify_elf_arm64 "$t/bad-endian.elf"
expect_failure "big-endian ELF is rejected"
make_elf "$t/small.elf" 2 1 b700 1024
run_sub verify_elf_arm64 "$t/small.elf"
expect_failure "suspiciously small engine is rejected"
assert_contains "$LAST_OUT" "unexpectedly small" "size error message"

printf '\n== unit: registry metadata parsing ==\n'
compact='{"name":"bharatcode","dist":{"integrity":"sha512-AAA==","shasum":"bb","tarball":"https://example.invalid/x"}}'
LAST_OUT="$(printf '%s' "$compact" | parse_registry_integrity)"
assert_eq "sha512-AAA==" "$LAST_OUT" "compact JSON integrity parsed"
pretty='{
  "name": "bharatcode",
  "dist": {
    "integrity": "sha512-BBB==",
    "shasum": "cc"
  },
  "other": {"integrity": "sha512-WRONG=="}
}'
LAST_OUT="$(printf '%s' "$pretty" | parse_registry_integrity)"
assert_eq "sha512-BBB==" "$LAST_OUT" "pretty JSON integrity parsed (first match only)"
LAST_OUT="$(printf '%s' '{"name":"x"}' | parse_registry_integrity)"
assert_eq "" "$LAST_OUT" "missing integrity yields empty output"

t2="$(new_tmpdir)"
make_fake_curl "$t2/bin"
printf '%s\n' "$pretty" > "$t2/meta.json"
run_env "PATH=$t2/bin:$PATH" "FAKE_CURL_MODE=copy" "FAKE_CURL_PAYLOAD=$t2/meta.json" -- registry_integrity bharatcode 1.2.3
expect_status 0 "registry_integrity fetches and parses metadata"
assert_eq "sha512-BBB==" "$LAST_OUT" "registry_integrity returns registry integrity"

printf '\n== unit: downloads and integrity failures ==\n'
t3="$(new_tmpdir)"
make_fake_curl "$t3/bin"
printf 'payload-data\n' > "$t3/payload"
expected_sha="$(sha256sum "$t3/payload" | cut -d' ' -f1)"
run_env "PATH=$t3/bin:$PATH" "FAKE_CURL_MODE=copy" "FAKE_CURL_PAYLOAD=$t3/payload" \
  -- download_verified_sha256 "https://example.invalid/a.tgz" "$expected_sha" "$t3/dest.tgz"
expect_status 0 "sha256-verified download succeeds"
assert_file "$t3/dest.tgz" "downloaded file created"
assert_eq "$expected_sha" "$(sha256sum "$t3/dest.tgz" | cut -d' ' -f1)" "downloaded bytes match expected hash"

rm -f "$t3/payload"
run_env "PATH=$t3/bin:$PATH" "FAKE_CURL_MODE=corrupt" "FAKE_CURL_PAYLOAD=/nonexistent" \
  -- download_verified_sha256 "https://example.invalid/a.tgz" "$expected_sha" "$t3/dest.tgz"
expect_status 0 "valid cached tarball is reused without downloading"
assert_contains "$LAST_OUT" "Using cached" "cache reuse is logged"

run_env "PATH=$t3/bin:$PATH" "FAKE_CURL_MODE=corrupt" "FAKE_CURL_PAYLOAD=/nonexistent" \
  -- download_verified_sha256 "https://example.invalid/b.tgz" "$expected_sha" "$t3/corrupt.tgz"
expect_failure "corrupt download is rejected"
assert_contains "$LAST_OUT" "integrity check FAILED" "integrity failure message"
[ -e "$t3/corrupt.tgz" ] && fail "corrupt file was kept at destination" || pass "corrupt file removed"
[ -e "$t3/corrupt.tgz.part" ] && fail "corrupt .part file was kept" || pass "corrupt .part removed"

run_env "PATH=$t3/bin:$PATH" "FAKE_CURL_MODE=partial" "FAKE_CURL_PAYLOAD=/nonexistent" \
  -- download_verified_sha256 "https://example.invalid/c.tgz" "$expected_sha" "$t3/partial.tgz"
expect_failure "interrupted download (curl exit 18) is rejected"
[ -e "$t3/partial.tgz.part" ] && fail "interrupted .part file was kept" || pass "interrupted .part removed"
assert_contains "$LAST_OUT" "download failed" "interrupted download message"

if command -v openssl >/dev/null 2>&1; then
printf 'payload\n' > "$t3/payload512"
expected512="sha512-$(openssl dgst -sha512 -binary "$t3/payload512" | openssl base64 -A)"
run_env "PATH=$t3/bin:$PATH" "FAKE_CURL_MODE=copy" "FAKE_CURL_PAYLOAD=$t3/payload512" \
  -- download_verified_sha512 "https://example.invalid/d.tgz" "$expected512" "$t3/dest512.tgz"
expect_status 0 "sha512-verified download succeeds"
assert_eq "$expected512" "sha512-$(openssl dgst -sha512 -binary "$t3/dest512.tgz" | openssl base64 -A)" "downloaded bytes match registry integrity"
else
  skip "openssl unavailable; sha512 verification test skipped"
fi

printf '\n== unit: platform and storage guards ==\n'
t4="$(new_tmpdir)"
mkdir -p "$t4/bin"
printf '#!%s\nprintf "x86_64\\n"\n' "$BASH" > "$t4/bin/uname"
printf '#!%s\nprintf "arm64-v8a\\n"\n' "$BASH" > "$t4/bin/getprop"
chmod +x "$t4/bin/uname" "$t4/bin/getprop"
run_env "PATH=$t4/bin:$PATH" -- require_arch
expect_failure "unsupported CPU architecture is rejected"
assert_contains "$LAST_OUT" "unsupported CPU architecture" "arch guard message"
printf '#!%s\nprintf "aarch64\\n"\n' "$BASH" > "$t4/bin/uname"
printf '#!%s\nprintf "armeabi-v7a\\n"\n' "$BASH" > "$t4/bin/getprop"
chmod +x "$t4/bin/uname" "$t4/bin/getprop"
run_env "PATH=$t4/bin:$PATH" -- require_arch
expect_failure "unsupported Android ABI is rejected"
assert_contains "$LAST_OUT" "unsupported Android ABI" "ABI guard message"

run_env "TERMUX_VERSION=" "PREFIX=/opt" -- require_termux
expect_failure "non-Termux environment is rejected"
assert_contains "$LAST_OUT" "must run inside Termux" "Termux guard message"

run_sub bash -c '
  source "$1" 2>/dev/null
  set +e +E
  free_kb() { echo 1024; }
  BC_DATA=/tmp
  check_storage
' _ "$REPO_ROOT/install.sh"
expect_failure "insufficient storage is rejected"
assert_contains "$LAST_OUT" "not enough free storage" "storage guard message"

run_sub bash -c '
  source "$1" 2>/dev/null
  set +e +E
  free_kb() { echo $(( 700 * 1024 )); }
  BC_DATA=/tmp
  check_storage
' _ "$REPO_ROOT/install.sh"
expect_status 0 "sufficient storage passes"

avail="$(free_kb "${TMPDIR:-/tmp}")"
case "$avail" in
  ''|*[!0-9]*) fail "free_kb returned non-numeric output [$avail]" ;;
  *) pass "free_kb returns a numeric value" ;;
esac

printf '\n== unit: tool detection ==\n'
t5="$(new_tmpdir)"
printf '#!%s\nprintf "%%s\\n" "pkg $*" >> "%s/pkg.log"\nexit 0\n' "$BASH" "$t5" > "$t5/pkg"
chmod +x "$t5/pkg"
run_env "PATH=$t5" -- ensure_tools
expect_failure "missing tools with an ineffective pkg call fail clearly"
assert_contains "$LAST_OUT" "is still missing after package installation" "missing tool message"

printf '\n== unit: wrapper, backup, current version ==\n'
t6="$(new_tmpdir)"
PREFIX="$t6/prefix"
BC_DATA="$t6/data dir"
mkdir -p "$PREFIX/bin"
run_sub write_wrapper
expect_status 0 "wrapper is generated"
assert_file "$PREFIX/bin/bharatcode" "wrapper exists"
assert_exec "$PREFIX/bin/bharatcode" "wrapper is executable"
run_sub bash -n "$PREFIX/bin/bharatcode"
expect_status 0 "generated wrapper passes bash -n"
run_sub grep -F "$MARKER" "$PREFIX/bin/bharatcode"
expect_status 0 "wrapper contains the management marker"
run_sub grep -qF -- '--library-path' "$PREFIX/bin/bharatcode"
expect_status 0 "wrapper invokes the glibc loader with a library path"
run_sub grep -F 'exec "$LOADER"' "$PREFIX/bin/bharatcode"
expect_status 0 "wrapper execs the loader (signal and exit-code transparency)"
run_sub grep -F 'BC_DATA=' "$PREFIX/bin/bharatcode"
expect_status 0 "wrapper bakes the install directory"

t7="$(new_tmpdir)"
PREFIX="$t7/prefix"
BC_DATA="$t7/data"
mkdir -p "$PREFIX/bin" "$BC_DATA/state"
printf '#!/bin/sh\necho old\n' > "$PREFIX/bin/bharatcode"
run_sub backup_foreign_launcher
expect_status 0 "existing launcher is backed up"
[ -e "$PREFIX/bin/bharatcode" ] && fail "foreign launcher still in place" || pass "foreign launcher moved aside"
assert_file "$BC_DATA/state/launcher-backup" "backup path recorded"
backup_path="$(cat "$BC_DATA/state/launcher-backup")"
assert_file "$backup_path" "backup file exists"
assert_eq "#!/bin/sh" "$(head -n1 "$backup_path")" "backup content preserved"
printf '# %s\n' "$MARKER" > "$PREFIX/bin/bharatcode"
run_sub backup_foreign_launcher
expect_status 0 "managed launcher is not backed up again"
assert_eq "1" "$(find "$BC_DATA/backups" -type f | wc -l | tr -d ' ')" "only one backup was made"

BC_DATA="$t6/data"
mkdir -p "$BC_DATA/versions/1.2.3"
ln -s versions/1.2.3 "$BC_DATA/current"
run_sub current_version
expect_status 0 "current_version succeeds for a symlinked install"
assert_eq "1.2.3" "$LAST_OUT" "current_version reads the symlink target"
rm -f "$BC_DATA/current"
run_sub current_version
expect_failure "current_version fails when the symlink is absent"

printf '\n== unit: install and rollback ==\n'
t8="$(new_tmpdir)"
make_install_tarballs "$t8/main.tgz" "$t8/native.tgz" 9.9.9
BC_DATA="$t8/data"
PREFIX="$t8/prefix"
mkdir -p "$BC_DATA/versions/9.9.9" "$PREFIX/bin"
printf 'old-engine\n' > "$BC_DATA/versions/9.9.9/bharatcode"
printf 'old\n' > "$BC_DATA/versions/9.9.9/old-marker"
ln -s versions/9.9.9 "$BC_DATA/current"
(
  smoke_test_binary() { return 1; }
  install_version 9.9.9 "$t8/main.tgz" "$t8/native.tgz"
) > "$t8/rollback.log" 2>&1
status=$?
[ "$status" -ne 0 ] && pass "smoke-test failure aborts the install (exit $status)" || fail "smoke-test failure did not abort the install"
assert_contains "$(cat "$t8/rollback.log")" "failed its smoke test" "rollback message is explicit"
assert_eq "versions/9.9.9" "$(readlink "$BC_DATA/current" 2>/dev/null || echo none)" "current symlink rolled back"
assert_file "$BC_DATA/versions/9.9.9/old-marker" "previous version directory restored"
assert_eq "old-engine" "$(cat "$BC_DATA/versions/9.9.9/bharatcode")" "previous engine content preserved"
leftovers="$(find "$BC_DATA/versions" -maxdepth 1 \( -name '.new.*' -o -name '*.previous.*' \) | wc -l | tr -d ' ')"
assert_eq "0" "$leftovers" "no partial version directories remain"

BC_DATA="$t8/data2"
PREFIX="$t8/prefix2"
mkdir -p "$BC_DATA" "$PREFIX/bin"
(
  smoke_test_binary() { return 0; }
  install_version 9.9.9 "$t8/main.tgz" "$t8/native.tgz"
) > "$t8/success.log" 2>&1
status=$?
[ "$status" -eq 0 ] && pass "successful install completes" || { fail "successful install failed"; sed -n '1,20p' "$t8/success.log" >&2; }
assert_eq "versions/9.9.9" "$(readlink "$BC_DATA/current" 2>/dev/null || echo none)" "current symlink points to the installed version"
assert_exec "$BC_DATA/current/bharatcode" "engine installed and executable"
assert_file "$BC_DATA/current/LICENSE" "official LICENSE installed"
assert_file "$BC_DATA/current/metadata.txt" "install metadata written"
assert_file "$BC_DATA/state/install.env" "install state written"
assert_eq "9.9.9" "$(sed -n 's/^version=//p' "$BC_DATA/state/install.env")" "state records the installed version"
recorded_sha="$(sed -n 's/^engine_sha256=//p' "$BC_DATA/state/install.env")"
actual_sha="$(sha256sum "$BC_DATA/current/bharatcode" | cut -d' ' -f1)"
assert_eq "$actual_sha" "$recorded_sha" "state records the engine SHA-256"
assert_contains "$(cat "$BC_DATA/current/metadata.txt")" "engine_sha256=$actual_sha" "metadata records the engine SHA-256"

printf '\n== unit: argument parsing ==\n'
run_sub bash -c '
  source "$1" 2>/dev/null
  set +e +E
  VERSION=1.15.46 ALLOW_UNTESTED=0 FORCE=0
  parse_args --force --version 1.2.3 --allow-untested
  printf "%s %s %s\n" "$VERSION" "$FORCE" "$ALLOW_UNTESTED"
' _ "$REPO_ROOT/install.sh"
expect_status 0 "valid installer arguments parse"
assert_eq "1.2.3 1 1" "$LAST_OUT" "parsed values are applied"
run_sub bash -c '
  source "$1" 2>/dev/null
  set +e +E
  parse_args --version
' _ "$REPO_ROOT/install.sh"
expect_failure "--version without a value is rejected"
run_sub bash -c '
  source "$1" 2>/dev/null
  set +e +E
  parse_args --bogus
' _ "$REPO_ROOT/install.sh"
expect_failure "unknown installer option is rejected"
assert_contains "$LAST_OUT" "unknown option" "unknown option message"
run_sub bash -c '
  source "$1" 2>/dev/null
  set +e +E
  parse_args "1.2.3;rm"
' _ "$REPO_ROOT/install.sh"
expect_failure "unsafe version string is rejected"
run_sub bash -c '
  source "$1" 2>/dev/null
  set +e +E
  parse_args --version ..
' _ "$REPO_ROOT/install.sh"
expect_failure "path-traversal version is rejected"
assert_contains "$LAST_OUT" "invalid version" "path-traversal error is explicit"
run_sub bash -c '
  source "$1" 2>/dev/null
  set +e +E
  parse_args --version 2.0.0-beta.1+build.5
  printf "%s\n" "$VERSION"
' _ "$REPO_ROOT/install.sh"
expect_status 0 "semver prerelease/build version is accepted"
assert_eq "2.0.0-beta.1+build.5" "$LAST_OUT" "prerelease version preserved"

printf '\n== unit: repository and CLI surface ==\n'
for f in install.sh uninstall.sh diagnose.sh update.sh lib/common.sh; do
  run_sub bash -n "$REPO_ROOT/$f"
  expect_status 0 "bash -n: $f"
done
for f in install.sh uninstall.sh diagnose.sh update.sh; do
  assert_exec "$REPO_ROOT/$f" "executable bit: $f"
done
run_sub bash "$REPO_ROOT/install.sh" --help
expect_status 0 "install.sh --help exits 0"
assert_contains "$LAST_OUT" "Usage:" "install.sh --help prints usage"
run_sub bash "$REPO_ROOT/install.sh" --bogus
expect_status 1 "install.sh rejects unknown options"
run_sub bash "$REPO_ROOT/uninstall.sh" --help
expect_status 0 "uninstall.sh --help exits 0"
run_sub bash "$REPO_ROOT/diagnose.sh" --help
expect_status 0 "diagnose.sh --help exits 0"
run_sub bash "$REPO_ROOT/update.sh" --help
expect_status 0 "update.sh --help exits 0"
run_sub grep -qF "$MARKER" "$REPO_ROOT/install.sh"
expect_status 0 "installer embeds the marker"
run_sub grep -qF "$MARKER" "$REPO_ROOT/uninstall.sh"
expect_status 0 "uninstaller embeds the marker"
run_sub grep -qF "$MARKER" "$REPO_ROOT/diagnose.sh"
expect_status 0 "diagnostics embed the marker"
for f in install.sh uninstall.sh diagnose.sh update.sh; do
  run_sub grep -qF "https://github.com/AadiVIP/bharatcode-termux" "$REPO_ROOT/$f"
  expect_status 0 "repository URL: $f"
done
run_sub grep -qE '^readonly PINNED_VERSION="1\.15\.46"$' "$REPO_ROOT/install.sh"
expect_status 0 "installer pins the tested version"
run_sub grep -qE '^readonly PINNED_MAIN_SHA256="[0-9a-f]{64}"$' "$REPO_ROOT/install.sh"
expect_status 0 "installer pins the main-package SHA-256"
run_sub grep -qE '^readonly PINNED_NATIVE_SHA256="[0-9a-f]{64}"$' "$REPO_ROOT/install.sh"
expect_status 0 "installer pins the native-package SHA-256"
run_sub grep -qF "scripts/bharatcode.mjs" "$REPO_ROOT/install.sh"
expect_failure "installer does not install the npm JS launcher"
run_sub grep -qF "assert_safe_data_dir" "$REPO_ROOT/install.sh"
expect_status 0 "installer guards the install directory"

summary
