#!/bin/bash
# The shell scripts CI checks (bash -n, ShellCheck): *.sh plus the files without
# an extension that start with a bash or sh shebang. One path per line.
# CI and CONTRIBUTING.md's quick checks both use it, so the lists stay the same.
set -eu   # no pipefail: grep -q may close the pipe on head early
cd "$(dirname "$0")/.."
{ git ls-files '*.sh'
  git ls-files | grep -v '\.[^/]*$' | while read -r f; do
    if head -1 "$f" 2>/dev/null | grep -qE '^#!.*\b(ba)?sh\b'; then echo "$f"; fi
  done; } | sort -u
