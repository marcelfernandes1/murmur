import Foundation
import ApplicationServices

actor TestSpeechEngine: SpeechEngine {
    enum Failure: Error { case unavailable }
    let output: String
    let verification: String?
    var failVerification = false
    private(set) var firstPasses: [[String]] = []
    private(set) var secondPasses: [[String]] = []
    private(set) var windows: [Int] = []
    private(set) var verifiedWindows: [Int] = []
    init(output: String, verification: String?, failVerification: Bool = false) {
        self.output = output; self.verification = verification; self.failVerification = failVerification
    }
    func setStateHandler(_ handler: @escaping @Sendable (EngineLoadState) -> Void) {}
    func preload() {}
    func transcribe(_ samples: [Float], language: String?, vocabulary: [String]) -> String {
        firstPasses.append(vocabulary); windows.append(samples.count)
        return output
    }
    func verifyLearning(_ samples: [Float], language: String?, hints: [String]) throws -> String {
        secondPasses.append(hints); verifiedWindows.append(samples.count)
        if failVerification { throw Failure.unavailable }
        return verification ?? output
    }
}

@main
struct CorrectionLearningTests {
    @MainActor
    static func main() async throws {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            guard condition() else { fatalError("FAIL: \(message)") }
        }
        func candidate(_ before: String, _ after: String) -> CorrectionDetector.Candidate? {
            CorrectionDetector.candidate(before: before, after: after,
                insertedRange: NSRange(location: 0, length: (before as NSString).length))
        }
        func edit(_ before: String, _ after: String) -> CorrectionDetector.Candidate? {
            CorrectionDetector.edit(before: before, after: after,
                insertedRange: NSRange(location: 0, length: (before as NSString).length))
        }
        let suite = "MurmurCorrectionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        func freshStore() -> CorrectionStore {
            defaults.removePersistentDomain(forName: suite)
            return CorrectionStore(defaults: defaults)
        }
        let store = freshStore()
        let cloud = candidate("I asked cloud to explain this", "I asked Claude to explain this")!
        expect(store.learn(cloud) != nil, "verified user correction can be learned")
        expect(store.apply(to: "I asked cloud to explain this") == "I asked cloud to explain this", "no audio result means no automatic replacement")
        expect(store.apply(to: "I asked cloud to explain this", verifiedText: "I asked Claude to explain this") == "I asked Claude to explain this", "second listen can approve exact alias")
        expect(store.apply(to: "Please, I asked cloud about Swift.", verifiedText: "Please, I asked Claude about Swift.") == "Please, I asked Claude about Swift.", "learning works in a new sentence")
        for phrase in ["The cloud is above us.", "I asked CLOD to explain this", "I asked cloud9 to explain this",
                       "I asked cloud-based to explain this", "I asked cloud_name to explain this", "I asked cloudé to explain this",
                       "I asked cloud\u{301} to explain this", "we use cloud today"] {
            expect(store.apply(to: phrase, verifiedText: phrase) == phrase, "unchanged second listen preserves: \(phrase)")
        }
        let before = "I asked cloud to explain this."
        for rewritten in ["I asked Claude to explain that.", "I asked Claude to explain this thanks.",
                          "I asked Claude to explain.", "Claude is very helpful.", "", "I asked Claudia to explain this."] {
            expect(store.apply(to: before, verifiedText: rewritten) == before, "verifier cannot rewrite unrelated prose: \(rewritten)")
        }
        expect(store.apply(to: before, verifiedText: "i asked Claude to explain this") == "I asked Claude to explain this.", "original formatting preserved")
        expect(store.apply(to: "I asked CLOD to explain this", verifiedText: "I asked Claude to explain this") == "I asked CLOD to explain this", "no fuzzy aliases even if verifier invents one")
        for _ in 0..<10 { _ = store.learn(cloud) }
        expect(store.corrections.first?.contexts?.count == 1, "duplicate context bounded")
        expect(store.apply(to: before) == before, "frequency never grants unconditional replacements")
        expect(CorrectionStore(defaults: defaults).apply(to: before, verifiedText: "I asked Claude to explain this.") == "I asked Claude to explain this.", "learning persists")

        for (old, new) in [
            ("tell John about it", "tell Michael about it"), ("send the file today", "send the OpenAI today"),
            ("open the PR now", "open the SupaBase now"), ("we saw cats today", "we saw Code today"),
            ("the cat sat", "The cat sat"), ("cloud", "Claude"), ("call Jon", "call John"),
            ("call him later", "phone her later"), ("I asked cloud today", "I asked Claude today thanks"),
            ("I asked cloud today", "I asked Claude. today"), ("api", "API")
        ] { expect(candidate(old, new) == nil, "ignore unsupported edit: \(old) → \(new)") }
        for (old, new) in [
            ("Jon called me today", "John called me today"), ("we use claude daily", "we use Claude daily"),
            ("use the nda today", "use the NDA today"), ("deploy to cubernetes now", "deploy to Kubernetes now"),
            ("we ask clod daily", "we ask Claude daily"), ("pay through fan basis today", "pay through Fanbasis today"),
            ("pay through wap today", "pay through Whop today"),
            ("pay through Womp today", "pay through Whop today")
        ] { expect(candidate(old, new) != nil, "learn supported edit: \(old) → \(new)") }
        expect(CorrectionDetector.candidate(before: before, after: "I asked Claude to explain this.", insertedRange: nil) == nil, "unknown paste rejected")
        expect(CorrectionDetector.candidate(before: before, after: "I asked Claude to explain this.", insertedRange: NSRange(location: Int.max - 1, length: 8)) == nil, "overflowing range rejected")
        expect(CorrectionDetector.candidate(before: "precloud", after: "preClaude", insertedRange: NSRange(location: 3, length: 5)) == nil, "fragment of existing token rejected")
        let field = "Old cloud text. 🙂 I asked cloud today. Tail"
        let inserted = (field as NSString).range(of: "I asked cloud today.")
        expect(CorrectionDetector.candidate(before: field, after: "Old Claude text. 🙂 I asked cloud today. Tail", insertedRange: inserted) == nil, "pre-existing content not learnable")
        expect(CorrectionDetector.candidate(before: field, after: "Old cloud text. 🙂 I asked Claude today. Tail", insertedRange: inserted)?.heard == "cloud", "Unicode paste scope")

        let locate = CorrectionDetector.insertionRange
        expect(locate("hello", "🙂 ", "🙂 hello", NSRange(location: 3, length: 0)) == NSRange(location: 3, length: 5), "Unicode paste")
        expect(locate("hello", "old text", "hello text", NSRange(location: 0, length: 3)) == NSRange(location: 0, length: 5), "replace selected text")
        expect(locate("hello", "hello text", "hello text", NSRange(location: 10, length: 0)) == nil, "failed paste")
        expect(locate("hello", "", "hello", nil) == NSRange(location: 0, length: 5), "verified fallback")
        expect(locate("hello", "hello ", "hello hello", nil) == nil, "ambiguous fallback")
        expect(locate("hello", "unrelated", "hello", nil) == nil, "wrong field")

        let application = store.application(to: "🙂 I asked cloud to explain this", verifiedText: "🙂 I asked Claude to explain this")
        let reversal = edit(application.text, "🙂 I asked cloud to explain this")!
        expect(store.reject(edit: reversal, applied: application.applied), "correcting a replacement removes its rule")
        expect(store.corrections.isEmpty && store.ignored.count == 1, "negative evidence retained")
        expect(store.learn(cloud) == nil, "rejected correction cannot silently relearn")
        expect(CorrectionStore(defaults: defaults).learn(cloud) == nil, "rejection survives restart")
        store.allowLearning(store.ignored[0])
        expect(store.learn(cloud) != nil, "explicit re-enable permits learning")

        let casing = freshStore()
        _ = casing.learn(candidate("send to the us office", "send to the US office")!)
        expect(casing.apply(to: "send to the us office", verifiedText: "send to the US office") == "send to the US office", "verified acronym casing")
        expect(casing.apply(to: "send to the us office", verifiedText: "send to the us office") == "send to the us office", "unconfirmed casing unchanged")
        expect(casing.apply(to: "please send us a message", verifiedText: "please send us a message") == "please send us a message", "pronoun not hijacked")

        _ = freshStore()
        defaults.set("[{\"heard\":\"cloud\",\"corrected\":\"Claude\",\"createdAt\":0}]".data(using: .utf8), forKey: "learnedCorrections")
        let legacy = CorrectionStore(defaults: defaults)
        expect(legacy.corrections.count == 1 && legacy.corrections[0].needsContext, "legacy retained but paused")
        expect(legacy.apply(to: before, verifiedText: "I asked Claude to explain this.") == before, "legacy rule not activated automatically")
        expect(legacy.learn(cloud) != nil, "legacy can be relearned")

        _ = freshStore()
        let grouped = "[{\"corrected\":\"Whop\",\"variants\":[\"Womp\",\"WAP\",\"wap\"],\"createdAt\":0}]".data(using: .utf8)!
        defaults.set(grouped, forKey: "learnedCorrections")
        let migrated = CorrectionStore(defaults: defaults)
        expect(migrated.corrections.count == 2 && migrated.corrections.allSatisfy(\.needsContext), "released grouped aliases imported once, paused")
        _ = migrated.learn(candidate("pay through wap today", "pay through Whop today")!)
        expect(defaults.data(forKey: "learnedCorrections") == grouped, "migration preserves rollback data")
        expect(CorrectionStore(defaults: defaults).corrections.filter { !$0.needsContext }.count == 1, "new evidence survives reload independently")

        let apiStore = freshStore()
        let apiDictation = "Yeah, so I'm testing here and the thing is, when we build our card on file using the WAP API, I don't know why. Most of the times it doesn't go through. I don't know if it's a bank issue or what it is. You know what I mean?"
        let apiCorrected = apiDictation.replacingOccurrences(of: "WAP", with: "Whop")
        expect(apiStore.learn(candidate(apiDictation, apiCorrected)!) != nil, "user's WAP API edit can be learned")
        expect(apiStore.apply(to: apiDictation, verifiedText: apiCorrected) == apiCorrected, "three-letter API context supports user's exact dictation")
        expect(apiStore.apply(to: apiDictation, verifiedText: apiDictation) == apiCorrected, "API context resolves unchanged homophone on second listen")
        expect(apiStore.apply(to: apiDictation) == apiDictation, "API context still requires an audio verification result")
        let apiRepeat = apiDictation.replacingOccurrences(of: "our card", with: "their card")
        expect(apiStore.apply(to: apiRepeat, verifiedText: apiRepeat) == apiRepeat.replacingOccurrences(of: "WAP", with: "Whop"), "nearby API context survives unrelated wording difference")
        for phrase in ["Play the WAP song.", "Discuss the API. Play WAP next.", "We need to swap the API."] {
            expect(apiStore.apply(to: phrase, verifiedText: phrase.replacingOccurrences(of: "WAP", with: "Whop")) == phrase, "API learning does not change unrelated speech: \(phrase)")
        }
        let fillerStore = freshStore()
        for phrase in ["We say wap now.", "She has wap too.", "Ele tem wap sim."] {
            let corrected = phrase.replacingOccurrences(of: "wap", with: "Whop")
            _ = fillerStore.learn(candidate(phrase, corrected)!)
            expect(fillerStore.apply(to: phrase, verifiedText: corrected) == phrase, "short function words cannot authorize homophone: \(phrase)")
        }

        let undoStore = freshStore()
        let first = undoStore.learn(cloud)!
        let second = undoStore.learn(candidate("we use cloud every day", "we use Claude every day")!)!
        undoStore.undoLearning(second, previous: first)
        expect(undoStore.corrections == [first], "undo restores earlier evidence")
        undoStore.update(first, heard: "clod", corrected: "Claude")
        expect(undoStore.corrections.first?.needsContext == true, "changing alias invalidates evidence")

        let brands = freshStore()
        let whop = brands.learn(candidate("take payment through wap today", "take payment through Whop today")!)!
        _ = brands.learn(candidate("take payment through fan basis today", "take payment through Fanbasis today")!)!
        let newPhrase = "I sent payment via fan basis yesterday."
        let verifiedPhrase = "I sent payment via Fanbasis yesterday."
        expect(brands.apply(to: newPhrase, verifiedText: verifiedPhrase) == verifiedPhrase, "Fanbasis split alias works in novel context")
        expect(brands.apply(to: "Complete payment via wap today.", verifiedText: "Complete payment via Whop today.") == "Complete payment via Whop today.", "Whop works in novel context")
        for phrase in ["I went to the shop today.", "We need to swap the order.", "Open WAMP on this computer.",
                       "Play WAP next.", "Wrap this up today.", "Their fanbase keeps growing.",
                       "The band has a loyal fan base.", "Their fan basis is expanding.", "Whop and Fanbasis are correct."] {
            expect(brands.apply(to: phrase, verifiedText: phrase) == phrase, "preserve actual ordinary wording: \(phrase)")
        }
        expect(brands.apply(to: "The band has a growing fan basis.", verifiedText: "The band has a growing Fanbasis.") == "The band has a growing fan basis.", "long aliases also reject unrelated context")
        expect(store.apply(to: "There is a cloud in the sky.", verifiedText: "There is a Claude in the sky.") == "There is a cloud in the sky.", "prompt bias cannot override ordinary-word context")
        expect(brands.apply(to: "Play WAP next.", verifiedText: "Play Whop next.") == "Play WAP next.", "prompt-biased short alias still requires content context")
        expect(brands.apply(to: "Send payment via wap today.", verifiedText: "Send payment via wap today.") == "Send payment via Whop today.", "agreed homophone can reuse observed content context")
        expect(brands.apply(to: "Use wap today.", verifiedText: "Use Whop today.") == "Use wap today.", "function and time words cannot authorize short aliases")
        expect(brands.apply(to: "Payment received. Play WAP next.", verifiedText: "Payment received. Play Whop next.") == "Payment received. Play WAP next.", "context cannot cross a sentence")
        let brandApplication = brands.application(to: "Send payment via wap and payment via fan basis today.", verifiedText: "Send payment via Whop and payment via Fanbasis today.")
        expect(brandApplication.applied.count == 2, "multiple approved names")
        expect((brandApplication.text as NSString).substring(with: brandApplication.applied[1].range) == "Fanbasis", "receipts reflect split-word length change")
        let shifted = "Well, " + brandApplication.text
        expect(LearningPlan.relocate([brandApplication], into: shifted).count == 2, "receipts follow cleanup offsets")
        expect(LearningPlan.relocate([brandApplication], into: brandApplication.text + " " + brandApplication.text).isEmpty, "ambiguous duplicate receipts ignored")
        expect(brands.apply(to: "Send payment via wap. The band has a fan basis.", verifiedText: "Send payment via Whop. The band has a fan basis.") == "Send payment via Whop. The band has a fan basis.", "verifier can accept only one name")
        expect(brands.apply(to: "Send payment via wap and payment via fan basis today.", verifiedText: "Send payment via Whop and payment via Fanbasis for refunds.") == "Send payment via wap and payment via fan basis today.", "unrelated change rejects all proposed substitutions")

        let raw = "Send payment via wap today."
        let audio = [Float](repeating: 0.1, count: 16_000)
        let engine = TestSpeechEngine(output: raw, verification: "Send payment via Whop today.")
        let personalized = try await engine.transcribePersonalized(audio, language: "en", vocabulary: ["ManualTerm"], corrections: [whop])
        expect(personalized.text == "Send payment via Whop today." && personalized.original == raw, "audio flow preserves raw output")
        let firstPasses = await engine.firstPasses, secondPasses = await engine.secondPasses
        expect(firstPasses == [["ManualTerm"]], "automatic learned words never enter first pass")
        expect(secondPasses == [["Whop"]], "only retrieved candidate enters second pass")
        let windows = await engine.windows, verifiedWindows = await engine.verifiedWindows
        expect(windows == verifiedWindows, "both passes receive same audio length")
        let failing = TestSpeechEngine(output: raw, verification: nil, failVerification: true)
        let fallback = try await failing.transcribePersonalized(audio, language: "en", vocabulary: [], corrections: [whop])
        expect(fallback.text == raw, "verification error delivers original")
        let noAlias = TestSpeechEngine(output: "The shop is open.", verification: "The Whop is open.")
        _ = try await noAlias.transcribePersonalized(audio, language: "en", vocabulary: [], corrections: [whop])
        let unused = await noAlias.secondPasses
        expect(unused.isEmpty, "no observed alias means no second pass")
        let noLearning = TestSpeechEngine(output: raw, verification: "Send payment via Whop today.")
        _ = try await noLearning.transcribePersonalized(audio, language: "en", vocabulary: [], corrections: [])
        let emptyCalls = await noLearning.secondPasses
        expect(emptyCalls.isEmpty, "empty dictionary uses original fast path")
        let longEngine = TestSpeechEngine(output: raw, verification: "Send payment via Whop today.")
        _ = try await longEngine.transcribePersonalized([Float](repeating: 0.1, count: 61 * 16_000), language: "en", vocabulary: [], corrections: [whop])
        let longWindows = await longEngine.windows, longVerified = await longEngine.verifiedWindows
        expect(longWindows == [976_000] && longVerified.isEmpty, "untimed engines preserve complete long audio without guessed seams")

        let many = (0..<500).map { LearnedCorrection(heard: "term\($0)", corrected: "TERM\($0)", createdAt: Date(), contexts: [cloud.context!]) }
        let longText = (0..<500).map { "we use term\($0) every day." }.joined(separator: " ")
        let startTime = ContinuousClock.now
        let plan = LearningPlan.make(text: longText, corrections: many)
        let duration = startTime.duration(to: .now)
        expect(plan.hints.count <= 6 && duration < .seconds(1), "dictionary retrieval bounded and fast")
        let oversize = String(repeating: raw, count: 1500)
        expect(LearningPlan.make(text: oversize, corrections: [whop]).proposals.isEmpty, "oversized text abstains")
        // Run the real polling loop against injected AX reads. No accessibility
        // permission, synthetic typing, or changes to the user's apps required.
        let target = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        let other = AXUIElementCreateSystemWide()
        var focused = target
        var value = ""
        var selection = NSRange(location: 0, length: 0)
        let watcher = FieldEditWatcher(access: .init(
            focused: { focused }, value: { _ in value }, selection: { _ in selection }),
            timing: .init(settleDelay: .milliseconds(5), pollInterval: .milliseconds(5),
                          maxTicks: 100, editSettleDuration: .milliseconds(15)))
        var edits: [CorrectionDetector.Candidate] = []
        watcher.onEdit = { edit, _ in
            guard CorrectionDetector.isLearnable(edit) else { return false }
            edits.append(edit)
            return true
        }
        let dictated = "I asked cloud to explain this"
        func pause() async throws { try await Task.sleep(for: .milliseconds(50)) }
        func beginPaste() {
            value = ""
            selection = NSRange(location: 0, length: 0)
            focused = target
            watcher.start(insertedText: dictated)
            value = dictated
        }
        beginPaste()
        try await pause() // first task is polling
        beginPaste() // cancellation of the older poll must not cancel this watch
        try await pause()
        value = "I asked Claude to explain this"
        try await pause()
        expect(edits.count == 1 && edits.first?.corrected == "Claude", "new watch survives cancellation of older task")

        edits = []
        beginPaste()
        try await pause()
        focused = other
        value = "I asked Claude to explain this"
        try await pause()
        expect(edits.isEmpty, "focus change stops observation")

        focused = target
        value = dictated // failed paste: the same text already existed
        selection = NSRange(location: (dictated as NSString).length, length: 0)
        watcher.start(insertedText: dictated)
        try await pause()
        value = "I asked Claude to explain this"
        try await pause()
        expect(edits.isEmpty, "failed paste cannot learn from old matching text")

        beginPaste()
        try await pause()
        value = "I asked cloud to explain that" // unlearnable edit should not end the window
        try await pause()
        value = "I asked Claude to explain this"
        try await pause()
        expect(edits.count == 1, "unlearnable edit does not consume observation window")

        edits = []
        beginPaste()
        try await pause()
        value = "I asked Claude to explain this"
        try await Task.sleep(for: .milliseconds(5))
        value = dictated // user undoes before the edit settles
        try await pause()
        expect(edits.isEmpty, "transient edit is not learned")
        watcher.cancel()

        print("PASS: \(checks) learning checks; 500-rule retrieval in \(duration)")
    }
}
