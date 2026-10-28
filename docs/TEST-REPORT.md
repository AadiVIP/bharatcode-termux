# Test report — BharatCode 1.15.46 on Termux

Date: 2026-10-28. Times are local IST (UTC+05:30) unless marked UTC. This report
describes what was actually executed on the development device. It separates mocked
tests from real-device tests, and user-assisted authentication from automated checks.

## Device and software under test

| Item | Observed value |
| --- | --- |
| Device | Android 15 (SDK 35), arm64-v8a |
| Termux | 0.118.3, prefix `/data/data/com.termux/files/usr` |
| CPU architecture | `aarch64` |
| glibc runtime | Termux `glibc` 2.44 (`ld.so ... 2.44-0`) |
| BharatCode | `1.15.46` (`bharatcode` + `bharatcode-linux-arm64`) |
| Installer state | `~/.local/share/bharatcode-termux`, launcher `$PREFIX/bin/bharatcode` |
| Root / proot | None used |

## Result summary

| Suite | Command | Result | Environment |
| --- | --- | --- | --- |
| Mocked/unit | `bash tests/run-tests.sh` | **122 passed, 0 failed, 0 skipped**, exit 0 | Android/Termux (mocked; CI-safe) |
| Real device E2E | `bash tests/device.sh --with-uninstall --with-network --with-auth` | **42 passed, 0 failed, 0 skipped**, exit 0 | Real Android/Termux/arm64 |
| Registry pins | `bash tests/verify-pins.sh` | **8/8 checks passed**, exit 0 | Network, npm registry |
| Diagnostics | `bash diagnose.sh` | **All critical checks passed (0 warnings)**, exit 0 | Real device |
| Secret scan | `bash tests/secret-scan.sh` | No credential/private-key patterns | Local tracked files |

