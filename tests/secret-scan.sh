#!/data/data/com.termux/files/usr/bin/bash
# Scan tracked files for common credential/private-key patterns.
# This is a guardrail, not a replacement for GitHub secret scanning.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

pattern='(ghp_[A-Za-z0-9]{36}|gho_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|xox[baprs]-[A-Za-z0-9-]{10,}|AIza[0-9A-Za-z_-]{35}|-----BEGIN (RSA|EC|OPENSSH|DSA) PRIVATE KEY-----)'

files=()
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  while IFS= read -r f; do files+=("$f"); done < <(git ls-files)
else
  while IFS= read -r f; do files+=("$f"); done < <(find . -type f \
    -not -path './.git/*' -not -path './work/*' -not -path './package/*' \
    -not -name '*.tgz' -not -name '*.tar.gz')
fi

hits=0
for f in "${files[@]}"; do
  [ "$f" = "tests/secret-scan.sh" ] && continue
  [ -f "$f" ] || continue
  if grep -InE -- "$pattern" "$f"; then
    hits=$((hits + 1))
  fi
done

if [ "$hits" -gt 0 ]; then
  printf '\nSecret scan failed: %d file(s) contain credential-like patterns.\n' "$hits" >&2
  exit 1
fi
printf 'Secret scan: no credential/private-key patterns found in %d file(s).\n' "${#files[@]}"
