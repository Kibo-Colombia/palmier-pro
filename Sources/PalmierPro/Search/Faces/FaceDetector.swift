import CoreGraphics
import Foundation
import Vision

/// On-device face detection + face-crop feature prints via Apple's Vision framework. Free, offline,
/// no account. Apple exposes no public face-*recognition* embedding, so identity is approximated by
/// taking a general image feature print of the face crop and comparing prints by distance — good
/// for clustering a few recurring people (e.g. the creator vs others), not biometric matching.
///
/// All calls are synchronous Vision work; invoke them off the main actor.
enum FaceDetector {
    /// Bump to re-run detection across the Library (folds into `FaceRecord.fingerprint`).
    static let version = 1

    /// A detected face in one frame. `box` is Vision-normalized (origin bottom-left).
    struct Face {
        let box: CGRect
        let quality: Float
    }

    /// Detect faces in a frame and score each face's capture quality in the same handler.
    static func detect(in image: CGImage) -> [Face] {
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        let rects = VNDetectFaceRectanglesRequest()
        do { try handler.perform([rects]) } catch { return [] }
        guard let faces = rects.results, !faces.isEmpty else { return [] }

        // Seed the quality request with the detected faces so scores line up 1:1.
        let quality = VNDetectFaceCaptureQualityRequest()
        quality.inputFaceObservations = faces
        try? handler.perform([quality])
        let scored = quality.results ?? faces
        return scored.map { Face(box: $0.boundingBox, quality: $0.faceCaptureQuality ?? 0) }
    }

    /// Image feature print of a padded face crop, as a plain `[Float]`. `normBox` is Vision-normalized
    /// (bottom-left origin), as returned by `detect`. Returns nil for crops too small to be useful.
    static func featurePrint(of frame: CGImage, normBox: CGRect, pad: CGFloat = 0.25) -> [Float]? {
        guard let crop = cropFace(frame, normBox: normBox, pad: pad) else { return nil }
        let handler = VNImageRequestHandler(cgImage: crop, options: [:])
        let req = VNGenerateImageFeaturePrintRequest()
        do { try handler.perform([req]) } catch { return nil }
        guard let obs = req.results?.first else { return nil }
        return vector(from: obs)
    }

    // MARK: - Helpers

    /// Crop a Vision-normalized face box (bottom-left origin) out of a top-left-origin CGImage,
    /// padded for a little context and clamped to the frame.
    private static func cropFace(_ image: CGImage, normBox: CGRect, pad: CGFloat) -> CGImage? {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let bw = min(1, normBox.width * (1 + pad))
        let bh = min(1, normBox.height * (1 + pad))
        let x = max(0, min(1 - bw, normBox.midX - bw / 2))
        let yBottom = max(0, min(1 - bh, normBox.midY - bh / 2))
        // Vision origin is bottom-left; CGImage is top-left → flip Y.
        let topY = 1 - (yBottom + bh)
        let rect = CGRect(x: x * w, y: topY * h, width: bw * w, height: bh * h).integral
        guard rect.width >= 32, rect.height >= 32 else { return nil }
        return image.cropping(to: rect)
    }

    private static func vector(from obs: VNFeaturePrintObservation) -> [Float]? {
        let count = obs.elementCount
        guard count > 0 else { return nil }
        switch obs.elementType {
        case .float:
            return obs.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self).prefix(count)) }
        case .double:
            return obs.data.withUnsafeBytes { ptr in
                ptr.bindMemory(to: Double.self).prefix(count).map { Float($0) }
            }
        default:
            return nil
        }
    }
}
