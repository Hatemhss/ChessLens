// Frozen pre-v3 scanner for a reproducible benchmark only; never included in the application target.
// Its learning is in-memory here so comparison cannot touch the user's saved templates.
import AppKit
import CoreGraphics

struct LegacyLearnedTemplate: Codable {
    let label: String
    let vector: [Float]
}

struct LegacyScanPrediction {
    let position: Position
    let confidence: Double
}

/// A deliberately local, privacy-preserving recognizer. It learns the exact board theme
/// from positions the user confirms instead of uploading screenshots or requiring a model.
final class LegacyBoardScanner {
    // v2 intentionally starts clean: earlier builds could reinforce low-confidence mistakes.
    private let defaultsKey = "ChessLens.learnedTemplates.v2"
    private var templates: [LegacyLearnedTemplate] = []

    init() {
    }

    var hasTraining: Bool { !templates.isEmpty }

    var learnedSummary: String {
        let labels = Set(templates.map(\.label).filter { $0 != "." })
        let whiteKinds = labels.filter { $0.first?.isUppercase == true }.count
        let blackKinds = labels.filter { $0.first?.isLowercase == true }.count
        return "Saved shapes: \(whiteKinds)/6 white • \(blackKinds)/6 black • \(templates.count) samples"
    }

    func predict(image: CGImage, whiteAtBottom: Bool, sideToMove: PieceColor) -> LegacyScanPrediction? {
        guard !templates.isEmpty else { return nil }
        let vectors = squareVectors(in: image, whiteAtBottom: whiteAtBottom)
        guard vectors.count == 64 else { return nil }

        var position = Position(sideToMove: sideToMove)
        let groupedTemplates = Dictionary(grouping: templates, by: \.label)
        var confidenceTotal = 0.0
        for square in 0..<64 {
            let labelScores: [(String, Double)] = groupedTemplates.map { label, samples in
                let distances = samples.map { distance(vectors[square], $0.vector) }.sorted()
                let score: Double
                if distances.count >= 2 {
                    score = distances[0] * 0.82 + distances[1] * 0.18
                } else {
                    score = distances[0]
                }
                return (label, score)
            }.sorted { $0.1 < $1.1 }
            guard let best = labelScores.first else { return nil }
            let runnerUp = labelScores.dropFirst().first?.1 ?? 0.08
            let absoluteQuality = max(0, min(1, 1 - best.1 / 0.045))
            let separationQuality = max(0, min(1, (runnerUp - best.1) / 0.008))
            confidenceTotal += absoluteQuality * 0.68 + separationQuality * 0.32

            if best.0 != ".", let character = best.0.first {
                position.board[square] = Piece(fenCharacter: character)
            }
        }
        position.inferCastlingRights()
        let confidence = confidenceTotal / 64.0
        return LegacyScanPrediction(position: position, confidence: confidence)
    }

    func learn(image: CGImage, position: Position, whiteAtBottom: Bool) {
        let vectors = squareVectors(in: image, whiteAtBottom: whiteAtBottom)
        guard vectors.count == 64 else { return }

        for square in 0..<64 {
            let label = position.board[square].map { String($0.fenCharacter) } ?? "."
            let vector = vectors[square]
            let sameLabel = templates.enumerated().filter { $0.element.label == label }
            let isNovel = sameLabel.allSatisfy { distance(vector, $0.element.vector) > 0.0025 }
            if isNovel {
                templates.append(LegacyLearnedTemplate(label: label, vector: vector))
            }
            // Keep a bounded number of samples for every piece/empty label.
            let indexes = templates.indices.filter { templates[$0].label == label }
            if indexes.count > 24, let oldest = indexes.first { templates.remove(at: oldest) }
        }
    }

    func reset() {
        templates = []
    }

    func visualSignature(image: CGImage, whiteAtBottom: Bool) -> [[Float]] {
        squareVectors(in: image, whiteAtBottom: whiteAtBottom)
    }

    private func squareVectors(in image: CGImage, whiteAtBottom: Bool) -> [[Float]] {
        let squareWidth = image.width / 8
        let squareHeight = image.height / 8
        guard squareWidth > 4, squareHeight > 4 else { return [] }
        var result = Array(repeating: [Float](), count: 64)

        for visualRow in 0..<8 {
            for visualColumn in 0..<8 {
                let cropRect = CGRect(
                    x: visualColumn * squareWidth,
                    y: visualRow * squareHeight,
                    width: squareWidth,
                    height: squareHeight
                )
                guard let crop = image.cropping(to: cropRect) else { continue }
                let rank = whiteAtBottom ? 7 - visualRow : visualRow
                let file = whiteAtBottom ? visualColumn : 7 - visualColumn
                result[rank * 8 + file] = fingerprint(crop)
            }
        }
        return result
    }

    private func fingerprint(_ image: CGImage) -> [Float] {
        let size = 16
        var bytes = [UInt8](repeating: 0, count: size * size * 4)
        guard let context = CGContext(
            data: &bytes,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return [] }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))

        var cornerSamples: [(Float, Float, Float)] = []
        for y in [0, 1, 14, 15] {
            for x in [0, 1, 14, 15] {
                let offset = (y * size + x) * 4
                cornerSamples.append((Float(bytes[offset]), Float(bytes[offset + 1]), Float(bytes[offset + 2])))
            }
        }
        let background = cornerSamples.reduce((Float(0), Float(0), Float(0))) {
            ($0.0 + $1.0, $0.1 + $1.1, $0.2 + $1.2)
        }
        let bg = (background.0 / 16, background.1 / 16, background.2 / 16)

        var vector: [Float] = []
        vector.reserveCapacity(size * size * 3)
        for pixel in 0..<(size * size) {
            let offset = pixel * 4
            vector.append((Float(bytes[offset]) - bg.0) / 255)
            vector.append((Float(bytes[offset + 1]) - bg.1) / 255)
            vector.append((Float(bytes[offset + 2]) - bg.2) / 255)
        }
        return vector
    }

    private func distance(_ lhs: [Float], _ rhs: [Float]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return 1 }
        var sum = 0.0
        for index in lhs.indices {
            let delta = Double(lhs[index] - rhs[index])
            sum += delta * delta
        }
        return sum / Double(lhs.count)
    }
}
