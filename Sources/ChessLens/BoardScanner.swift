import AppKit
import CoreGraphics

struct LearnedTemplate: Codable {
    let label: String
    let vector: [Float]
}

struct ScanPrediction {
    let position: Position
    /// A conservative matching score, not a probability that all 64 labels are correct.
    let confidence: Double
    let squareConfidences: [Double]
    let uncertainSquares: [Int]
}

struct ScanLearningResult {
    let learnedSquares: [Int]
    let rejectedSquares: [Int]
    var accepted: Bool { rejectedSquares.isEmpty }
}

/// Quantized bundled samples keep the known-theme starter set small and entirely local.
struct ShapeTemplateArchive: Codable {
    struct Sample: Codable {
        let label: String
        let pixels: Data
    }
    let version: Int
    let templates: [Sample]
}

/// Learns only explicitly confirmed positions. Both initial recognition and live tracking
/// use the same background-independent representation, so highlighting does not change a
/// white piece into a black one or turn empty cells into pieces.
final class BoardScanner {
    private static let defaultsKey = "ChessLens.learnedTemplates.v3"
    private static let featureCount = 24 * 24 * 4
    private static let emptyOccupancy = 0.045
    private static let occupiedOccupancy = 0.070
    private let defaults: UserDefaults
    private let bundledTemplates: [LearnedTemplate]
    private var templates: [LearnedTemplate] = []

    init(defaults: UserDefaults = .standard, bundledTemplates: [LearnedTemplate]? = nil) {
        self.defaults = defaults
        self.bundledTemplates = bundledTemplates ?? Self.loadBundledTemplates()
        // v2 stores a different descriptor and may contain reinforced mistakes. Keep those
        // bytes intact for recovery, but never mix them into the new representation.
        if let data = defaults.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([LearnedTemplate].self, from: data) {
            templates = decoded.filter(Self.isValid)
        }
    }

    var hasTraining: Bool { !templates.isEmpty || !bundledTemplates.isEmpty }

    var learnedSummary: String {
        let allTemplates = bundledTemplates + templates
        let labels = Set(allTemplates.map(\.label).filter { $0 != "." })
        let whiteKinds = labels.filter { $0.first?.isUppercase == true }.count
        let blackKinds = labels.filter { $0.first?.isLowercase == true }.count
        return "Local shapes: \(whiteKinds)/6 white • \(blackKinds)/6 black • \(templates.count) confirmed samples + \(bundledTemplates.count) built-in"
    }

    func predict(image: CGImage, whiteAtBottom: Bool, sideToMove: PieceColor) -> ScanPrediction? {
        guard let observation = BoardVision().observe(image: image, whiteAtBottom: whiteAtBottom) else {
            return nil
        }
        let grouped = Dictionary(grouping: bundledTemplates + templates, by: \.label)
        var position = Position(sideToMove: sideToMove)
        var confidences = [Double]()
        var uncertainSquares = [Int]()
        for square in 0..<64 {
            let vector = observation.squares[square]
            let occupancy = Self.occupancy(vector)
            // Empty squares are identified geometrically, independently of the number of
            // stored piece samples or the tint of the last move's highlighted squares.
            if occupancy <= Self.emptyOccupancy {
                confidences.append(1)
                continue
            }

            let scores: [(label: String, distance: Double)] = grouped.compactMap { label, samples in
                guard label != "." else { return nil }
                let best = samples.map { BoardVision.distance(vector, $0.vector) }.min() ?? 1
                return (label, best)
            }.sorted { $0.distance == $1.distance ? $0.label < $1.label : $0.distance < $1.distance }

            guard let best = scores.first, let character = best.label.first else {
                confidences.append(0)
                uncertainSquares.append(square)
                continue
            }
            let second = scores.dropFirst().first?.distance ?? 1
            let separation = max(0, second - best.distance)
            let absoluteQuality = max(0, 1 - best.distance / 0.065)
            let separationQuality = min(1, separation / 0.010)
            var confidence = absoluteQuality * 0.55 + separationQuality * 0.45
            let uncertain = occupancy < Self.occupiedOccupancy
                || best.distance > 0.022 || separation < 0.004 || confidence < 0.86
            if uncertain {
                confidence = min(confidence, 0.79)
                uncertainSquares.append(square)
            }
            // Keep the best candidate in the draft so the user can correct only uncertain
            // cells. An unrecognizable shape is deliberately left blank and marked unsure.
            if best.distance <= 0.060 {
                position.board[square] = Piece(fenCharacter: character)
            } else {
                confidence = 0
            }
            confidences.append(confidence)
        }
        // A screenshot cannot establish castling history. A confirmed session carries its
        // own rights; a standalone scan conservatively starts without them.
        position.castling = []
        let average = confidences.reduce(0, +) / 64
        let weakest = confidences.min() ?? 0
        let confidence = uncertainSquares.isEmpty ? average : min(average, weakest + 0.08)
        return ScanPrediction(
            position: position, confidence: confidence,
            squareConfidences: confidences, uncertainSquares: uncertainSquares
        )
    }

