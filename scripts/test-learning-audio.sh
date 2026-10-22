#!/bin/bash
# Actual-engine smoke test; requires a Debug build and cached large-v3 weights.
set -euo pipefail
cd "$(dirname "$0")/.."
app="${1:?Pass the path to a Debug Murmur.app}"
binary="$app/Contents/MacOS/Murmur"
[[ -x "$binary" ]] || { echo "No executable: $binary" >&2; exit 2; }
fixtures_dir=$(mktemp -d "${TMPDIR:-/tmp}/murmur-learning-audio.XXXXXX")
python3 - "$fixtures_dir" <<'PY'
import json, subprocess, sys
from pathlib import Path
root = Path(sys.argv[1])
cases = [
    ('whop-pay', 'Send the payment through wop today.', 'Whop', []),
    ('fanbasis-pay', 'Use fan basis to collect the subscription payments.', 'Fanbasis', []),
    ('shop-negative', 'Send the payment through the shop today.', 'shop', ['Whop', 'Fanbasis']),
    ('swap-negative', 'We need to swap the order before tomorrow.', 'swap', ['Whop', 'Fanbasis']),
    ('wap-song-negative', 'Play the song WAP by Cardi B next.', 'song', ['Whop', 'Fanbasis']),
    ('fans-negative', 'These musicians have several loyal fan bases around the world.', 'fan', ['Whop', 'Fanbasis']),
    ('whatsapp-negative', 'Please send me the message on WhatsApp today.', 'WhatsApp', ['Whop', 'Fanbasis']),
    ('long-coverage', 'We are reviewing the work for next week. The design team finished the first page and the engineering team reviewed every change. Send the payment through wop today. Then check the invoice and save a copy for our records. There are several other details to discuss before the meeting ends. We should keep the original notes and ask everyone to read the complete document. The final section covers support requests and the schedule for next month. This last sentence stays intact.', 'last sentence stays intact', []),
]
fixtures = []
for name, sentence, contains, excludes in cases:
    aiff, wav = root / (name + '.aiff'), root / (name + '.wav')
    subprocess.run(['say', '-v', 'Samantha', '-r', '160', '-o', str(aiff), sentence], check=True)
    subprocess.run(['afconvert', '-f', 'WAVE', '-d', 'LEF32@16000', '-c', '1', str(aiff), str(wav)], check=True)
    fixtures.append(dict(path=str(wav), contains=contains, excludes=excludes))
(root / 'fixtures.json').write_text(json.dumps(fixtures))
PY
set +e
MURMUR_LEARNING_AUDIO_TESTS="$fixtures_dir/fixtures.json" "$binary" > "$fixtures_dir/result.log" 2>&1
status=$?
set -e
grep -E '^\[Learning(Audio|Context)\]' "$fixtures_dir/result.log" || true
if [[ $status -ne 0 ]] || ! grep -q '^\[LearningAudio\] failures=0' "$fixtures_dir/result.log"; then
  echo "Failed; fixtures and full log retained at $fixtures_dir" >&2
  exit 1
fi
rm -rf "$fixtures_dir"
