#!/usr/bin/env bash
# Creates a public GitHub repository and pushes the code (Cloud Shell has the GitHub CLI 'gh').
# build/ and results are excluded by .gitignore. The URL is saved to build/github_url.txt.
set -euo pipefail
cd "$(dirname "$0")/.."
NAME="${1:-iso27001-azure-evidence}"
command -v gh >/dev/null || { echo "GitHub CLI (gh) not found – upload the folder via github.com instead."; exit 1; }
gh auth status >/dev/null 2>&1 || gh auth login -h github.com -p https --web
LOGIN=$(gh api user --jq .login); GHID=$(gh api user --jq .id)
[ -d .git ] || git init -q
git config user.name  >/dev/null || git config user.name "$LOGIN"
git config user.email >/dev/null || git config user.email "${GHID}+${LOGIN}@users.noreply.github.com"
git add -A && (git commit -qm "ISO/IEC 27001 evidence collection prototype" || true)
git branch -M main
if gh repo view "$LOGIN/$NAME" >/dev/null 2>&1; then
  git remote get-url origin >/dev/null 2>&1 || git remote add origin "https://github.com/$LOGIN/$NAME.git"
  git push -u origin main
else
  gh repo create "$NAME" --public --source . --remote origin --push
fi
mkdir -p build
URL="https://github.com/$LOGIN/$NAME"; echo "$URL" > build/github_url.txt
echo "Repository: $URL  (enter it in section 2.5.6)"
