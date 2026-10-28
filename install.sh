#!/data/data/com.termux/files/usr/bin/bash
# BharatCode on Termux - independent compatibility installer.
# Not affiliated with or endorsed by BharatCode.
#
# Installs the official BharatCode CLI (pinned version) and runs its native
# linux-arm64 engine on Android/Termux through the Termux glibc runtime.
# No root. No vendor binary is redistributed by this project; artifacts are
# downloaded from the official npm registry and integrity-checked.
set -Eeuo pipefail
umask 077

readonly PROJECT_NAME="bharatcode-termux"
readonly REPO_URL="https://github.com/AadiVIP/bharatcode-termux"
readonly PINNED_VERSION="1.15.46"
readonly MAIN_PKG="bharatcode"
readonly NATIVE_PKG="bharatcode-linux-arm64"
readonly REGISTRY="https://registry.npmjs.org"
readonly MARKER="managed by AadiVIP/bharatcode-termux"
readonly DEFAULT_PREFIX="/data/data/com.termux/files/usr"
readonly MIN_FREE_KB=$((600 * 1024))

# SHA-256 of the official npm tarballs for PINNED_VERSION, recorded after
# verifying the npm registry sha512 integrity metadata on 2026-10-28.
readonly PINNED_MAIN_SHA256="80a8957e9ec279a79523de92b37ded14f1042d8e2bfd66c79514fab8612a7298"
readonly PINNED_NATIVE_SHA256="8a7efe92922b29dc125e847a6574cfb62582a8a84a17df53119d5534f5c3c28d"

VERSION="$PINNED_VERSION"
ALLOW_UNTESTED=0
FORCE=0
PREFIX="${PREFIX:-$DEFAULT_PREFIX}"
BC_DATA="${BHARATCODE_TERMUX_DATA:-${HOME:-}/.local/share/bharatcode-termux}"
TMP_WORK=""
NEW_DIR=""
LOCK_DIR=""

log()  { printf '==> %s\n' "$*" >&2; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
BharatCode on Termux installer (independent compatibility project)

Usage: install.sh [--force] [--version X.Y.Z [--allow-untested]]

Options:
  --force             Reinstall even if the requested version is present.
  --version X.Y.Z     Install a specific BharatCode version. Only
                      $PINNED_VERSION is pinned and tested by this project.
  --allow-untested    With --version, allow a non-pinned version. Its tarballs
                      are verified against npm registry sha512 integrity and the
                      engine is smoke-tested; if it fails, the previous version
                      is restored. Untested versions may not run on Android.
  -h, --help          Show this help.

Environment:
  BHARATCODE_TERMUX_DATA   Install directory
                           (default: \$HOME/.local/share/bharatcode-termux)
  BHARATCODE_TERMUX_GLIBC_DIR
                           Override the glibc runtime directory
                           (default: \$PREFIX/glibc)

Supported: Termux on Android/arm64 (aarch64), bash, curl, tar, coreutils.
The installer never asks for credentials and never starts a login flow.
EOF
}

on_exit() {
  local status=$?
  if [ -n "$TMP_WORK" ] && [ -d "$TMP_WORK" ]; then rm -rf "$TMP_WORK" || true; fi
  if [ -n "$NEW_DIR" ] && [ -d "$NEW_DIR" ]; then rm -rf "$NEW_DIR" || true; fi
  if [ -n "$LOCK_DIR" ] && [ -d "$LOCK_DIR" ]; then rm -rf "$LOCK_DIR" || true; fi
  exit "$status"
}

