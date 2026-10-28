# Testing

## Layers

| Layer | Script | Environment | Network | Android/glibc |
| --- | --- | --- | --- | --- |
| Mocked/unit | `tests/run-tests.sh` (or `tests/unit.sh`) | Any Bash/Linux, including GitHub Actions | No | No |
| Registry pins | `tests/verify-pins.sh` | Any Bash with curl/openssl/python3 | Yes | No |
| Real device E2E | `tests/run-tests.sh --device` (or `tests/device.sh`) | Termux on arm64 | Yes (installation) | Yes |

The unit suite is the CI gate. It uses fake `curl`, fake `uname`/`getprop`, fake `pkg`,
synthetic tarballs, and synthetic ELF headers; it never proves that the vendor engine runs
on Android. The device suite is the proof of real compatibility. Do not present CI-only
results as device results.

## Commands

```bash
# Mocked/unit tests (122 checks, no device/network)
bash tests/run-tests.sh

# Real device suite (installs/repairs the pinned version on the device)
bash tests/run-tests.sh --device

# Real device suite with the optional destructive/network/auth checks
bash tests/device.sh --with-uninstall --with-network --with-auth

# Verify the SHA-256 pins and npm integrity metadata for the pinned version
bash tests/verify-pins.sh
```

Device options:

- `--with-uninstall` — uninstall, verify removal and idempotency, reinstall, verify.
- `--with-auth` — start the official `auth login` flow for 20 seconds and verify the URL
  and waiting state. It never submits credentials and never completes sign-in.
- `--with-network` — run `bharatcode models` and require success/non-empty output.
- `--skip-tui` — skip the PTY/Ctrl+C TUI smoke test.

`tests/device.sh` installs the pinned version if it is missing and refuses to run outside
Termux/arm64 or without the glibc loader. It does not remove account/session data.

## Coverage matrix

| Requirement | Mocked/unit | Real device |
| --- | --- | --- |
| Fresh install | installer state transitions with synthetic tarballs (`install_version` test) | `tests/device.sh` installs if missing; published one-command install transcript in TEST-REPORT |
| Repeat install / idempotency | `--help`, argument tests; installer logic | `install.sh` rerun and `update.sh` report “already installed” |
| Missing dependencies | fake `pkg` in a restricted PATH; clear failure | Real Termux `pkg` path exercised when glibc is absent (manual) |
| Corrupt download | fake curl writes bytes; hash failure removes file/`.part` | Registry pin verification; real downloads hash-checked during install |
| Interrupted download | fake curl exit 18; `.part` cleanup | `curl --retry`; retry behavior observed manually |
| Storage guard | `free_kb` mocked below/above threshold | Real free-space check on device |
| Unsupported architecture/ABI | fake `uname`/`getprop` reject x86_64 and armeabi-v7a | N/A (device is arm64); tested through mocks |
| Upgrade/repair | install_version success; smoke-failure rollback | `--force` reinstall; `update.sh`; uninstall/reinstall cycle |
| Version pin integrity | parser tests; pinned constants checked in code | `tests/verify-pins.sh` against npm (SHA-256, sha512, sha1) |
| Shell restart / PATH | wrapper generation | clean `env -i` login shell finds and runs `bharatcode` |
| Uninstall | N/A (script checks) | `uninstall.sh`, refusal on unmarked data, idempotency, reinstall |
| Runtime `--help`/`--version` | CLI surface (`bash -n`, `--help` of scripts) | Real engine `--help`, `--version`, exit codes |
| Auth flow | N/A | Starts official flow, verifies URL/waiting state; **does not complete login** |
| TUI | N/A | PTY launch, output, Ctrl+C graceful exit |
| Argument/exit forwarding | wrapper content tests | `debug paths`, invalid option exit 1, `run --help` exit 0 |
| Stdio forwarding | wrapper content tests | version to stdout, empty stderr, redirects work |
| Signals | wrapper `exec` content | headless server SIGTERM → wait status 143; TUI Ctrl+C → exit 0 |
| Persistence | N/A | clean login shell; account data untouched across uninstall |
| Secrets/sanitization | log sanitizer in `lib/common.sh` | auth URLs retained only in temp dirs; report redacts them |

## What is deliberately not automated

- Completing a real BharatCode login. It requires a human with an account and browser
  authorization. `--with-auth` only proves that the official flow launches; it is
  user-assisted, not a login success test.
- A fully authenticated TUI session (same reason). The PTY test proves the TUI starts and
  exits cleanly, not that every authenticated feature works.
- Other Android versions, other Termux versions, other ABIs, desktop Linux, and the
  Play Store Termux build.
- Vendor engine behavior, network services, and upstream security.

## CI

`.github/workflows/tests.yml` is committed and active. It is configured to run on Ubuntu:

- `bash -n` syntax checks and `shellcheck --severity=error` on the scripts;
- the mocked/unit suite (`tests/run-tests.sh`);
- the registry pin/integrity verification (`tests/verify-pins.sh`);
- a secret-pattern scan of tracked files (`tests/secret-scan.sh`).

**Current blocker (2026-10-28):** GitHub Actions is disabled at the account level for
`AadiVIP`. The initial push produced zero runs, and a manual dispatch returned
`HTTP 422: Actions has been disabled for this user.` The same steps were executed locally
with ShellCheck 0.11.0 and all passed (see [TEST-REPORT.md](TEST-REPORT.md#ci)). Enabling
Actions in the GitHub account settings is the remaining manual step.

CI has no Android device, no Termux, and no Termux glibc runtime, so it cannot run
`tests/device.sh`. Passing CI is necessary but not sufficient; the device results in
[TEST-REPORT.md](TEST-REPORT.md) are the compatibility evidence.

## Sanitization and artifacts

`lib/common.sh` provides `sanitize_log`, which redacts authorization URLs, registry URLs,
`token`/`secret`/`password`/`code_challenge`/`state` parameters, and the home path. Device
tests write temporary logs under `$TMPDIR` (or the test temp dir), not into the repository;
the report contains only sanitized excerpts. Do not attach auth logs, `auth.json`, or
session exports to issues.
