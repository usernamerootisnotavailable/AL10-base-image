#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
cd "$REPO_ROOT"

PACKER_BIN="${PACKER_BIN:-packer}"
need_cmd bash
need_cmd "$PACKER_BIN"

mapfile -t shell_files < <(find scripts -type f -name '*.sh' | sort)
for file in "${shell_files[@]}"; do
  bash -n "$file"
done
log "bash syntax OK"

need_cmd shellcheck
# SC1091: shared helpers are sourced through a computed path.
# SC2029: remote commands are intentionally expanded locally and their
# arguments are shell-quoted with printf %q before being sent over SSH.
shellcheck -x -e SC1091,SC2029 "${shell_files[@]}"
log "shellcheck OK"

"$PACKER_BIN" fmt -check -recursive packer
log "packer fmt OK"

scripts/packer-validate.sh
log "packer validate OK"

need_cmd yamllint
yamllint -c .yamllint .
log "yamllint OK"

if command -v npx >/dev/null 2>&1; then
  npx --yes markdownlint-cli2@0.24.2 "**/*.md"
  log "markdownlint OK"
else
  warn "npx is not installed; skipping markdownlint"
fi

if command -v gitleaks >/dev/null 2>&1; then
  gitleaks detect --config .gitleaks.toml --source . --no-git --redact --verbose
  log "gitleaks OK"
else
  warn "gitleaks is not installed; skipping secret scan"
fi

log "lint passed"
