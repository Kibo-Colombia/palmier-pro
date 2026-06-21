import Testing
@testable import PalmierPro

/// Unit tests for the heard-labels layer: the say:/topic: classifier and the audio→visual fusion rule.
@Suite("HeardLabels")
struct HeardLabelsTests {
    private func transcript(_ text: String, lang: String? = "en") -> TranscriptionResult {
        TranscriptionResult(text: text, language: lang, words: [], segments: [])
    }

    private func say(_ text: String) -> String? {
        TranscriptClassifier.fileLabels(transcript(text)).first { $0.token.hasPrefix("say:") }?.token
    }

    @Test("say: keys off transcript shape")
    func sayFacet() {
        #expect(say("") == "say:silent")
        #expect(say("Hey, welcome back.") == "say:intro")
        #expect(say(Array(repeating: "word", count: 30).joined(separator: " ")) == "say:explainer")
        #expect(say(Array(repeating: "word", count: 80).joined(separator: " ")) == "say:story")
    }

    @Test("topic: extracts salient nouns from the transcript")
    func topicFacet() {
        let labels = TranscriptClassifier.fileLabels(
            transcript("Today we are making espresso coffee with a new machine in the kitchen."))
        let topics = labels.filter { $0.token.hasPrefix("topic:") }.map(\.token)
        #expect(!topics.isEmpty)
        #expect(topics.contains { token in ["coffee", "espresso", "machine", "kitchen"].contains { token.contains($0) } })
    }

    @Test("fusion sharpens use: from the said-state")
    func fusion() {
        let person = [
            FileLabel(token: "subj:person", coverage: 1, peak: 1),
            FileLabel(token: "use:broll", coverage: 1, peak: 0.5),
        ]
        let speech = LabelMerge.fuse(visual: person, said: .speech).map(\.token)
        #expect(speech.contains("use:talking-head") && speech.contains("act:talking") && !speech.contains("use:broll"))

        let silent = LabelMerge.fuse(visual: person, said: .silent).map(\.token)
        #expect(silent.contains("use:broll") && !silent.contains("use:talking-head"))

        let unknown = LabelMerge.fuse(visual: person, said: .unknown).map(\.token)
        #expect(unknown == person.map(\.token))   // untouched when there's no transcript
    }

    @Test("isHeard separates heard facets from seen")
    func isHeard() {
        #expect(HeardFacets.isHeard("topic:coffee"))
        #expect(HeardFacets.isHeard("say:intro"))
        #expect(!HeardFacets.isHeard("use:broll"))
        #expect(!HeardFacets.isHeard("subj:person"))
    }
}
