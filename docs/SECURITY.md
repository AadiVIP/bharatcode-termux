# Security

## Scope and trust boundary

This project is an installer, launcher wrapper, and diagnostics/test suite. It does not
implement BharatCode, does not proxy its network traffic, and never asks for, stores, or
prints account credentials or tokens.

Trusted:

- The official npm registry (`https://registry.npmjs.org`) and TLS certificate trust on
  the device.
- Termux's signed package repositories (`glibc-repo`, `glibc`, `termux-exec-glibc`,
  `curl`, `coreutils`, …).
- The pinned SHA-256 values in `install.sh`, which were verified against the registry's
  own `sha512` integrity and `sha1` shasum metadata (`tests/verify-pins.sh`).
- This repository's `main` branch as served by GitHub over HTTPS.

Not trusted:

- The contents of the BharatCode engine itself beyond its published checksums. The engine
  runs with your Termux user's privileges and has whatever access the Android app sandbox
  grants Termux. It is a large third-party program; this project does not audit it.
- Any project environment or instruction that asks you to disable checks, install
  unreviewed binaries, or expose credentials.

## Supply chain

### Pinned installation (default)

- Version `1.15.46` is pinned in `install.sh`.
- Each tarball URL is the official registry path.
- The downloaded tarball's SHA-256 must equal the pin. Mismatches abort and remove the
  downloaded file.
- For the pin, `tests/verify-pins.sh` additionally checks npm's `sha512` `dist.integrity`
  and legacy `sha1` `dist.shasum`, and the tarball URL.
- The archive is inspected before extraction: only `package/` entries, no absolute paths,
  no `..`, no symlinks/hardlinks. The package manifest name/version and the engine ELF
  header are validated.
- The install is smoke-tested with `--version`; a failure rolls back to the previous
  version.

### Untested versions (`--version X --allow-untested`)

The SHA-256 pin does not exist for arbitrary versions. The installer verifies the tarball
against the registry's `dist.integrity` (sha512, base64) using OpenSSL, then runs the
engine smoke test. A failure restores the previous version. Registry compromise or TLS
compromise is outside this project's control; the smoke test only proves that
`--version` works, not that the engine is safe.

### Update path

`update.sh` downloads `install.sh` from this repository's `main` branch over HTTPS and
executes it. That installer is not separately signed or checksum-pinned. Anyone who can
push to `main` or compromise GitHub's delivery can influence updates. If this matters to
you, clone the repository, review the commit, and run the local installer/update instead.
Release tags and commit history provide an auditable trail.

### No binary redistribution

This repository does not contain the BharatCode engine, its tarballs, or node_modules.
The installer downloads them at runtime from the official registry and keeps the
official `LICENSE` alongside the installed engine. The glibc runtime is installed through
Termux's package manager, not from this repository.

## Runtime isolation and privileges

- No root is required or requested. Do not run the installer with `sudo`; Termux has no
  meaningful root and the installer is designed for the Termux user.
- No proot, chroot, VM, or namespace tricks are used. The engine runs as a normal Termux
  process under Android's application sandbox.
- The wrapper unsets `LD_PRELOAD`, `LD_LIBRARY_PATH`, `LD_AUDIT`, and `LD_DEBUG` before
  starting the glibc loader, and passes only the Termux-provided `libtermux-exec.so` to
  the loader via `--preload`. This is required for correctness and avoids inheriting a
  Bionic preload into a glibc process.
- The wrapper does not add capabilities, alter SELinux, mount filesystems, or modify
  system libraries.
- `bharatcode serve` binds `127.0.0.1` by default. Do not expose it without understanding
  the upstream warning: the tested version warns that
  `OPENCODE_SERVER_PASSWORD is not set; server is unsecured.`

## Credentials and privacy

- Authentication is performed by the official CLI. It prints an authorization URL and
  waits for a localhost callback; the user completes sign-in in a browser.
- This project never implements the auth exchange, never reads `auth.json`, and never
  prints tokens. Diagnostics run `auth status` and report only "signed in" or "signed
  out"; they do not print account details.
- Test logs in this repository are sanitized: authorization URLs, registry URLs, query
  parameters such as `state`/`code_challenge`, tokens, passwords, and the home path are
  redacted. The test suite does not print auth URLs by default.
- The installer's metadata contains only version numbers, hashes, timestamps, the registry
  URL, and file paths. It contains no credentials.

## Local file safety

- `uninstall.sh` only removes a launcher containing this project's marker and a data
  directory containing its `.managed-by` marker. It refuses `/`, `$HOME`, and `$PREFIX`,
  restores a backed-up launcher if recorded, and preserves BharatCode account/session data
  and the Termux glibc packages.
- `BHARATCODE_TERMUX_DATA` must be an absolute path and is rejected if it equals `/`,
  `$HOME`, or `$PREFIX`.
- Version strings are validated as semantic versions before being used in paths, blocking
  path traversal such as `--version ..`.
- A lock directory prevents concurrent installer runs; stale locks are detected by PID.

## Known limitations

- The pinned engine is not audited by this project. Its behavior and security are the
  vendor's responsibility.
- The installer trusts the npm registry, GitHub, and Termux's package signing. A
  compromise of any of those can defeat the checks. The pin protects against a different
  artifact being served for the pinned version; it does not protect against a compromised
  registry account publishing a new version that you explicitly choose to install with
  `--allow-untested`.
- `diagnose.sh` makes read-only network requests to the npm registry and the auth host to
  test reachability; it does not authenticate.
- Android/Termux behavior varies by device and Android version. The tested configuration
  is documented in the README and test report; other configurations are untested.

## Reporting a vulnerability

Open a GitHub issue or security advisory at
`https://github.com/AadiVIP/bharatcode-termux` without including secrets, tokens,
authorization URLs, or personal data. If the issue is in BharatCode itself (not in this
installer/wrapper), report it to the BharatCode project through its own channels.
