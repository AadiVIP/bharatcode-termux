# Troubleshooting

Start with diagnostics:

```bash
curl -fsSL https://raw.githubusercontent.com/AadiVIP/bharatcode-termux/main/diagnose.sh | bash
```

It is read-only and prints `[ ok ]`, `[warn]`, and `[FAIL]` checks with a non-zero exit
status on critical failures.

## Installation

### `npm error code EBADPLATFORM`

Expected. The official npm package only allows desktop platforms, while Termux reports
`os: android`, `cpu: arm64`. Use this repository's installer; it downloads the official
native tarball directly after verifying integrity. Do not edit npm's platform fields or
rename the OS.

### `this installer must run inside Termux on Android`

Run the installer inside Termux (not adb, not a generic Linux shell, not a desktop
terminal) and make sure Termux's environment is intact (`echo $TERMUX_VERSION`, `echo $PREFIX`).
If `TERMUX_VERSION` is empty in a script, run the installer from an interactive Termux
session.

### `unsupported CPU architecture` / `unsupported Android ABI`

The official engine is `arm64-v8a` only. Check with:

```bash
uname -m            # expect aarch64
getprop ro.product.cpu.abi   # expect arm64-v8a
```

A 32-bit Termux installation or an x86 emulator cannot run the official native engine.

### `not enough free storage`

The installer requires about 600 MiB because it downloads tarballs, extracts them, and
keeps the previous version during an upgrade. Free space and rerun:

```bash
df -h "$HOME"
```

### glibc installation fails (`pkg install glibc`)

- Refresh package lists: `pkg update -y`, then `pkg install -y glibc`.
- Make sure `glibc-repo` is installed: `pkg install -y glibc-repo`.
- Check network/DNS: `pkg update` must reach the Termux mirrors.
- Verify the loader afterward:
  `$PREFIX/glibc/lib/ld-linux-aarch64.so.1 --version`.
- If the package is half-installed: `pkg reinstall glibc`.

Do not mix glibc packages from other projects or copy random `libc.so.6` files into the
Termux prefix.

### `curl` download failed or integrity check failed

The installer rejects a tarball whose SHA-256 does not match the pin. This can be a
network proxy/captive portal, a truncated download, or an unexpected registry change. Rerun
the installer; verified partial caches are reused only when their hash matches. If it
persists, run `tests/verify-pins.sh` from a clone to confirm the published pins against
the registry.

### `another installer instance is running`

A lock directory exists and its PID is alive. Wait for the other installer to finish. If
it crashed, the next run removes the stale lock automatically (a warning is printed).

## Runtime

### `libc.so: invalid ELF header` or `version 'LIBC' not found`

Termux's Bionic `LD_PRELOAD` reached the glibc loader. The installed wrapper unsets
`LD_PRELOAD`, `LD_LIBRARY_PATH`, `LD_AUDIT`, and `LD_DEBUG` for the engine. If you see this
through the wrapper:

```bash
echo "$LD_PRELOAD"
type -a bharatcode
```

Make sure `bharatcode` resolves to `$PREFIX/bin/bharatcode` (the managed wrapper) and not
to an older launcher. Run `bash diagnose.sh` from a clone, or reinstall.

Do **not** export `$PREFIX/glibc/lib/libtermux-exec.so` as `LD_PRELOAD` in a Termux shell:
Bionic programs such as `env` and `timeout` will fail. The wrapper passes it to the glibc
loader with `--preload` instead.

### `EACCES: permission denied, mkdir '/tmp/BharatCode'`

Android has no writable `/tmp`. The wrapper falls back to `$PREFIX/tmp` when `TMPDIR` is
unset or not writable. If you launch the engine manually, set `TMPDIR=$PREFIX/tmp`.
If the wrapper is an old installation, regenerate it with `bash install.sh --force`.

### `bharatcode: glibc runtime missing`

The Termux glibc package was removed or the loader is missing. Reinstall:

```bash
pkg install -y glibc termux-exec-glibc
bash install.sh --force       # from a clone
```

### `bharatcode: engine not installed`

The `current` symlink or the version directory is missing. Re-run the installer; it
repairs the current version. Account/session data is separate and is not deleted.

### Everything fails after a shell restart

`$PREFIX/bin` is on Termux's default `PATH`. Check:

```bash
echo "$PATH"
command -v bharatcode
```

If you started Termux with a custom environment (or `env -i`), source Termux's profile or
open a new Termux session. This project does not edit `.bashrc`; there is nothing to
deduplicate.

## Authentication

### The browser does not open

The official CLI prints an `https://auth.bharatcode.ai/...` URL and starts a local callback
server (`127.0.0.1:27182` in the tested version). Copy the URL into a browser on the same
device. If no browser is registered with Termux, the URL is still printed. Complete the
flow, then return to the waiting Termux session.

### `auth login` times out

The CLI waits for the browser callback. Start it again if the URL expired. Check network
reachability to `auth.bharatcode.ai` (the diagnostics script checks HTTPS reachability).
This project cannot and does not complete authentication for you.

### `auth status` says signed out

That is normal until you complete `bharatcode auth login`. The installer never signs in.

## TUI and server

### The TUI does not render

Use a real interactive Termux terminal with `TERM` set (`xterm-256color` is typical) and a
font that supports the glyphs the TUI uses. Try `bharatcode --help` first; if that works,
the engine and loader are functional. The TUI requires authentication; before login it
shows the official sign-in flow.

### `OPENCODE_SERVER_PASSWORD is not set; server is unsecured.`

This is an upstream warning from `bharatcode serve`. The server binds `127.0.0.1` by
default. Do not bind it to `0.0.0.0` on an untrusted network. This project does not add or
remove a password.

### Ctrl+C / SIGTERM behavior

The wrapper `exec`s the engine, so signals go directly to it. In the tested version, Ctrl+C
in the TUI exits cleanly and SIGTERM to a headless server terminates the process (wait
status 143). If a child process is left behind, stop it explicitly; reinstall if the
wrapper was replaced by something else.

## Updating and uninstalling

### `update.sh` says "not pinned/tested"

Use `--allow-untested` only if you accept that the engine may not run on Android; the
installer verifies the registry integrity and rolls back if the smoke test fails.

### `uninstall.sh` refuses to remove a directory

It only deletes a directory containing this project's `.managed-by` marker, and it only
removes a launcher containing its marker. If you intentionally used a custom
`BHARATCODE_TERMUX_DATA`, pass `--force` after verifying the path. If the launcher is a
foreign installation, remove it manually; the uninstaller will not touch it.

### The built-in `bharatcode uninstall` does not clean this installation

The upstream `uninstall` command manages a different installation layout (npm/JS
launcher). Use this repository's `uninstall.sh`. The uninstaller restores a launcher that
the installer backed up, if one was recorded.

### Account data after uninstall

`uninstall.sh` keeps `~/.local/share/BharatCode`, `~/.config/BharatCode`,
`~/.local/state/BharatCode`, and `~/.cache/BharatCode`. Delete them manually only if you
want to erase your local account/session data. It also keeps the Termux glibc packages
because other programs may use them.

## Getting help

Include the output of `diagnose.sh` and the exact command/exit status. Remove or redact
authorization URLs, tokens, session IDs, and personal paths before posting. Never post
credentials. This is a community compatibility project with no vendor support.