The device suite was re-run at 15:11 after the final test changes. The unit suite was
re-run at 15:15. The pin check was last run at 14:48. The diagnostic transcript is from
14:53 (signed out at that time; see [Authentication](#authentication)).

## Real-device evidence

### Install, repeat install, force reinstall

First successful installer run (14:13) downloaded both official tarballs, verified both
SHA-256 values, installed, and ran the engine smoke test:

```text
==> Installing pinned, tested version 1.15.46
==> Downloading bharatcode-1.15.46.tgz
==> Verified sha256: 80a8957e9ec279a79523de92b37ded14f1042d8e2bfd66c79514fab8612a7298
==> Downloading bharatcode-linux-arm64-1.15.46.tgz
==> Verified sha256: 8a7efe92922b29dc125e847a6574cfb62582a8a84a17df53119d5534f5c3c28d
==> Verifying the installed launcher
BharatCode 1.15.46 is installed.
```

Rerunning the installer without changes produced the idempotent path (14:14):

```text
==> BharatCode 1.15.46 is already installed and working
```

`bash install.sh --force` and `bash update.sh` (14:14 and 14:32) both exited 0; the
published-install verification is recorded in [FINAL-AUDIT.md](FINAL-AUDIT.md).

Note: this device already had the Termux glibc packages from compatibility research, so
the installer's "install glibc from scratch" branch was not re-exercised on a bare
device. That branch is covered by mocked tests only (see limitations).

### Runtime: version, help, argv, exit codes, stdio

From the 42-check device suite:

```text
[pass] bharatcode --version exits 0
[pass] version output matches the pin            # 1.15.46
[pass] bharatcode --help exits 0
[pass] help lists commands
[pass] invalid CLI option returns a non-zero exit (1)
[pass] debug paths exits 0
[pass] subcommand --help exits 0 (arguments reach the engine)
[pass] version exits 0 with redirected stdio
[pass] version goes to stdout
[pass] version writes nothing to stderr
```

Manual checks at 15:15: `bharatcode --version` → `1.15.46`, exit 0;
`bharatcode --definitely-not-an-option` → exit 1; `bash update.sh` → exit 0.

### Shell persistence and update/repair

```text
[pass] clean login shell finds and runs bharatcode
[pass] clean login shell reports the pinned version
[pass] update.sh exits 0 when the pinned version is current
[pass] update.sh reuses the idempotent installer path
```

The clean-shell check uses `env -i` with a login Bash. The wrapper supplies a writable
`TMPDIR` fallback (`$PREFIX/tmp`) and a `HOME` fallback when the environment is empty.

### Headless server and signal forwarding

```text
[pass] headless server answers GET /config with 200
[pass] SIGTERM is forwarded to the engine (wait status 143)
```

`bharatcode serve` was started on localhost, queried over HTTP, then sent SIGTERM to the
wrapper PID. The shell's wait status was 143 (128 + SIGTERM), confirming `exec` semantics
with no intermediary process surviving.

### TUI under a PTY

```text
[pass] PTY driver exits 0
[pass] TUI exits 0 after Ctrl+C
[pass] TUI shuts down gracefully (not killed)
[pass] TUI produced terminal output
[pass] TUI rendered BharatCode UI or sign-in screen
```

The TUI test ran at 15:11, after the account was signed in (see below). The assertion is
intentionally broad: it proves the TUI starts, renders, and handles Ctrl+C, not that every
authenticated screen works. Raw terminal output stays in a temp directory and is not
committed.

### Network model listing

```text
[pass] bharatcode models exits 0
[pass] models output is non-empty
```

This confirms the official CLI can reach its backend through the glibc runtime on this
network. It does not upload credentials or inspect account data.

### Uninstall safety and uninstall/reinstall cycle

```text
[pass] uninstall refuses an unmarked data directory
[pass] unmarked-directory refusal is explicit
[pass] unmarked directory contents preserved
[pass] managed launcher untouched after refusal
[pass] uninstall.sh exits 0
[pass] wrapper removed
[pass] install directory removed
[pass] second uninstall is a safe no-op
[pass] second uninstall reports nothing to remove
[pass] reinstall after uninstall exits 0
[pass] reinstalled launcher runs
[pass] reinstalled version matches the pin
```

The uninstall test uses a synthetic unmarked data directory to verify the refusal path,
then uninstalls the managed installation, verifies a second uninstall is harmless, and
reinstalls. Vendor account/session data is not removed.

## Authentication

- The automated `--with-auth` check only launches the official `auth login` flow, verifies
  that it prints the official authorization URL and waits, then kills it after 20 seconds.
  It **never submits credentials and never completes sign-in**.
- The read-only diagnostic at 14:53 reported `Signed out`.
- A session appeared at 14:55 (BharatCode's `auth.json` mtime). This was completed
  interactively by the account owner in a browser, not by the test suite and not by this
  project.
- At 15:11 the device suite saw `Signed in`; at 15:15 the official CLI still reported
  `Signed in` (exit 0). This is the official CLI's own confirmation of an authenticated
  session.
- Account identifiers, tokens, authorization URLs, and session contents are intentionally
  omitted from this report. No credential material was passed to any test.

The evidence supports this statement: the official CLI on this device was signed in after
a user-assisted login. It does **not** support a claim that automated authentication was
tested or that every post-login feature was exercised.

## Defects found and fixed during testing

1. **First download failed with `curl: (23)`** because the downloads directory did not
   exist yet. The installer now creates the destination directory before downloading
   (`download_verified_sha256` / `download_verified_sha512`), and removes both the
   partial file and any stale destination on hash mismatch. The rerun succeeded.
2. **Clean-environment failure**: `env -i` produced
   `EACCES: permission denied, mkdir '/tmp/BharatCode'` because `TMPDIR` was unset and
   Android's `/tmp` is not writable by apps. The wrapper now falls back to
   `$PREFIX/tmp` (and `$HOME` when unset). The clean login-shell tests pass.
3. **Unit harness bugs**: the first unit run reported 87 passed / 30 failed because the
   helper library resolved the repository root one directory too high and a `grep -F`
   call consumed `--library-path` as an option. Both were fixed; the suite then reported
   117/0 and, after adding security regression tests, 122/0.
4. **Upstream quirk, not a wrapper defect**: `bharatcode definitely-not-a-command` treats
   the argument as a project path, prints a chdir error, and exits 0. The argv/exit test
   therefore uses `--definitely-not-an-option` (exit 1) plus `bharatcode run --help`
   (exit 0, engine-rendered help). Exit codes are forwarded unchanged in both cases.
5. **Security regressions found by review**: `--version ..` could traverse the version
   directory, and an unsafe `BHARATCODE_TERMUX_DATA` could point the installer at `/` or
   the home/prefix directory. Version strings are now strictly validated and the data
   directory is guarded. Regression tests were added to the 122-check suite.

## Explicitly not tested

- Completing sign-in through automation (impossible without credentials; deliberately not
  attempted). The authenticated TUI is therefore not asserted beyond "renders and exits
  cleanly".
- A bare device with no glibc packages installed; only the mocked path covers that branch.
- On-device corrupt/interrupted downloads (mocked in the unit suite; real downloads were
  hash-verified).
- Android versions other than 15, Termux versions other than 0.118.3, armeabi-v7a,
  x86/x86_64, rooted devices, proot, or the Play Store Termux build.
- Desktop-only BharatCode features that assume a desktop browser or desktop tooling.
- Upstream BharatCode behavior, services, and security.

## Reproducing

```bash
bash tests/run-tests.sh                    # 122 mocked checks, no device/network
bash tests/run-tests.sh --device           # real suite; installs/repairs if needed
bash tests/device.sh --with-uninstall --with-network --with-auth
bash tests/verify-pins.sh                  # SHA-256, sha512 integrity, sha1 shasum
bash diagnose.sh                           # read-only device diagnostics
bash tests/secret-scan.sh                  # credential-pattern scan
```

The unit suite is the CI gate, but it cannot prove vendor-engine compatibility. The
real-device suite above is the compatibility evidence. CI runs on Ubuntu and has no
Android device.

## Sanitization

Logs quoted here are excerpts from sessions on the development device. Authorization
URLs, account identifiers, tokens, session data, and the home path are removed or
redacted. Raw test logs and vendor tarballs are kept in the git-ignored `work/` and
`package/` directories and are not published. The secret scan is run before every push.

## CI

The first GitHub Actions run on the published repository is recorded in
[FINAL-AUDIT.md](FINAL-AUDIT.md) together with its URL and result. CI covers syntax,
ShellCheck (errors), the secret scan, the 122 mocked checks, and the registry pin
verification. It does not run the Android device suite.
