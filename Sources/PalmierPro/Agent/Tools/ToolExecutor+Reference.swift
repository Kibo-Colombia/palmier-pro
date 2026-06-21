import Foundation

extension ToolExecutor {
    private static let analyzeReferenceAllowedKeys: Set<String> = ["mediaRef", "maxFrames"]
    private static let analyzeReferenceDefaultFrames = 8
    private static let analyzeReferenceMaxFrames = 12

    /// The recipe-analysis front end (milestone B). Runs on-device CV/DSP over a reference video and
    /// returns the deterministic half of the edit recipe + a storyboard for the agent to read the
    /// fuzzy "vibe" half from. This is the hybrid split: Koma measures timing/format/color exactly;
    /// the agent (looking at the returned frames) infers transitions/caption-anim/look.
    func analyzeReference(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        try validateUnknownKeys(args, allowed: Self.analyzeReferenceAllowedKeys, path: "analyze_reference")
        let mediaRef = try args.requireString("mediaRef")
        let asset = try asset(mediaRef, editor: editor, label: "Reference")

        guard asset.isReference else {
            throw ToolError("Asset \(mediaRef) is not a reference. Import it with import_reference first.")
        }
        guard asset.type == .video else {
            throw ToolError("A reference must be a video — \(mediaRef) is \(asset.type.rawValue).")
        }
        let url = asset.url
        guard FileManager.default.fileExists(atPath: url.path) else {
            if case .downloading = asset.generationStatus {
                throw ToolError("Reference \(mediaRef) is still downloading. Poll get_media and retry once generationStatus is 'none'.")
            }
            throw ToolError("Reference file not on disk: \(url.lastPathComponent)")
        }

        let maxFrames = max(1, min(args.int("maxFrames") ?? Self.analyzeReferenceDefaultFrames, Self.analyzeReferenceMaxFrames))

        let analysis: ReferenceAnalyzer.Analysis
        do {
            analysis = try await ReferenceAnalyzer.analyze(url: url, maxStoryboard: maxFrames)
        } catch let err as ReferenceError {
            throw ToolError(err.description)
        } catch {
            throw ToolError("Reference analysis failed: \(error.localizedDescription)")
        }

        let recipe = EditRecipe(
            referenceMediaRef: mediaRef,
            format: analysis.format,
            pacing: analysis.pacing,
            beat: analysis.beat,
            captions: analysis.captions,
            color: analysis.color,
            vibe: nil
        )

        // Optional transcript — short-form often has speech worth carrying into the handoff.
        var transcriptMeta: Any?
        do {
            let t = try await TranscriptCache.shared.transcript(for: url, isVideo: true, range: nil)
            if !t.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                transcriptMeta = ["language": t.language ?? "?", "segments": t.segments.count, "text": t.text]
            }
        } catch {
            Log.transcription.error("reference transcription failed: \(error.localizedDescription)")
        }

        let recipeObj = try Self.recipeJSONObject(recipe)
        var meta: [String: Any] = [
            "recipe": recipeObj,
            "storyboardTimes": analysis.storyboard.map { $0.timeSeconds },
            "guidance": Self.analyzeReferenceGuidance,
        ]
        if let transcriptMeta { meta["transcript"] = transcriptMeta }

        guard let json = Self.jsonString(roundJSONFloatingPointNumbers(meta, toPlaces: 3)) else {
            throw ToolError("Failed to encode recipe")
        }
        let imageBlocks: [ToolResult.Block] = analysis.storyboard.map {
            .image(base64: $0.jpeg.base64EncodedString(), mediaType: "image/jpeg")
        }
        return ToolResult(content: imageBlocks + [.text(json)], isError: false)
    }

    private static func recipeJSONObject(_ recipe: EditRecipe) throws -> Any {
        let data = try JSONEncoder().encode(recipe)
        return try JSONSerialization.jsonObject(with: data)
    }

    private static let analyzeReferenceGuidance = """
    The storyboard images above are one frame per detected shot, in order. The 'recipe' fields \
    format/pacing/beat/captions/color were measured on-device and are high-confidence — apply them \
    to the user's own footage automatically (match aspect/length, cut on the beat grid and at the \
    pacing, place captions). Now LOOK at the storyboard frames and fill the fuzzy 'vibe' half — \
    transitionStyle, captionAnimation, colorLook, effects, summary — as your best guess; treat these \
    as low-confidence and confirm with the user via candidate picks rather than applying silently. \
    For color, the LUT/look pack is owned by color grading and may not be wired yet — approximate the \
    color.moodHint with the set_grade minor knobs (warmth/contrast/saturation) until looks land.
    """
}
