# Learned words: research and implementation decision

Reviewed 2026-10-22. Target: Murmur Mac 0.5.5, based on the installed 0.5.4 source. User examples: Whop and Fanbasis.

## What the sources support

- [Wispr's dictionary documentation](https://docs.wisprflow.ai/articles/4052411709-Teach-Flow-your-words-with-the-dictionary) distinguishes automatically learned dictionary entries from explicit literal spelling replacements. It filters learning and remembers deletions. Its public documentation does not expose the complete recognition algorithm, so this implementation does not claim to reproduce it.
- [CB-Whisper, Li et al., 2024](https://aclanthology.org/2024.lrec-main.262/) retrieves user names using acoustic keyword spotting before prompting Whisper. It supports restricting contextual bias to relevant candidates rather than globally boosting every saved word. Its trained TTS/CNN spotter is not implemented here.
- [CTC word spotting for contextual ASR, 2024](https://arxiv.org/abs/2406.07096) describes using acoustic evidence for targeted corrections. This motivates an audio check, but two Whisper passes are not an independent acoustic likelihood test and do not reproduce that paper's method.
- [FluidAudio issue 702](https://github.com/FluidInference/FluidAudio/issues/702) reports false positives for short vocabulary terms in 0.15.3, the dependency pinned here. The issue was closed after opt-in mitigations; follow-up reports still found residual short-term errors. This is a reason to test ordinary speech explicitly, not a claim that all current FluidAudio releases are broken.

## Decision and tradeoffs

There is no established universally best choice for this app, voice and hardware. The implemented compromise prioritizes precision and preserves local processing: exact observed aliases retrieve a small second-pass prompt; strict reconciliation prevents rewriting unrelated words; all substitutions need a nearby content word from a verified correction. The context check is a heuristic, not a confidence score or semantic understanding. It may miss valid names in new subjects, and can still confuse homophones in similar contexts.

The first pass never receives automatic learned words. Names already recognized correctly remain untouched. Split/join aliases are allowed, but frequency never increases a rule's authority and deletion cannot silently relearn the same pair. Pre-paste verification, focus checks, a settling delay, UTF-16 ranges, bounded matching and cancellation protect the source of learning. Only nearby dictated context is persisted; surrounding document text is not logged.

Long whisper.cpp recordings keep the existing one-pass decode, timestamp handling, coverage recovery and tail trimming. Verification uses bounded timestamped regions without text-overlap stitching. Untimed engines currently abstain on recordings over 25 seconds. Up to eight long-take regions are checked; extra regions keep their original text. A second pass adds latency when an alias appears. Manual vocabulary remains a separate explicit bias and can still affect first-pass recognition.

Old grouped aliases migrate to a separate settings key in a paused state, preserving the original key for rollback. This deliberately requires new contextual evidence for rules that may have caused overcorrection.

## Experiments that were rejected

Teacher-forced Whisper token scores favored common spellings over rare brand spellings even on the positive audio examples, so they were not used as a calibrated threshold. Small local Qwen classifiers were also tested to distinguish payment-company context from song titles. Both 1.5B and 3B configurations produced unacceptable false positives or false negatives on the small test set; no such classifier ships in this change. Matching every neighboring word was rejected because it prevented useful reuse in differently worded sentences.

## Validation

107 isolated learning checks passed, along with the app’s capture, coverage, prompt-echo and WAV self-tests. Eight synthetic audio fixtures and five exact-text context checks passed using large-v3, including a long recording that retained its ending while correcting WAP to Whop in payment context.

Run `scripts/test-corrections.sh` for isolated logic and simulated Accessibility-loop checks. These cover edit scope, Unicode, split terms, no fuzzy aliases, verifier drift/failure, short-word ambiguity, rejection persistence, grouped migration, undo, cancellation, focus changes, and preservation of full long recordings in untimed engines.

Run `scripts/test-learning-audio.sh /path/to/Debug/Murmur.app` for a reproducible local synthetic-audio smoke test, using cached large-v3 weights. It exercises the actual engine and correction pipeline without recording, typing, or editing the user's dictionary. It also checks WAP song contexts with exact text so an ASR error cannot hide the negative case.

Synthetic voices are not a substitute for Marcel's microphone recordings. A passing negative test means the learned-word layer did not inject a saved brand; it does not mean the underlying recognizer transcribed every word correctly. Real microphone-to-field correction and accent/noise performance still need user trials. No remote release was published.
