# Final audit — BharatCode on Termux

Audit date: 2026-10-28 (IST). This file is part of the repository so the publication
state and its evidence survive the session. It is a follow-up documentation commit to the
initial code commit `601cf469e8853c00191ad2ab9103f64dd906ee00`.

## Publication

| Item | Value |
| --- | --- |
| Repository | https://github.com/AadiVIP/bharatcode-termux |
| Visibility | Public (confirmed through the GitHub API) |
| Default branch | `main` |
| Initial code commit | `601cf469e8853c00191ad2ab9103f64dd906ee00` |
| Commit history | `git log --oneline` (this audit is a later documentation commit) |
| Release tag | `v1.15.46-termux.1` (see the repository's Releases page) |
| Install command | README one-command (see the code block below) |
| Installer SHA-256 | `371a95ee3b50e02a46d9d8dad1901f63f40a235c125caae5a0c5ec0d7aae6699` (unchanged by documentation commits) |

```bash
curl -fsSL https://raw.githubusercontent.com/AadiVIP/bharatcode-termux/main/install.sh | bash
```

The repository is an independent compatibility project. It is not affiliated with,
endorsed by, or supported by BharatCode.

## What was delivered

- `install.sh` — self-contained, idempotent, pinned, integrity-checked installer.
- A generated wrapper at `$PREFIX/bin/bharatcode` that `exec`s the official engine under
  the Termux glibc loader and forwards arguments, environment, stdio, cwd, signals, and
  the exit status.
- `uninstall.sh` — refuses unmarked/foreign installations, backs up/restores a foreign
  launcher, keeps vendor account/session data.
- `update.sh` — reuses the local installer or fetches the published one over HTTPS.
- `diagnose.sh` — read-only environment/runtime/account/network diagnostics.
- `tests/` — 122 mocked checks, a 42-check real-device suite, a PTY driver, registry pin
  verification, and a secret-pattern scan.
- `docs/` — architecture, troubleshooting, security/threat model, testing, test report,
  and this audit.
- `.github/workflows/tests.yml` — CI for syntax, ShellCheck, secret scan, mocked tests,
  and registry pins.
- `LICENSE` (MIT for this repository's original code) and `NOTICE` (no vendor artifact
  redistribution; no official endorsement).

## Compatibility design

The official `bharatcode-linux-arm64` engine is a non-PIE glibc AArch64 ELF. It cannot
run directly under Android Bionic. The installer:

1. downloads the official `bharatcode` and `bharatcode-linux-arm64` tarballs from
   `https://registry.npmjs.org` and checks pinned SHA-256 values (and npm sha512 for
   untested versions);
2. uses the Termux-signed `glibc` 2.44 runtime;
3. generates a wrapper that unsets the Bionic `LD_PRELOAD`/`LD_LIBRARY_PATH` variables and
   invokes `ld-linux-aarch64.so.1 --preload libtermux-exec.so --library-path ...`;
4. `exec`s the unmodified official engine, so there is no extra process, and supplies
   `HOME`/`TMPDIR` fallbacks for clean Android environments.

No root, proot, vendor-binary patch, OS spoofing, or system-library modification is used.
No BharatCode binary is redistributed by the repository.

## Verification evidence

| Check | Command / artifact | Result | Time (IST) |
| --- | --- | --- | --- |
| Mocked/unit suite | `bash tests/run-tests.sh` | 122 passed, 0 failed, 0 skipped | 15:59 |
| Full real-device suite | `bash tests/device.sh --with-uninstall --with-network --with-auth` | 42 passed, 0 failed, 0 skipped | 15:11 |
| Published one-command install | exact README command (above) | exit 0; both SHA-256 pins verified; 1.15.46 installed | 15:26 |
| Repeat published install | same command | exit 0; “already installed and working” | 15:27 |
| Post-live device runtime | `bash tests/device.sh --with-network` | 32 passed, 0 failed, 2 skipped (optional sections) | 15:28 |
| Published diagnostics | live `diagnose.sh` over HTTPS | exit 0; 0 warnings; all critical checks passed | 15:28 |
| Registry pins | `bash tests/verify-pins.sh` | 8/8 passed (SHA-256, sha512, sha1) | 14:48 |
| Secret scan | `bash tests/secret-scan.sh` | no credential/private-key patterns in 21 files | 15:59 |
| CI-equivalent shell checks | `bash -n`; `shellcheck --severity=error` (0.11.0) | exit 0 | 15:59 |
| Published file match | raw `README.md`, `install.sh`, `uninstall.sh`, `update.sh`, `diagnose.sh`, `TEST-REPORT.md` | SHA-256 identical to tested local files at initial publication | before live install |

A README wording correction after the release clarified that the pinned install checks
SHA-256 at install time and that `tests/verify-pins.sh` performs the npm `sha512`/`sha1`
cross-check. The installer script hash above is unchanged by that correction.

Live installation was performed after a managed uninstall. Vendor account/session data was
deliberately preserved, so the uninstall/reinstall cycle could be verified without
destroying the user's login.

## Authentication

- The automated suite only launches the official `auth login` flow, verifies its URL and
  waiting state, and terminates it. It never submits credentials and never completes login.
- A session appeared at approximately 14:55 (BharatCode's `auth.json` mtime), immediately
  after the 14:53 diagnostic reported signed out. Completion required interactive browser
  authorization (user-assisted); this project's automation did not submit credentials.
- The official CLI reported `Signed in` at 15:11, 15:15, and again after the live
  uninstall/reinstall at 15:26. This is the CLI's own confirmation, not an inference from
  test output alone.
- Account identifiers, tokens, authorization URLs, and session contents are intentionally
  omitted. No credential material was read, logged, or proxied by this project.

The authenticated TUI is not exhaustively tested: the PTY check verifies launch, rendering,
and clean Ctrl+C exit, not every post-login screen or model interaction.

## CI status (external blocker)

`.github/workflows/tests.yml` is committed and the workflow is registered as `active`, but
GitHub Actions is disabled at the account level for `AadiVIP`:

- the initial push produced zero workflow runs;
- manual dispatch on 2026-10-28 at 09:59 UTC failed with
  `HTTP 422: Actions has been disabled for this user.`

No hosted CI result is claimed. The workflow commands were executed locally with
ShellCheck 0.11.0 and all passed (table above). Enabling Actions in the GitHub account
settings is the remaining manual step for hosted CI. CI would only run mocked and pin
checks on Ubuntu; it cannot run the Android device suite.

## Known limitations

- Only Android 15 (SDK 35), Termux 0.118.3, aarch64/arm64-v8a, and BharatCode 1.15.46 were
  tested. Other versions, ABIs, and rooted/proot setups are unverified.
- The device already had the Termux glibc packages when the installer was first exercised;
  the installer's “install glibc from scratch” branch is covered by mocked tests only.
- Corrupt/interrupted downloads and unsupported architectures are covered by mocked tests;
  the real device downloads succeeded and were hash-verified.
- `bharatcode .` was verified as a TUI launch in a disposable directory, not as a complete
  authenticated coding session with model responses.
- Existing-version upgrade was exercised through force reinstall/update of the pinned
  version; arbitrary version upgrades require `--allow-untested` and are not guaranteed.
- Desktop-only features and upstream BharatCode behavior/services are out of scope.
- The engine's built-in `upgrade` and `uninstall` commands do not manage this installation;
  use this repository's scripts.

## Manual steps remaining

1. Optional: enable GitHub Actions in the `AadiVIP` account settings so
   `.github/workflows/tests.yml` can run on push. The workflow itself is ready.
2. On a new device, run `bharatcode auth login` and complete the browser flow. This is
   user-assisted by design; no automation can or should do it.
3. Treat the authenticated TUI and model-backed coding sessions as manually verified by
   the user, not by this project's automated suite.

## Progress log (condensed)

1. Inspected the environment and official package; reproduced `EBADPLATFORM`.
2. Determined the engine is a glibc AArch64 ELF; rejected Bionic-direct execution, OS
   spoofing, and vendor patching; validated a proot-free Termux glibc approach.
3. Proved the unmodified engine runs under the Termux glibc loader after removing Bionic
   `LD_PRELOAD`.
4. Built the installer/wrapper/diagnostics/uninstall/update scripts with pinning,
   integrity checks, atomic switches, rollback, and safe-path guards.
5. Built and fixed the mocked suite (87/30 → 117/0 → 122/0 after security regression
   tests) and the device suite (25/0/3 → 37/0/0 → 42/0/0).
6. Published the public repository and verified live files against the tested commit.
7. Ran the exact README one-command install from a clean managed state; verified repeat
   install, diagnostics, runtime, auth state, and post-live device checks.
8. Recorded the account-level Actions blocker and ran the CI steps locally.

## Definition-of-done checklist

- [x] The genuine official BharatCode engine runs on the target Android/Termux device.
- [x] `bharatcode auth login` and `bharatcode .` are available through the documented
      workflow; sign-in was completed interactively and confirmed by the official CLI.
- [x] A clean installation succeeds with the one command from the public README.
- [x] The installer is repeatable, integrity-checked, and safe to rerun.
- [x] Installation, diagnostics, uninstall, documentation, and automated tests are present.
- [x] Published files were checked against the tested implementation.
- [ ] A GitHub-hosted CI run exists. Blocked externally by account-level Actions disable;
      the equivalent steps pass locally.

## Independence and licensing

This repository's original code is MIT-licensed. BharatCode is a separate product; its
published package declares MIT (Copyright (c) 2025 opencode). No vendor binary, source, or
other vendor artifact is redistributed here. BharatCode's name and services belong to their
respective owners; this is not an official installation method and comes with no vendor
support or warranty.
