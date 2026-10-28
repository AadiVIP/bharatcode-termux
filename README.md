# BharatCode on Termux

An independent, unofficial installer that makes the **official BharatCode CLI** work on
**Android / Termux (arm64)** — without root, without proot, and without patching the
vendor binary.

> **Not affiliated with, endorsed by, or supported by BharatCode.** BharatCode is a
> separate product. This repository contains only installer/wrapper code and does not
> redistribute any BharatCode binary. See [License and disclaimer](#license-and-disclaimer).

**Tested configuration:** BharatCode `1.15.46` · Termux `0.118.3` · Android 15
(SDK 35) · `arm64-v8a` · Termux glibc `2.44`.

## Install (one command)

```bash
curl -fsSL https://raw.githubusercontent.com/AadiVIP/bharatcode-termux/main/install.sh | bash
```

Then authenticate with the official CLI and start it in a project:

```bash
bharatcode auth login    # open the printed URL and finish sign-in in your browser
bharatcode .             # start the TUI in the current directory
```

The installer never asks for credentials and never starts a login flow.

Requirements:

- Termux from [F-Droid](https://f-droid.org/packages/com.termux/) or the
  [Termux GitHub releases](https://github.com/termux/termux-app/releases) (the outdated
  Play Store build is not supported by Termux itself). Android 7+ is likely required;
  only Android 15 was tested.
- 64-bit ARM (`arm64-v8a`). armeabi-v7a, x86, and x86_64 are **not** supported by the
  official engine.
- About 600 MiB of free storage (the engine is ~186 MiB and the glibc runtime adds
  ~72 MiB) and a working network connection.
- No root. The installer writes only to `$PREFIX/bin`, `$HOME/.local/share/bharatcode-termux`,
  and the Termux package manager's glibc packages.

## Why plain `npm install` fails on Termux

The published package restricts itself to desktop platforms. On Android, npm rejects it
with `EBADPLATFORM` (Termux reports `os: android`, `cpu: arm64`, while the package allows
`darwin`, `linux`, and `win32`), and the native artifact is a **glibc Linux AArch64**
executable. Android's Bionic libc cannot load it directly.

This project solves that in user space:

1. It downloads the official `bharatcode` and `bharatcode-linux-arm64` tarballs from the
   npm registry and verifies their pinned SHA-256 hashes.
2. It installs the Termux **glibc** runtime from the Termux-signed glibc repository.
3. It launches the official Linux engine through the glibc loader, removing Termux's
   Bionic `LD_PRELOAD` first (that preload is what otherwise produces
   `libc.so: invalid ELF header`).
4. It puts a small Bash wrapper at `$PREFIX/bin/bharatcode` that forwards arguments,
   environment, stdio, signals, and the exit code. The engine runs as `exec`, so there is
   no extra process in the middle.

No vendor binary is patched, renamed, or redistributed. See
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the full design and the rejected
alternatives.

## What the installer does

- Refuses to run outside Termux or on a non-arm64 device.
- Checks free storage, installs missing basic tools, and installs
  `glibc-repo`, `glibc`, and `termux-exec-glibc` from Termux's package repositories when
  the glibc runtime is absent.
- Installs the **pinned, tested** BharatCode version. Tarballs come from
  `https://registry.npmjs.org`; the pinned SHA-256 and the registry's sha512 integrity
  are checked. Archives are validated (no absolute paths, `..` traversal, or symlinks)
  before extraction.
- Installs into `~/.local/share/bharatcode-termux` (override with
  `BHARATCODE_TERMUX_DATA`), keeps versions side by side, and switches the `current`
  symlink atomically.
- Runs a `--version` smoke test of the new engine and rolls back to the previous version
  if it fails.
- Backs up any pre-existing `$PREFIX/bin/bharatcode` (recorded in
  `state/launcher-backup`) and never deletes BharatCode account or session data.
- Is idempotent: rerunning it verifies and repairs the current installation. It does not
  edit shell startup files; Termux already puts `$PREFIX/bin` on `PATH`.

Options: `--force`, `--version X.Y.Z [--allow-untested]`, `--help`. Untested versions are
verified against the registry's sha512 integrity and rolled back on smoke-test failure.

## Common commands

```bash
bharatcode --version
bharatcode --help
bharatcode auth status
bharatcode auth login
bharatcode .                       # TUI in the current directory
bharatcode run "explain this repo"
bharatcode serve --port 4096      # headless server (localhost by default)
```

`bharatcode serve` prints `OPENCODE_SERVER_PASSWORD is not set; server is unsecured.`
This is upstream behavior. Keep the default `127.0.0.1` binding unless you understand the
risk of exposing the server.

## Updating

Updates install the version pinned and tested by this project (currently `1.15.46`):

```bash
curl -fsSL https://raw.githubusercontent.com/AadiVIP/bharatcode-termux/main/update.sh | bash
```

From a clone, `bash update.sh` uses the local installer. `bash update.sh --force`
reinstalls, and `bash update.sh --version X.Y.Z --allow-untested` tries another version
(with automatic rollback if its engine does not run). The installer is idempotent when the
pinned version is already installed. BharatCode account data and sessions are preserved
across updates.

## Uninstalling

```bash
curl -fsSL https://raw.githubusercontent.com/AadiVIP/bharatcode-termux/main/uninstall.sh | bash
```

This removes the managed wrapper and the install directory, restores a previous launcher
if the installer had backed one up, and then tells you where your BharatCode data lives.
It deliberately keeps:

- `~/.local/share/BharatCode`, `~/.config/BharatCode`, `~/.local/state/BharatCode`, and
  `~/.cache/BharatCode` (account, sessions, configuration);
- the Termux glibc packages, which other software may use.

Do **not** use the engine's built-in `bharatcode uninstall` command with this installation;
it manages a different installation layout.

## Diagnostics

```bash
curl -fsSL https://raw.githubusercontent.com/AadiVIP/bharatcode-termux/main/diagnose.sh | bash
```

Checks Termux/ABI/architecture, storage, tools, the glibc loader, the wrapper and its
marker, install integrity (including the engine SHA-256), runtime `--version`, account
state, and network reachability. It is read-only (it never starts a login flow) and exits
non-zero on a critical failure. Credentials are never printed.

## Compatibility

| Component | Tested / supported |
| --- | --- |
| BharatCode | `1.15.46` (pinned and tested) |
| OS | Android 15 / SDK 35 (Termux) |
| Termux | `0.118.3` |
| CPU / ABI | `aarch64` / `arm64-v8a` only |
| libc runtime | Termux glibc `2.44` (from the Termux glibc repository) |
| Shell | Bash (`$PREFIX/bin/bash`) |
| Root / proot | Not required |

Known limitations:

- Only 64-bit ARM Termux on Android is supported. This is a limit of the official native
  artifact; armv7 and x86_64 are not available from this project.
- The engine is the desktop Linux build. Features that assume desktop-only tools,
  paths, or a browser launcher may behave differently on Android.
- `bharatcode auth login` must be completed by **you** in a browser. Automated tests
  verify that the official flow launches, not that a login succeeds (no credentials are
  available to this project). The post-login TUI is therefore not covered by this
  project's automated tests.
- This project installs a pinned, tested version rather than tracking every upstream
  release. Use `update.sh --version ... --allow-untested` at your own risk; a failed
  smoke test rolls back.
- The built-in `bharatcode upgrade` and `bharatcode uninstall` commands do not manage this
  wrapper installation. Use this repository's scripts.

## Security

The installer pins the tested version and verifies both the SHA-256 of each official
tarball and the npm registry's `sha512` integrity metadata. The glibc runtime comes from
Termux's signed package repository. No credentials are read, logged, or proxied; auth is
handled entirely by the official CLI. `update.sh` downloads the current installer from
this repository over HTTPS. See [docs/SECURITY.md](docs/SECURITY.md) for the threat model,
the trust boundaries, and reporting instructions.

## Testing

```bash
bash tests/run-tests.sh              # mocked/unit tests (no device or network)
bash tests/run-tests.sh --device     # real Termux/arm64 end-to-end tests
bash tests/verify-pins.sh            # verify pins against the npm registry
```

The repository includes 122 mocked tests, a 42-check on-device end-to-end suite (with the
optional auth/uninstall checks enabled), and a registry pin/integrity verification script.
Real command transcripts, exit codes, sanitized logs, and explicitly labelled
user-assisted/untested items are in [docs/TEST-REPORT.md](docs/TEST-REPORT.md). See
[docs/TESTING.md](docs/TESTING.md) for the matrix and CI notes.

## Project layout

```
install.sh            self-contained installer (curl | bash)
uninstall.sh          safe uninstaller
update.sh             update/repair helper
diagnose.sh           read-only diagnostics
lib/common.sh         shared test-suite helpers
tests/                unit, device, pin-verification, and PTY helpers
docs/                 architecture, troubleshooting, security, testing, reports
.github/workflows/    CI (unit tests and pin verification)
```

## License and disclaimer

This repository's original code is licensed under the [MIT License](LICENSE). BharatCode
itself is a separate project; its published package declares the MIT license
(Copyright (c) 2025 opencode). No BharatCode binary, source, or other vendor artifact is
redistributed by this repository — the installer downloads official packages from npm at
runtime and retains the package's `LICENSE` file in the install directory.

BharatCode, its name, and its services belong to their respective owners. This is an
independent compatibility project; it is not an official installation method and comes
with no warranty or vendor support.
