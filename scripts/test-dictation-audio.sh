#!/bin/bash
# Usage: scripts/test-dictation-audio.sh <directory containing whisper.framework> [ggml model path]
# Generates local synthetic speech; never opens the microphone or edits app data.
set -euo pipefail
cd "$(dirname "$0")/.."
framework_dir="${1:?Pass a build-products directory containing whisper.framework}"
fixture_dir=$(mktemp -d "${TMPDIR:-/tmp}/murmur-dictation-audio.XXXXXX")
trap 'rm -rf "$fixture_dir"' EXIT
say -v Samantha -r 185 -o "$fixture_dir/speech.aiff" \
  'Please check the recording and keep every word I say. The first sentence explains the problem. The final sentence must remain complete.'
afconvert -f WAVE -d LEF32@16000 -c 1 "$fixture_dir/speech.aiff" "$fixture_dir/speech.wav"
# Compile the real wrapper with the current Swift compiler, avoiding stale
# cached Swift modules when Xcode has been updated since the last app build.
swiftc -emit-library -emit-module -module-name WhisperCppKit \
  -F "$framework_dir" -framework whisper -Xlinker -rpath -Xlinker "$framework_dir" \
  Vendor/WhisperCpp/Sources/WhisperCppKit/WhisperModel.swift \
  -o "$fixture_dir/libWhisperCppKit.dylib" -emit-module-path "$fixture_dir/WhisperCppKit.swiftmodule"
swiftc -parse-as-library -I "$fixture_dir" -L "$fixture_dir" -lWhisperCppKit \
  -F "$framework_dir" -Xlinker -rpath -Xlinker "$fixture_dir" \
  Murmur/Transcription/DecodeCoverage.swift tests/DictationAudioTests.swift \
  -o "$fixture_dir/dictation-audio-tests"
model_args=()
if [[ -n "${2:-}" ]]; then model_args+=("$2"); fi
"$fixture_dir/dictation-audio-tests" "$fixture_dir/speech.wav" "${model_args[@]}"
