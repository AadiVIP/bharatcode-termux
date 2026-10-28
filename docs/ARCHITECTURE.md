# Architecture

This document explains why BharatCode does not run on Termux out of the box, which
approaches were considered, and how this project's installer and wrapper work.

## 1. The compatibility problem

The official package (`bharatcode@1.15.46`) is a Node package whose native executable is
published as the optional dependency `bharatcode-linux-arm64@1.15.46`. The package
manifest and the platform target logic reject Android:

- npm's platform gate compares `os`/`cpu`; Termux reports `os: android`, `cpu: arm64`.
  The package allows desktop platforms only, so npm exits with `EBADPLATFORM`.
- The native artifact is a **Linux AArch64 ELF** built against **glibc**. On Termux,
  executables run against Android's **Bionic** libc. The engine's interpreter is
  `/lib/ld-linux-aarch64.so.1` and it needs `libc.so.6`, `libpthread.so.0`, `libdl.so.2`,
  and `libm.so.6` — none of which are Bionic. Bionic also does not read
  `/etc/resolv.conf`, which a stock glibc build expects on Android.

The engine is a Bun-compiled single-file executable. It is not a Node script that can be
run with a different interpreter, and the vendor offers no Android build. Therefore the
only honest options are: reproduce a compatible user-space libc runtime, or reject the
target.

## 2. Approaches considered

### A. Run natively on Bionic

Requires the vendor to rebuild the engine for Bionic, or a third party to patch/relink
the binary. Rebuilding is not possible from the published artifact, and patching the
vendor binary was explicitly out of scope (and would undermine the integrity of the
installation). **Rejected.**

### B. Provide a glibc user space (chosen)

Termux publishes a glibc runtime for Android (`glibc`, `glibc-repo`,
`termux-exec-glibc`) from its signed repository. It supplies a patched loader and libc
that understand Android's sandbox and the Termux prefix, including a resolver
configuration at `$PREFIX/glibc/etc/resolv.conf`. The official Linux engine can be
started with:

```
$PREFIX/glibc/lib/ld-linux-aarch64.so.1 \
  --preload $PREFIX/glibc/lib/libtermux-exec.so \
  --library-path $PREFIX/glibc/lib \
  <official-bharatcode-binary> "$@"
```

This runs the unmodified official binary, without root, proot, containers, or kernel
namespaces. **Chosen.**

The alternative of installing a general-purpose glibc distro rootfs was rejected: it is
larger, needs proot/chroot tricks on Android, and is unnecessary for a single executable.

### C. Proot / full Linux userland / VM

`proot` or a VM can provide a conventional `/etc`, but user/mount namespaces are not
available in this Termux sandbox, proot adds a ptrace layer (performance, signal, and TTY
complexity), and the official binary does not need a full distro. A VM is far heavier than
the problem requires. **Rejected.**

Renaming Android to `linux`, spoofing npm platform fields, or patching the vendor binary
was **not** done. The installation uses the official artifact exactly as published.

## 3. Runtime invocation chain

`install.sh` writes a small Bash wrapper to `$PREFIX/bin/bharatcode`. It:

1. Verifies that the glibc loader and the installed engine exist (clear errors, exit 127).
2. Removes `LD_PRELOAD`, `LD_LIBRARY_PATH`, `LD_AUDIT`, and `LD_DEBUG` for the engine
   process. Termux exports a Bionic-targeted preload (`libtermux-exec-ld-preload.so`) in
   interactive shells. If it is inherited by the glibc loader, the loader fails with
   `libc.so: invalid ELF header` or `version 'LIBC' not found`. The wrapper starts from a
   clean loader environment instead.
3. Provides `HOME` and `TMPDIR` fallbacks. Android has no writable `/tmp`; if `TMPDIR` is
   unset or unusable, the wrapper uses `$PREFIX/tmp`. Without this, the engine fails with
   `EACCES: permission denied, mkdir '/tmp/BharatCode'` in a clean login environment.
4. `exec`s the glibc loader with the optional `libtermux-exec.so` preload (for Termux
   shebang handling inside the engine) and `--library-path $PREFIX/glibc/lib`. Because it
   is an `exec`, the engine replaces the wrapper: arguments, environment, stdin/stdout,
   TTY, signals, and the exit status pass through one process boundary. SIGTERM to the
   launcher terminates the engine (observed wait status 143); Ctrl+C in the TUI is handled
   by the engine and exits cleanly.

