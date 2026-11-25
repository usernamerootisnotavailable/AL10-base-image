#!/usr/bin/env bash
set -euo pipefail

# Emit GitHub Actions error annotations from captured build/test logs. This lets
# a public repository show the useful failure tail without requiring access to
# the private Actions log download endpoint.

max_lines="${CI_ANNOTATION_MAX_LINES:-60}"
max_chars="${CI_ANNOTATION_MAX_CHARS:-6000}"

sanitize() {
  sed -e 's/\x1b\[[0-9;]*[A-Za-z]//g' \
    -e 's/\r$//' \
    -e 's/%/%25/g' \
    | tail -n "$max_lines" \
    | tr '\n' ' ' \
    | cut -c1-"$max_chars"
}

found=0
for log_file in "$@"; do
  [[ -f "$log_file" ]] || continue
  found=1
  message="$(sanitize <"$log_file")"
  [[ -n "$message" ]] || message="(log is empty)"
  printf '::error title=Failure details: %s::%s\n' "$log_file" "$message"
done

if [[ "$found" == "0" ]]; then
  printf '::error title=Build failure::No build or test log was produced. Check dependency setup and the workflow run.\n'
fi