    /// Validate without mutation before the editor accepts either a session or training.
    func learningIssues(image: CGImage, position: Position, whiteAtBottom: Bool) -> [Int] {
        guard let observation = BoardVision().observe(image: image, whiteAtBottom: whiteAtBottom) else {
            return Array(0..<64)
        }
        return validation(observation: observation, position: position).rejectedSquares
    }

    @discardableResult
    func learn(image: CGImage, position: Position, whiteAtBottom: Bool) -> ScanLearningResult {
        guard let observation = BoardVision().observe(image: image, whiteAtBottom: whiteAtBottom) else {
            return ScanLearningResult(learnedSquares: [], rejectedSquares: Array(0..<64))
        }
        let result = validation(observation: observation, position: position)
        // Atomic validation prevents partially teaching a board whose badges are stale.
        guard result.accepted else { return result }
        for square in 0..<64 {
            let label = position.board[square].map { String($0.fenCharacter) } ?? "."
            let vector = observation.squares[square]
            // A new explicit correction wins over a nearly identical older user sample.
            templates.removeAll {
                $0.label != label && BoardVision.distance(vector, $0.vector) < 0.0010
            }
            let sameLabel = templates.filter { $0.label == label }
            if sameLabel.allSatisfy({ BoardVision.distance(vector, $0.vector) > 0.0012 }) {
                templates.append(LearnedTemplate(label: label, vector: vector))
            }
            let indexes = templates.indices.filter { templates[$0].label == label }
            if indexes.count > 24, let oldest = indexes.first { templates.remove(at: oldest) }
        }
        if let data = try? JSONEncoder().encode(templates) { defaults.set(data, forKey: Self.defaultsKey) }
        return result
    }

    func reset() {
        templates = []
        defaults.removeObject(forKey: Self.defaultsKey)
    }

    func visualSignature(image: CGImage, whiteAtBottom: Bool) -> [[Float]] {
        BoardVision().observe(image: image, whiteAtBottom: whiteAtBottom)?.squares ?? []
    }

    private func validation(observation: BoardObservation, position: Position) -> ScanLearningResult {
        var rejected = [Int]()
        for square in 0..<64 {
            let occupancy = Self.occupancy(observation.squares[square])
            if position.board[square] == nil ? occupancy >= Self.occupiedOccupancy : occupancy <= Self.emptyOccupancy {
                rejected.append(square)
            }
        }
        return ScanLearningResult(
            learnedSquares: rejected.isEmpty ? Array(0..<64) : [], rejectedSquares: rejected
        )
    }

    private static func occupancy(_ vector: [Float]) -> Double {
        guard vector.count == featureCount else { return 0 }
        var sum = 0.0
        for index in stride(from: 0, to: vector.count, by: 4) { sum += Double(vector[index]) }
        return sum / Double(featureCount / 4)
    }

    private static func isValid(_ sample: LearnedTemplate) -> Bool {
        (sample.label == "." || (sample.label.count == 1 && sample.label.first.flatMap(Piece.init(fenCharacter:)) != nil))
            && sample.vector.count == featureCount
            && sample.vector.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 }
    }

    private static func loadBundledTemplates() -> [LearnedTemplate] {
        let appResourceBundle = Bundle.main.resourceURL
            .flatMap { Bundle(url: $0.appendingPathComponent("ChessLens_ChessLens.bundle")) }
        let resourceBundle: Bundle
        if Bundle.main.bundleURL.pathExtension == "app" {
            // Do not call SwiftPM's Bundle.module fallback from a relocated app: it can
            // fatalError when the developer's build tree no longer exists.
            guard let appResourceBundle else { return [] }
            resourceBundle = appResourceBundle
        } else {
            resourceBundle = Bundle.module
        }
        guard let url = resourceBundle.url(forResource: "classic-shapes-v3", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let archive = try? JSONDecoder().decode(ShapeTemplateArchive.self, from: data),
              archive.version == 3 else { return [] }
        return archive.templates.map {
            LearnedTemplate(label: $0.label, vector: $0.pixels.map { Float($0) / 255 })
        }.filter(isValid)
    }
}
