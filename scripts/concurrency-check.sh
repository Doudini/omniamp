#!/bin/zsh
# Swift 6 readiness, as a ratchet: build with complete concurrency checking and count the warnings. Fails when there
# are more than scripts/concurrency-baseline.txt allows, so new code can't add any; when there are fewer, lower the
# baseline to the new count (CI says so). Once it reaches 0, the package can switch to the Swift 6 language mode.
#
#   ./scripts/concurrency-check.sh
set -euo pipefail
cd "$(dirname "$0")/.."
BASELINE=$(tr -dc '0-9' < scripts/concurrency-baseline.txt)
LOG=$(mktemp)
# Its own build folder: the strict flags must not mix with (or rebuild) the normal build. Emptied first: a build
# that finds nothing to recompile prints no warnings at all.
rm -rf .build/concurrency
swift build --scratch-path .build/concurrency -Xswiftc -strict-concurrency=complete 2>&1 | sed $'s/\x1b\\[[0-9;]*m//g' > "$LOG" || { cat "$LOG"; exit 1; }
# Each warning once (the compiler can print one twice); deprecations aren't about concurrency.
WARNINGS=$(grep -E '^/.*: warning: ' "$LOG" | grep -v 'deprecated' | sort -u || true)
COUNT=$(printf '%s' "$WARNINGS" | grep -c . || true)
echo "Concurrency warnings: $COUNT (baseline $BASELINE)"
printf '%s\n' "$WARNINGS" | sed -E 's|^.*/Sources/OmniAmp/([^/]+/[^:]+):.*|\1|' | sort | uniq -c | sort -rn | head -15
if (( COUNT > BASELINE )); then
  echo "::error::$((COUNT - BASELINE)) more concurrency warning(s) than the baseline. The first 40 (new code: look for your files):" >&2
  printf '%s\n' "$WARNINGS" | head -40 >&2
  exit 1
elif (( COUNT < BASELINE )); then
  echo "::notice::Down to $COUNT: lower scripts/concurrency-baseline.txt to $COUNT."
fi
