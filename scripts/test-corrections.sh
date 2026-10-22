#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/murmur-corrections.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
swiftc -parse-as-library \
  Murmur/Transcription/CorrectionDetector.swift \
  Murmur/Settings/CorrectionStore.swift \
  Murmur/Input/FieldEditWatcher.swift \
  Murmur/Transcription/SpeechEngine.swift \
  Murmur/Transcription/TranscriptCleaner.swift \
  tests/CorrectionLearningTests.swift \
  -o "$test_dir/correction-tests"
"$test_dir/correction-tests"