The loader, not the Bionic parent process, receives the preload. Setting a glibc preload
in the environment of a Bionic program (for example `env` or `timeout`) fails, because
that process itself is Bionic. The wrapper therefore unsets the environment and passes the
preload to the loader as a command-line option.

## 4. Installation layout

Default data directory: `$HOME/.local/share/bharatcode-termux` (override with
`BHARATCODE_TERMUX_DATA`; must be an absolute path, not `/`, `$HOME`, or `$PREFIX`).

```
bharatcode-termux/
├── .managed-by                     marker used by uninstall.sh
├── current -> versions/1.15.46     atomic symlink
├── versions/1.15.46/
│   ├── bharatcode                  official linux-arm64 engine
│   ├── LICENSE                     from the official main package
│   ├── package.json                from the official main package
│   └── metadata.txt                version, hashes, timestamp, source
├── state/
│   ├── install.env                 version, engine SHA-256, tarball hashes
│   └── launcher-backup             path to a backed-up foreign launcher
├── downloads/                      temporary verified tarballs (removed on success)
└── backups/                        backups of pre-existing launchers
```

The wrapper at `$PREFIX/bin/bharatcode` embeds the data directory and Termux prefix.
`current` is swapped with a temporary symlink plus `mv -fT`, and a smoke test runs the new
engine. On failure the previous symlink and version directory are restored. A lock
directory with stale-PID handling prevents concurrent installers.

## 5. Supply chain and integrity

- Tarball URLs are constructed from the official npm registry:
  `https://registry.npmjs.org/<package>/-/<package>-<version>.tgz`.
- The pinned version has a hard-coded SHA-256 for both the main and native tarballs,
  recorded after verifying the registry's own integrity metadata. `tests/verify-pins.sh`
  re-checks both SHA-256 pins, the registry `sha512` integrity, and the legacy `sha1`
  shasum.
- Untested versions (`--version X --allow-untested`) are verified against the registry's
  `dist.integrity` (sha512, base64) using OpenSSL; the engine must pass the same smoke test,
  otherwise the previous version is restored.
- Downloads use HTTPS only (`--proto '=https' --tlsv1.2`), retries, and `.part` files.
  Failed downloads are removed; verified cached tarballs may be reused.
- Archives are checked before extraction: only `package/...` paths, no absolute paths, no
  `..` traversal, and no symlinks/hardlinks. Manifests must declare the expected package
  name and version, and the engine must be a 64-bit little-endian AArch64 ELF larger than
  10 MB.
- The glibc runtime comes from Termux's `glibc-repo` package, which is signed by Termux's
  build key through the Termux keyring. The installer does not download random libc
  binaries from this repository or from a third-party site.
- No vendor binary is stored in this repository. The official `LICENSE` is retained in
  the install directory.

`update.sh` downloads the current installer from this repository over HTTPS. The
installer itself is not separately signed; its integrity depends on GitHub's TLS and the
repository's main branch. This trade-off is documented in
[SECURITY.md](SECURITY.md). From a clone, `update.sh` prefers the local installer.

## 6. Why the installer is a single file

The README's one-command installation requires `install.sh` to be self-contained: it must
work when piped to Bash, with no sibling files. Therefore the production scripts
(`install.sh`, `uninstall.sh`, `update.sh`, `diagnose.sh`) each carry the small amount of
shared logic they need. `lib/common.sh` is the shared helper library for the test suite
(assertions, temporary directories, log sanitization). The test suite checks that the
marker and repository URL stay consistent across the production scripts.

## 7. Updates and uninstallation

`update.sh` forwards its arguments to `install.sh`; the installer's idempotent path
verifies the current launcher and repairs it if necessary. A forced reinstall replaces the
version directory, swaps the symlink atomically, and removes the previous copy only after a
successful smoke test. BharatCode account/session data lives outside the install directory
and is never touched.

`uninstall.sh` refuses to delete an unmarked directory or a launcher it does not manage.
It removes the wrapper, restores a launcher backed up at install time, then removes its
own install directory. It deliberately preserves BharatCode's account data and the Termux
glibc packages.

## 8. Known limits

- Only arm64 Android/Termux is supported by the published native artifact.
- The engine is a desktop Linux build; desktop-specific assumptions may still surface.
- The TUI and authentication are upstream behavior. This project verifies that the
  official auth flow launches and that the TUI starts, but completing a login requires a
  human with credentials, so the post-login TUI is not automatically tested.
- The pinned version is tested; newer versions may work but are not guaranteed.
