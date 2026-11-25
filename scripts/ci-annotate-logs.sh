#!/usr/bin/env bash
set -euo pipefail

# Emit GitHub Actions error annotations from captured build/test logs. This lets
# a public repository show the useful failure tail without requiring access to
# the private Actions log download endpoint.

max_lines="${CI_ANNOTATION_MAX_LINES:-80}"
max_chars="${CI_ANNOTATION_MAX_CHARS:-6000}"

escape_annotation() {
  # Keep the end of the log: the failure is at the end, not the beginning.
  tr '\n' ' ' | tail -c "$max_chars" | sed 's/%/%25/g'
}

found=0
for log_file in "$@"; do
  [[ -f "$log_file" ]] || continue
  found=1

  cleaned="$(mktemp)"
  trap 'rm -f "$cleaned"' EXIT
  sed -e 's/\r/\n/g' -e 's/\x1b\[[0-9;]*[A-Za-z]//g' "$log_file" >"$cleaned"

  error_lines="$(
    grep -aiE 'error|fail|fatal|cannot|no such|not found|refused|timed out|traceback|curl:|make:|http/[0-9]' "$cleaned" \
      | tail -n 30 || true
  )"
  if [[ -n "$error_lines" ]]; then
    message="$(printf '%s\n' "$error_lines" | escape_annotation)"
    printf '::error title=Error lines: %s::%s\n' "$log_file" "$message"
  fi

  tail_text="$(tail -n "$max_lines" "$cleaned" | escape_annotation)"
  [[ -n "$tail_text" ]] || tail_text="(log is empty)"
  printf '::error title=Failure tail: %s::%s\n' "$log_file" "$tail_text"

  rm -f "$cleaned"
  trap - EXIT
done

if [[ "$found" == "0" ]]; then
  printf '::error title=Build failure::No build or test log was produced. Check dependency setup and the workflow run.\n'
fi
