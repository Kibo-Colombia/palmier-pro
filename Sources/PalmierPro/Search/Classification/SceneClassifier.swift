import Accelerate
import Foundation

/// Precomputed label vectors for a (model, vocabulary) pair: one mean-pooled, L2-normalized
/// vector per token, plus the null anchor. Built once and reused across every asset.
struct LabelVectors: Sendable {
    let fingerprint: String
    let dim: Int
    let tokens: [String]
    let matrix: [Float]        // tokens.count × dim, row-major
    let nullVector: [Float]    // dim
}

/// Pure classification: scores an asset's per-shot embeddings against the label vectors and
/// assigns tokens per facet. No model inference here — that already happened at index time;
/// this is linear algebra over cached vectors (one SGEMM per asset).
enum SceneClassifier {

    // MARK: - Label vector construction (one model-inference pass, cached by the caller)

    static func buildLabelVectors(vocab: Vocabulary, embedder: VisualEmbedder, fingerprint: String) -> LabelVectors? {
        let dim = embedder.spec.embeddingDim
        var tokens: [String] = []
        var matrix: [Float] = []
        for label in vocab.labels {
            guard let vector = meanPooled(prompts: label.prompts, embedder: embedder, dim: dim) else { continue }
            tokens.append(label.token)
            matrix += vector
        }
        guard !tokens.isEmpty,
              let nullVector = meanPooled(prompts: vocab.nullPrompts, embedder: embedder, dim: dim)
        else { return nil }
        return LabelVectors(fingerprint: fingerprint, dim: dim, tokens: tokens, matrix: matrix, nullVector: nullVector)
    }

    /// Encode each prompt, L2-normalize, average, renormalize — an ensemble in one vector.
    private static func meanPooled(prompts: [String], embedder: VisualEmbedder, dim: Int) -> [Float]? {
        var accumulator = [Float](repeating: 0, count: dim)
        var n = 0
        for prompt in prompts {
            guard let vector = try? embedder.encode(text: prompt), vector.count == dim else { continue }
            let unit = l2normalized(vector)
            for i in 0..<dim { accumulator[i] += unit[i] }
            n += 1
        }
        guard n > 0 else { return nil }
        for i in 0..<dim { accumulator[i] /= Float(n) }
        return l2normalized(accumulator)
    }

    private static func l2normalized(_ v: [Float]) -> [Float] {
        var sumSquares: Float = 0
        vDSP_svesq(v, 1, &sumSquares, vDSP_Length(v.count))
        let norm = sqrt(sumSquares)
        guard norm > 0 else { return v }
        return v.map { $0 / norm }
    }

    // MARK: - Classification

    static func classify(index: EmbeddingStore.AssetIndex, vocab: Vocabulary, vectors: LabelVectors, fingerprint: String) -> AssetLabels {
        let dim = index.header.dim
        let count = index.header.count
        let labelCount = vectors.tokens.count
        guard dim == vectors.dim, count > 0, labelCount > 0 else {
            return AssetLabels(fingerprint: fingerprint, scenes: [], file: [])
        }

        // Combined matrix = label vectors with the null anchor appended as the last column.
        let cols = labelCount + 1
        var combined = vectors.matrix
        combined += vectors.nullVector

        // scores (count × cols) = frameVectors (count × dim) · combinedᵀ — same kernel as VisualSearch.
        var scores = [Float](repeating: 0, count: count * cols)
        cblas_sgemm(
            CblasRowMajor, CblasNoTrans, CblasTrans,
            Int32(count), Int32(cols), Int32(dim),
            1, index.vectors, Int32(dim),
            combined, Int32(dim),
            0, &scores, Int32(cols)
        )

        // Per shot, take the peak score per column ("does this label appear anywhere in the scene").
        var sceneOrder: [Double] = []
        var sceneRange: [Double: (start: Double, end: Double)] = [:]
        var sceneMax: [Double: [Float]] = [:]
        for i in 0..<count {
            let row = index.rows[i]
            let shot = row.shotStart
            if sceneMax[shot] == nil {
                sceneMax[shot] = [Float](repeating: -.greatestFiniteMagnitude, count: cols)
                sceneRange[shot] = (row.shotStart, row.shotEnd)
                sceneOrder.append(shot)
            }
            let base = i * cols
            for j in 0..<cols where scores[base + j] > sceneMax[shot]![j] {
                sceneMax[shot]![j] = scores[base + j]
            }
        }

        // Precompute facet membership + margin per label column.
        let facetOf = vectors.tokens.map { String($0.prefix { $0 != ":" }) }
        let marginOf: [Double] = vectors.tokens.map { token in
            let facetID = String(token.prefix { $0 != ":" })
            return vocab.labels.first { $0.token == token }?.margin ?? vocab.facet(facetID)?.defaultMargin ?? 0.02
        }

        var scenes: [SceneLabels] = []
        var fileAgg: [String: (count: Int, peak: Float)] = [:]
        let nullColumn = labelCount
        for shot in sceneOrder {
            let maxes = sceneMax[shot]!
            let nullScore = Double(maxes[nullColumn])

            // Gather passing candidates grouped by facet.
            var byFacet: [String: [(token: String, score: Float)]] = [:]
            for j in 0..<labelCount where Double(maxes[j]) >= nullScore + marginOf[j] {
                byFacet[facetOf[j], default: []].append((vectors.tokens[j], maxes[j]))
            }

            var assigned: [TokenScore] = []
            for (facetID, candidates) in byFacet {
                let mode = vocab.facet(facetID)?.mode ?? .multi
                let cap = mode == .exclusive ? 1 : (vocab.facet(facetID)?.maxLabels ?? 3)
                let kept = candidates.sorted { $0.score > $1.score }.prefix(cap)
                for c in kept { assigned.append(TokenScore(token: c.token, score: c.score)) }
            }

            let range = sceneRange[shot]!
            scenes.append(SceneLabels(shotStart: range.start, shotEnd: range.end, tokens: assigned))
            for a in assigned {
                var agg = fileAgg[a.token] ?? (0, -.greatestFiniteMagnitude)
                agg.count += 1
                agg.peak = max(agg.peak, a.score)
                fileAgg[a.token] = agg
            }
        }

        let sceneCount = max(scenes.count, 1)
        let file = fileAgg
            .map { FileLabel(token: $0.key, coverage: Double($0.value.count) / Double(sceneCount), peak: $0.value.peak) }
            .sorted { $0.coverage * Double($0.peak) > $1.coverage * Double($1.peak) }
        return AssetLabels(fingerprint: fingerprint, scenes: scenes, file: file)
    }
}
