#!/bin/sh
# One-time setup after cloning: wire the localvals filter + pre-commit hook,
# then re-checkout so the working tree gets the real values from local.env.
set -e
cd "$(git rev-parse --show-toplevel)"
[ -f local.env ] || { echo "local.env missing: cp local.env.example local.env and fill it in" >&2; exit 1; }
chmod +x scripts/localvals.sh scripts/hooks/pre-commit
git config filter.localvals.clean  'scripts/localvals.sh clean'
git config filter.localvals.smudge 'scripts/localvals.sh smudge'
git config filter.localvals.required true
git config core.hooksPath scripts/hooks
# re-smudge tracked files (except the filter tooling itself)
git ls-files -z -- . ":!scripts" | xargs -0 rm -f
git checkout -- .
echo "localvals filter + hooks configured; working tree now has real values."
