#!/usr/bin/env bash
#
# Repository secret check (pre-Milestone-3 security fix).
#
#   Scripts/check_no_secrets.sh
#
# Scans every tracked file and every commit in the repository for credentials:
#
#   * API-key shaped strings (sk-..., ghp_..., github_pat_..., AKIA..., xox.-...,
#     AIza..., ya29....), PEM private-key blocks and long bearer tokens,
#   * token= / secret= / password= style values that are long enough to be a
#     real credential (the throwaway fixtures this repository documents are
#     shorter and therefore do not match).
#
# A matched value is NEVER printed: only the category and <rev>:<path>:<line>.
# The output is therefore safe to paste into a report, an issue or a CI log.
# When DSH_WEB_URL carries a token, that literal value is searched for as well
# (through a temporary pattern file, so it never appears in the process list).
#
# Exits 0 when nothing suspicious was found, 1 otherwise.
#
#   Scripts/check_no_secrets.sh
#
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# High-confidence credential shapes.
HIGH_CONFIDENCE='(\bsk-[A-Za-z0-9_-]{20,}|\b(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}|\bgithub_pat_[A-Za-z0-9_]{20,}|\b(AKIA|ASIA)[0-9A-Z]{12,}|\bxox[baprs]-[A-Za-z0-9-]{10,}|\bAIza[0-9A-Za-z_-]{30,}|\bya29\.[0-9A-Za-z_-]{20,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|(?i)authorization[[:space:]]*:[[:space:]]*bearer[[:space:]]+[A-Za-z0-9._-]{20,})'

# A secret-looking assignment. 20 characters is well above the throwaway
# fixtures this repository uses ("test-token_123-abc", "super-secret", ...).
CONTEXTUAL='(?i)\b(token|secret|password|passwd|api[_-]?key|access[_-]?key|client[_-]?secret)["'"'"']?[[:space:]]*[:=][[:space:]]*["'"'"']?[A-Za-z0-9_.+-]{20,}'

FAILURES=0
report() {
  printf '  [FAIL] %s at %s\n' "$1" "$2"
  FAILURES=$((FAILURES + 1))
}
pass() { printf '  [pass] %s\n' "$1"; }

# Prints rev:path:line for every match without echoing the matched text.
scan_git() {
  local pattern="$1" label="$2" rev location
  for rev in $(git rev-list --all); do
    while IFS= read -r location; do
      report "$label" "$location"
    done < <(git grep -n -I -E -e "$pattern" "$rev" -- . 2>/dev/null | cut -d: -f1-3)
  done
}

echo "Repository secret check"
echo

echo "1. tracked working tree"
while IFS= read -r file; do
  [ -f "$file" ] || continue
  while IFS= read -r line; do
    report "credential-shaped value" "$file:$line"
  done < <(grep -n -I -E -e "$HIGH_CONFIDENCE" -e "$CONTEXTUAL" "$file" 2>/dev/null | cut -d: -f1)
done < <(git ls-files)
if [ "$FAILURES" -eq 0 ]; then
  pass "no credential-shaped value in tracked files"
fi

echo
echo "2. git history (all commits)"
BEFORE_HISTORY=$FAILURES
scan_git "$HIGH_CONFIDENCE" "credential-shaped value"
scan_git "$CONTEXTUAL" "credential-shaped value"
if [ "$FAILURES" -eq "$BEFORE_HISTORY" ]; then
  pass "no credential-shaped value in git history"
fi

echo
echo "3. the harness token, when the environment exposes one"
TOKEN_FILE="$(mktemp -t nativebrowser-token)"
chmod 600 "$TOKEN_FILE"
trap 'rm -f "$TOKEN_FILE"' EXIT
printf '%s\n' "${DSH_WEB_URL:-}" | sed -n 's/.*[?&]token=\([^&]*\).*/\1/p' > "$TOKEN_FILE"
if [ ! -s "$TOKEN_FILE" ]; then
  pass "DSH_WEB_URL carries no token; nothing to compare (literal check skipped)"
else
  TOKEN_FAILURES=0
  while IFS= read -r location; do
    TOKEN_FAILURES=$((TOKEN_FAILURES + 1))
    report "the harness token itself" "$location"
  done < <(git grep -n -I -F -f "$TOKEN_FILE" -- . 2>/dev/null | cut -d: -f1-2)
  for rev in $(git rev-list --all); do
    while IFS= read -r location; do
      TOKEN_FAILURES=$((TOKEN_FAILURES + 1))
      report "the harness token itself" "$location"
    done < <(git grep -n -I -F -f "$TOKEN_FILE" "$rev" -- . 2>/dev/null | cut -d: -f1-3)
  done
  if [ "$TOKEN_FAILURES" -eq 0 ]; then
    pass "the harness token does not appear in tracked files or history"
  fi
fi

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "Secret check: CLEAN"
else
  echo "Secret check: POSSIBLE SECRET FOUND ($FAILURES finding(s); values are deliberately not printed)"
fi
exit $((FAILURES > 0 ? 1 : 0))