acquire_lock() {
  LOCK_DIR="$BC_DATA/.install.lock"
  mkdir -p "$BC_DATA"
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    printf '%s\n' "$$" > "$LOCK_DIR/pid"
    trap on_exit EXIT INT TERM HUP
    return 0
  fi
  local old_pid=""
  [ -f "$LOCK_DIR/pid" ] && old_pid="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
  if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
    die "another installer instance is running (pid $old_pid)"
  fi
  warn "removing stale installer lock"
  rm -rf "$LOCK_DIR"
  mkdir "$LOCK_DIR"
  printf '%s\n' "$$" > "$LOCK_DIR/pid"
  trap on_exit EXIT INT TERM HUP
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --force) FORCE=1 ;;
      --version)
        [ $# -ge 2 ] || die "--version requires an argument"
        VERSION="$2"; shift ;;
      --allow-untested) ALLOW_UNTESTED=1 ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown option: $1 (see --help)" ;;
    esac
    shift
  done
  case "$VERSION" in
    ""|*[!0-9A-Za-z.+-]*|*..*) die "invalid version: $VERSION" ;;
  esac
  [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.+-]+)?$ ]] \
    || die "invalid version: $VERSION (expected X.Y.Z, optionally with -pre or +build)"
  [ "${#VERSION}" -le 64 ] || die "version string is too long"
}

