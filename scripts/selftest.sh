#!/usr/bin/env bash
#
# Run every env-gated self-test against a built Murmur.app and fail loudly.
#
# The tests print to stdout, which is invisible under `open Murmur.app`, so this
# launches the binary directly with MURMUR_TEST_EXIT set — the app runs the
# suites, prints, and exits with the failure count.
#
# Usage:
#   scripts/selftest.sh                     # uses build/export/Murmur.app
#   scripts/selftest.sh /Applications/Murmur.app
set -euo pipefail

cd "$(dirname "$0")/.."
APP="${1:-build/export/Murmur.app}"
BIN="$APP/Contents/MacOS/Murmur"
[[ -x "$BIN" ]] || { echo "error: no binary at $BIN — build first (scripts/release.sh --no-notarize)" >&2; exit 2; }

echo "==> Self-tests: $APP"
set +e
MURMUR_TEST_CAPTURE=1 \
MURMUR_TEST_COVERAGE=1 \
MURMUR_TEST_CORRECTIONS=1 \
MURMUR_TEST_EXIT=1 \
  "$BIN" 2>&1 | grep -E "^\[(CaptureOutcome|Coverage|PromptEcho|WAV|CorrectionDetector|CorrectionStore|SelfTest)\]"
status=${PIPESTATUS[0]}
set -e

if [[ $status -ne 0 ]]; then
  echo "FAILED (exit $status)" >&2
  exit $status
fi
echo "All self-tests passed."