assert_safe_data_dir() {
  [ -n "${HOME:-}" ] || die "HOME is unset; cannot choose an install directory"
  case "$BC_DATA" in
    /*) ;;
    *) die "install directory must be an absolute path: $BC_DATA" ;;
  esac
  [ "$BC_DATA" != "/" ] && [ "$BC_DATA" != "$HOME" ] && [ "$BC_DATA" != "$PREFIX" ] \
    || die "refusing to use $BC_DATA as the install directory"
}

require_termux() {
  if [ -z "${TERMUX_VERSION:-}" ] || [[ "${PREFIX:-}" != *com.termux* ]]; then
    die "this installer must run inside Termux on Android. See $REPO_URL"
  fi
}

require_arch() {
  local arch abi
  arch="$(uname -m)"
  case "$arch" in
    aarch64|arm64) ;;
    *) die "unsupported CPU architecture '$arch': the official BharatCode linux-arm64 engine requires 64-bit ARM (arm64-v8a)" ;;
  esac
  if command -v getprop >/dev/null 2>&1; then
    abi="$(getprop ro.product.cpu.abi 2>/dev/null || true)"
    if [ -n "$abi" ] && [[ "$abi" != arm64* ]]; then
      die "unsupported Android ABI '$abi': arm64-v8a is required"
    fi
  fi
}

ensure_tools() {
  local missing=() t
  for t in curl tar sha256sum od stat mktemp install timeout readlink sed grep cut; do
    command -v "$t" >/dev/null 2>&1 || missing+=("$t")
  done
  if [ ${#missing[@]} -gt 0 ]; then
    command -v pkg >/dev/null 2>&1 || die "missing tools (${missing[*]}) and 'pkg' is unavailable"
    log "Installing missing Termux packages for: ${missing[*]}"
    pkg install -y curl tar coreutils sed grep
  fi
  for t in curl tar sha256sum od stat mktemp install timeout readlink sed grep cut; do
    command -v "$t" >/dev/null 2>&1 || die "required tool '$t' is still missing after package installation"
  done
}

ensure_openssl() {
  if ! command -v openssl >/dev/null 2>&1; then
    command -v pkg >/dev/null 2>&1 || die "openssl is required to verify untested versions"
    log "Installing openssl for registry integrity verification"
    pkg install -y openssl
  fi
  command -v openssl >/dev/null 2>&1 || die "openssl installation failed"
}

free_kb() {
  local a s
  a="$(stat -f -c '%a' "$1" 2>/dev/null || echo 0)"
  s="$(stat -f -c '%S' "$1" 2>/dev/null || echo 0)"
  if [ "$a" -gt 0 ] && [ "$s" -gt 0 ]; then
    echo $(( a * s / 1024 ))
    return 0
  fi
  df -Pk "$1" | sed -n '2p' | tr -s ' ' | cut -d' ' -f4
}

check_storage() {
  local avail
  avail="$(free_kb "$BC_DATA")"
  [ -n "$avail" ] || die "could not determine free storage"
  if [ "$avail" -lt "$MIN_FREE_KB" ]; then
    die "not enough free storage in $BC_DATA: $((avail / 1024)) MiB available, $((MIN_FREE_KB / 1024)) MiB required. Free space and re-run."
  fi
  log "Free storage: $((avail / 1024)) MiB (minimum $((MIN_FREE_KB / 1024)) MiB)"
}

glibc_dir() { printf '%s\n' "${BHARATCODE_TERMUX_GLIBC_DIR:-$PREFIX/glibc}"; }
glibc_loader() { printf '%s/lib/ld-linux-aarch64.so.1\n' "$(glibc_dir)"; }

glibc_ok() {
  [ -x "$(glibc_loader)" ] && [ -f "$(glibc_dir)/lib/libc.so.6" ]
}

glibc_version() {
  ( unset LD_PRELOAD LD_LIBRARY_PATH LD_AUDIT LD_DEBUG
    "$(glibc_loader)" --version 2>/dev/null | sed -n '1p' ) || true
}

ensure_glibc() {
  if glibc_ok; then
    log "glibc runtime: $(glibc_version)"
    return 0
  fi
  command -v pkg >/dev/null 2>&1 || die "the Termux glibc runtime is missing and 'pkg' is unavailable"
  log "Installing the Termux glibc runtime (from the Termux-signed glibc repository)"
  pkg install -y glibc-repo
  pkg update -y || warn "package list refresh failed; attempting the install anyway"
  if ! pkg install -y glibc; then
    warn "first glibc install attempt failed; retrying after another package list refresh"
    pkg update -y || true
    pkg install -y glibc || die "could not install the 'glibc' package"
  fi
  # Optional: lets the engine honor Termux shebangs for helper scripts.
  pkg install -y termux-exec-glibc || warn "termux-exec-glibc is unavailable; shebang rewriting inside the engine will be limited"
  glibc_ok || die "glibc installation completed but $(glibc_loader) is still missing"
  local gv
  gv="$(glibc_version)"
  [ -n "$gv" ] || die "the glibc loader exists but does not run; run 'pkg reinstall glibc' and retry"
  log "glibc runtime: $gv"
}

sha256_file() { sha256sum "$1" | cut -d' ' -f1; }

sha512_b64_file() {
  openssl dgst -sha512 -binary "$1" | openssl base64 -A
}

download_verified_sha256() {
  local url="$1" expected="$2" dest="$3" part got
  mkdir -p "$(dirname "$dest")"
  expected="$(printf '%s' "$expected" | tr 'A-F' 'a-f')"
  if [ -f "$dest" ] && [ "$(sha256_file "$dest")" = "$expected" ]; then
    log "Using cached $(basename "$dest")"
    return 0
  fi
  part="${dest}.part"
  rm -f "$part"
  log "Downloading $(basename "$dest")"
  curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 20 --proto '=https' --tlsv1.2 -o "$part" "$url" \
    || { rm -f "$part"; die "download failed: $url"; }
  got="$(sha256_file "$part")"
  if [ "$got" != "$expected" ]; then
    rm -f "$part" "$dest"
    die "integrity check FAILED for $(basename "$dest"): expected sha256 $expected, got $got"
  fi
  mv "$part" "$dest"
  log "Verified sha256: $got"
}

download_verified_sha512() {
  local url="$1" expected="$2" dest="$3" part got
  mkdir -p "$(dirname "$dest")"
  if [ -f "$dest" ] && [ "sha512-$(sha512_b64_file "$dest")" = "$expected" ]; then
    log "Using cached $(basename "$dest")"
    return 0
  fi
  part="${dest}.part"
  rm -f "$part"
  log "Downloading $(basename "$dest")"
  curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 20 --proto '=https' --tlsv1.2 -o "$part" "$url" \
    || { rm -f "$part"; die "download failed: $url"; }
  got="sha512-$(sha512_b64_file "$part")"
  if [ "$got" != "$expected" ]; then
    rm -f "$part" "$dest"
    die "integrity check FAILED for $(basename "$dest"): npm registry reported $expected, got $got"
  fi
  mv "$part" "$dest"
  log "Verified npm registry sha512 integrity"
}

parse_registry_integrity() {
  tr -d '\n' | sed 's/": *"/":"/g' | grep -o '"integrity":"[^"]*"' | head -n1 | cut -d'"' -f4 || true
}

registry_integrity() {
  local pkg="$1" ver="$2" json
  json="$(curl -fsSL --retry 2 --connect-timeout 20 "$REGISTRY/$pkg/$ver")" \
    || die "could not fetch npm metadata for $pkg@$ver"
  printf '%s' "$json" | parse_registry_integrity
}

safe_extract() {
  local tgz="$1" dest="$2" listing entry
  [ -f "$tgz" ] || die "archive not found: $tgz"
  listing="$(tar -tzf "$tgz")" || die "cannot list archive: $tgz"
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    case "$entry" in
      /*|..|../*|*/..|*/../*) die "unsafe path in archive: $entry" ;;
    esac
    case "$entry" in
      package/*) ;;
      *) die "unexpected archive layout (missing package/ prefix): $entry" ;;
    esac
  done <<< "$listing"
  if tar -tvzf "$tgz" | grep -qE '^[lh]'; then
    die "archive contains symlinks or hardlinks, refusing to extract: $tgz"
  fi
  mkdir -p "$dest"
  tar -xzf "$tgz" --strip-components=1 -C "$dest" --no-same-owner
}

assert_pkg_manifest() {
  local file="$1" name="$2" ver="$3"
  [ -f "$file" ] || die "missing package manifest: $file"
  grep -q "\"name\"[[:space:]]*:[[:space:]]*\"$name\"" "$file" \
    || die "manifest $file does not declare package '$name'"
  grep -q "\"version\"[[:space:]]*:[[:space:]]*\"$ver\"" "$file" \
    || die "manifest $file does not declare version '$ver'"
}

verify_elf_arm64() {
  local file="$1" hex
  [ -f "$file" ] || die "engine binary is missing after extraction"
  hex="$(od -An -tx1 -N20 "$file" | tr -d ' \n')"
  [ "${hex:0:8}" = "7f454c46" ] || die "engine is not an ELF binary"
  [ "${hex:8:2}" = "02" ] || die "engine is not a 64-bit ELF binary"
  [ "${hex:10:2}" = "01" ] || die "engine is not little-endian"
  [ "${hex:36:4}" = "b700" ] || die "engine is not an AArch64 (arm64) binary"
  [ "$(wc -c < "$file")" -gt 10000000 ] || die "engine binary is unexpectedly small"
}

engine_cmd_prefix() {
  # Prints the loader invocation prefix; callers append binary and args.
  local gdir
  gdir="$(glibc_dir)"
  if [ -f "$gdir/lib/libtermux-exec.so" ]; then
    printf '%s\n' "env" "-u" "LD_PRELOAD" "-u" "LD_LIBRARY_PATH" "-u" "LD_AUDIT" "-u" "LD_DEBUG" \
      "$(glibc_loader)" "--preload" "$gdir/lib/libtermux-exec.so" "--library-path" "$gdir/lib"
  else
    printf '%s\n' "env" "-u" "LD_PRELOAD" "-u" "LD_LIBRARY_PATH" "-u" "LD_AUDIT" "-u" "LD_DEBUG" \
      "$(glibc_loader)" "--library-path" "$gdir/lib"
  fi
}

smoke_test_binary() {
  local bin="$1" expected="$2" out prefix=()
  mapfile -t prefix < <(engine_cmd_prefix)
  if ! out="$(timeout 120 "${prefix[@]}" "$bin" --version 2>&1)"; then
    printf 'error: engine smoke test failed while running --version:\n%s\n' "$out" >&2
    return 1
  fi
  out="$(printf '%s' "$out" | sed -n '1p' | tr -d '\r')"
  if [ "$out" != "$expected" ]; then
    printf "error: engine smoke test returned '%s', expected '%s'\n" "$out" "$expected" >&2
    return 1
  fi
}

backup_foreign_launcher() {
  local target="$PREFIX/bin/bharatcode" backup_dir="$BC_DATA/backups" backup
  mkdir -p "$backup_dir"
  if [ -e "$target" ] || [ -L "$target" ]; then
    if grep -qF "$MARKER" "$target" 2>/dev/null; then
      return 0
    fi
    backup="$backup_dir/bharatcode.pre-install.$(date +%Y%m%d-%H%M%S).$$"
    log "Backing up existing launcher: $target -> $backup"
    mv "$target" "$backup" || die "could not back up existing launcher $target"
    if [ ! -f "$BC_DATA/state/launcher-backup" ]; then
      printf '%s\n' "$backup" > "$BC_DATA/state/launcher-backup"
      chmod 600 "$BC_DATA/state/launcher-backup"
    fi
  fi
}

write_wrapper() {
  local target="$PREFIX/bin/bharatcode" tmp
  mkdir -p "$PREFIX/bin" || die "cannot create $PREFIX/bin"
  [ -w "$PREFIX/bin" ] || die "no write permission for $PREFIX/bin"
  tmp="$(mktemp "$PREFIX/bin/.bharatcode.XXXXXX")" || die "cannot create a temporary launcher in $PREFIX/bin"
  {
    printf '#!%s/bin/bash\n' "$PREFIX"
    printf '# %s\n' "$MARKER"
    printf '# This wrapper runs the official BharatCode linux-arm64 engine under\n'
    printf '# the Termux glibc runtime. Re-run the installer to regenerate it.\n'
    printf 'set -u\n'
    printf 'BC_DATA=%q\n' "$BC_DATA"
    printf '%s\n' 'BC_ENGINE="$BC_DATA/current/bharatcode"'
    printf 'TERMUX_PREFIX=%q\n' "$PREFIX"
    printf '%s\n' 'GLIBC_DIR="${BHARATCODE_TERMUX_GLIBC_DIR:-$TERMUX_PREFIX/glibc}"'
    printf '%s\n' 'LOADER="$GLIBC_DIR/lib/ld-linux-aarch64.so.1"'
    printf '%s\n' 'if [ ! -x "$LOADER" ]; then'
    printf '%s\n' '  printf "bharatcode: glibc runtime missing at %s\\n" "$LOADER" >&2'
    printf '%s\n' '  printf "Re-run the installer: %s\\n" "https://github.com/AadiVIP/bharatcode-termux" >&2'
    printf '%s\n' '  exit 127'
    printf '%s\n' 'fi'
    printf '%s\n' 'if [ ! -f "$BC_ENGINE" ]; then'
    printf '%s\n' '  printf "bharatcode: engine not installed at %s\\n" "$BC_ENGINE" >&2'
    printf '%s\n' '  printf "Re-run the installer: %s\\n" "https://github.com/AadiVIP/bharatcode-termux" >&2'
    printf '%s\n' '  exit 127'
    printf '%s\n' 'fi'
    printf '%s\n' 'unset LD_PRELOAD LD_LIBRARY_PATH LD_AUDIT LD_DEBUG'
    printf '%s\n' 'if [ -z "${HOME:-}" ]; then HOME="$(dirname "$TERMUX_PREFIX")/home"; export HOME; fi'
    printf '%s\n' 'if [ -z "${TMPDIR:-}" ] || [ ! -d "$TMPDIR" ] || [ ! -w "$TMPDIR" ]; then'
    printf '%s\n' '  TMPDIR="$TERMUX_PREFIX/tmp"'
    printf '%s\n' '  mkdir -p "$TMPDIR" 2>/dev/null || true'
    printf '%s\n' '  export TMPDIR'
    printf '%s\n' 'fi'
    printf '%s\n' 'preload_args=()'
    printf '%s\n' 'if [ -f "$GLIBC_DIR/lib/libtermux-exec.so" ]; then'
    printf '%s\n' '  preload_args=(--preload "$GLIBC_DIR/lib/libtermux-exec.so")'
    printf '%s\n' 'fi'
    printf '%s\n' 'exec "$LOADER" ${preload_args[@]+"${preload_args[@]}"} --library-path "$GLIBC_DIR/lib" "$BC_ENGINE" "$@"'
  } > "$tmp"
  chmod 0755 "$tmp"
  mv -f "$tmp" "$target" || die "could not install launcher at $target"
}

current_version() {
  local link="$BC_DATA/current"
  [ -L "$link" ] || return 1
  readlink "$link" | sed -n 's#^versions/##p'
}

install_version() {
  local ver="$1" main_tgz="$2" native_tgz="$3" downloads="$BC_DATA/downloads"
  local tmp new old_current="" backup_ver="" version_dir="$BC_DATA/versions/$ver"
  mkdir -p "$downloads" "$BC_DATA/versions" "$BC_DATA/state"
  tmp="$(mktemp -d "$downloads/.extract.XXXXXX")"
  TMP_WORK="$tmp"

  safe_extract "$main_tgz" "$tmp/main"
  safe_extract "$native_tgz" "$tmp/native"
  assert_pkg_manifest "$tmp/main/package.json" "$MAIN_PKG" "$ver"
  assert_pkg_manifest "$tmp/native/package.json" "$NATIVE_PKG" "$ver"
  [ -f "$tmp/main/LICENSE" ] || die "official LICENSE file is missing from the main package"
  verify_elf_arm64 "$tmp/native/bin/bharatcode"

  new="$(mktemp -d "$BC_DATA/versions/.new.XXXXXX")"
  NEW_DIR="$new"
  mv "$tmp/native/bin/bharatcode" "$new/bharatcode"
  chmod 0755 "$new/bharatcode"
  mv "$tmp/main/LICENSE" "$new/LICENSE"
  mv "$tmp/main/package.json" "$new/package.json"
  chmod 0644 "$new/LICENSE" "$new/package.json"
  local eng_sha
  eng_sha="$(sha256_file "$new/bharatcode")"
  printf 'version=%s\nengine_sha256=%s\nmain_sha256=%s\nnative_sha256=%s\ninstalled_at=%s\nsource=%s\n' \
    "$ver" "$eng_sha" "${MAIN_EXPECTED:-registry-sha512}" "${NATIVE_EXPECTED:-registry-sha512}" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$REGISTRY" > "$new/metadata.txt"
  chmod 600 "$new/metadata.txt"
  ENGINE_SHA256="$eng_sha"

  if [ -e "$version_dir" ]; then
    backup_ver="${version_dir}.previous.$(date +%s).$$"
    mv "$version_dir" "$backup_ver"
  fi
  mv "$new" "$version_dir"
  NEW_DIR=""

  if [ -L "$BC_DATA/current" ]; then
    old_current="$(readlink "$BC_DATA/current")"
  fi
  ln -sfn "versions/$ver" "$BC_DATA/current.tmp.$$"
  mv -fT "$BC_DATA/current.tmp.$$" "$BC_DATA/current"

  if ! smoke_test_binary "$BC_DATA/current/bharatcode" "$ver"; then
    if [ -n "$old_current" ]; then
      ln -sfn "$old_current" "$BC_DATA/current.tmp.$$"
      mv -fT "$BC_DATA/current.tmp.$$" "$BC_DATA/current"
      warn "rolled back current -> $old_current"
    else
      rm -f "$BC_DATA/current"
    fi
    rm -rf "$version_dir"
    if [ -n "$backup_ver" ] && [ -d "$backup_ver" ]; then
      mv "$backup_ver" "$version_dir"
    fi
    die "the downloaded engine failed its smoke test; installation rolled back"
  fi
  [ -n "$backup_ver" ] && rm -rf "$backup_ver"

  printf 'version=%s\nengine_sha256=%s\nnative_sha256=%s\nmain_sha256=%s\ninstalled_at=%s\nlauncher=%s\n' \
    "$ver" "${ENGINE_SHA256:-unknown}" "${NATIVE_EXPECTED:-registry-sha512}" "${MAIN_EXPECTED:-registry-sha512}" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$PREFIX/bin/bharatcode" > "$BC_DATA/state/install.env"
  chmod 600 "$BC_DATA/state/install.env"
  rm -rf "$tmp"
  TMP_WORK=""
}

print_summary() {
  cat >&2 <<EOF

BharatCode $VERSION is installed.

  Engine:  $BC_DATA/current/bharatcode (official linux-arm64 build)
  Runtime: $(glibc_dir)
  Command: $PREFIX/bin/bharatcode

Next steps (authentication is interactive and is handled by BharatCode itself):
  bharatcode auth login     # open the printed URL, then return to Termux
  bharatcode .              # start the TUI in the current project

Manage:
  Diagnose:  bash diagnose.sh   (or: curl -fsSL $REPO_URL/raw/main/diagnose.sh | bash)
  Update:    see $REPO_URL#updating
  Uninstall: see $REPO_URL#uninstalling

This is an independent compatibility project, not an official BharatCode build.
EOF
}

main() {
  parse_args "$@"
  require_termux
  require_arch
  assert_safe_data_dir

  mkdir -p "$BC_DATA"
  printf '%s\n' "$MARKER" > "$BC_DATA/.managed-by"
  chmod 600 "$BC_DATA/.managed-by"
  acquire_lock
  check_storage
  ensure_tools
  ensure_glibc

  local cur=""
  cur="$(current_version 2>/dev/null || true)"
  if [ "$cur" = "$VERSION" ] && [ "$FORCE" -eq 0 ] && [ -x "$PREFIX/bin/bharatcode" ] \
     && grep -qF "$MARKER" "$PREFIX/bin/bharatcode" 2>/dev/null; then
    if timeout 120 "$PREFIX/bin/bharatcode" --version >/dev/null 2>&1; then
      log "BharatCode $VERSION is already installed and working"
      print_summary
      exit 0
    fi
    warn "existing installation failed its check; repairing"
  fi

  local main_url="$REGISTRY/$MAIN_PKG/-/$MAIN_PKG-$VERSION.tgz"
  local native_url="$REGISTRY/$NATIVE_PKG/-/$NATIVE_PKG-$VERSION.tgz"
  local main_sha="" native_sha="" main_integrity="" native_integrity=""

  if [ "$VERSION" = "$PINNED_VERSION" ]; then
    main_sha="$PINNED_MAIN_SHA256"
    native_sha="$PINNED_NATIVE_SHA256"
    log "Installing pinned, tested version $VERSION"
  else
    [ "$ALLOW_UNTESTED" -eq 1 ] || die "version $VERSION is not pinned/tested by this project. Re-run with --allow-untested to try it (rollback on failure)."
    ensure_openssl
    main_integrity="$(registry_integrity "$MAIN_PKG" "$VERSION")"
    native_integrity="$(registry_integrity "$NATIVE_PKG" "$VERSION")"
    [ -n "$main_integrity" ] && [ -n "$native_integrity" ] || die "npm registry metadata is missing integrity data for $VERSION"
    log "Installing untested version $VERSION (registry integrity verification enabled)"
  fi

  local main_tgz="$BC_DATA/downloads/$MAIN_PKG-$VERSION.tgz"
  local native_tgz="$BC_DATA/downloads/$NATIVE_PKG-$VERSION.tgz"
  if [ "$VERSION" = "$PINNED_VERSION" ]; then
    download_verified_sha256 "$main_url" "$main_sha" "$main_tgz"
    download_verified_sha256 "$native_url" "$native_sha" "$native_tgz"
    MAIN_EXPECTED="$main_sha"
    NATIVE_EXPECTED="$native_sha"
  else
    download_verified_sha512 "$main_url" "$main_integrity" "$main_tgz"
    download_verified_sha512 "$native_url" "$native_integrity" "$native_tgz"
    MAIN_EXPECTED="$main_integrity"
    NATIVE_EXPECTED="$native_integrity"
  fi

  install_version "$VERSION" "$main_tgz" "$native_tgz"
  backup_foreign_launcher
  write_wrapper

  log "Verifying the installed launcher"
  local out
  out="$(timeout 120 "$PREFIX/bin/bharatcode" --version 2>&1)" \
    || die "the installed 'bharatcode' launcher failed to run:
$out"
  [ "$(printf '%s' "$out" | sed -n '1p' | tr -d '\r')" = "$VERSION" ] \
    || die "launcher reported '$out', expected '$VERSION'"

  rm -f "$main_tgz" "$native_tgz"
  log "Removed cached tarballs to save space"
  print_summary
}

if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  main "$@"
fi
