import Foundation

struct ReconciledPosition: Sendable {
    let position: Position
    let moves: [ChessMove]
    let confidence: Double
}

/// Session references come from the board the user actually confirmed, not the
/// persistent recognizer's possibly unrelated themes or older mislabeled samples.
struct SessionBoardModel: Sendable {
    private static let labelCount = 13
    private let seedSamples: [[[Float]]]

    init(position: Position, observation: BoardObservation) {
        var samples = Array(repeating: [[Float]](), count: Self.labelCount)
        for square in 0..<min(64, observation.squares.count) {
            Self.appendUnique(observation.squares[square],
                              to: &samples[Self.labelIndex(position.board[square])])
        }
        seedSamples = samples
    }

    /// Search complete resulting positions, including both players' moves when
    /// the intermediate screenshot was missed. Chess history is preserved by applying moves.
    func reconcile(
        position: Position,
        baseline: BoardObservation,
        observed: BoardObservation,
        maximumPlies: Int = 2
    ) -> ReconciledPosition? {
        guard baseline.squares.count == 64, observed.squares.count == 64,
              baseline.squares.allSatisfy({ !$0.isEmpty }),
              observed.squares.allSatisfy({ !$0.isEmpty }) else { return nil }

        // The current position already labels this confirmed baseline. Identical
        // appearances cannot represent a new move, and require no classifier work.
        if observed.squares == baseline.squares {
            return ReconciledPosition(position: position, moves: [], confidence: 1)
        }

        var samples = seedSamples
        for square in 0..<64 {
            Self.appendUnique(baseline.squares[square],
                              to: &samples[Self.labelIndex(position.board[square])])
        }
        let costs: [[Double]] = observed.squares.map { appearance in
            samples.map { Self.minimumDistance(appearance, to: $0) }
        }
        let minimumCosts = costs.map { $0.min() ?? 1 }

        struct Candidate {
            let position: Position
            let moves: [ChessMove]
            let score: Double
            let maximumRegret: Double
            let maximumCost: Double
            let meanCost: Double
        }
        func evaluate(_ candidate: Position, moves: [ChessMove]) -> Candidate {
            var regret = 0.0, worstRegret = 0.0, worstCost = 0.0, totalCost = 0.0
            for square in 0..<64 {
                let cost = costs[square][Self.labelIndex(candidate.board[square])]
                let difference = max(0, cost - minimumCosts[square])
                regret += difference
                worstRegret = max(worstRegret, difference)
                worstCost = max(worstCost, cost)
                totalCost += cost
            }
            return Candidate(
                position: candidate,
                moves: moves,
                score: regret + Double(moves.count) * 0.001,
                maximumRegret: worstRegret,
                maximumCost: worstCost,
                meanCost: totalCost / 64
            )
        }

        let unchanged = evaluate(position, moves: [])
        // Common idle case: all pieces match their current labels. No move search required.
        if unchanged.maximumRegret < 0.002 && unchanged.maximumCost < 0.035 {
            return ReconciledPosition(position: position, moves: [], confidence: 1)
        }

        var candidates = [unchanged]
        for firstMove in maximumPlies > 0 ? position.legalMoves() : [] {
            let first = position.applying(firstMove)
            candidates.append(evaluate(first, moves: [firstMove]))
            if maximumPlies >= 2 {
                for reply in first.legalMoves() {
                    candidates.append(evaluate(first.applying(reply), moves: [firstMove, reply]))
                }
            }
        }
        candidates.sort { $0.score < $1.score }
        guard let best = candidates.first,
              best.maximumRegret < 0.018,
              best.score < 0.10,
              best.maximumCost < 0.08,
              best.meanCost < 0.025 else { return nil }

        let alternative = candidates.dropFirst().first { $0.position.fen != best.position.fen }
        let margin = (alternative?.score ?? 1) - best.score
        guard margin > 0.008 else { return nil }
        if !best.moves.isEmpty {
            // A sequence must explain a measurable improvement over retaining the old board.
            guard unchanged.score - best.score > 0.015 else { return nil }
        }
        let confidence = min(1, max(0, 1 - best.score / 0.15)) * min(1, margin / 0.035)
        return ReconciledPosition(position: best.position, moves: best.moves, confidence: confidence)
    }

    private static func labelIndex(_ piece: Piece?) -> Int {
        guard let piece else { return 0 }
        let kind: Int
        switch piece.kind {
        case .pawn: kind = 1
        case .knight: kind = 2
        case .bishop: kind = 3
        case .rook: kind = 4
        case .queen: kind = 5
        case .king: kind = 6
        }
        return kind + (piece.color == .black ? 6 : 0)
    }

    private static func appendUnique(_ appearance: [Float], to references: inout [[Float]]) {
        // Empty squares and same-theme pieces often have exactly identical features.
        // Removing duplicates cannot affect their minimum distance or classification.
        if !references.contains(appearance) { references.append(appearance) }
    }

    private static func minimumDistance(_ appearance: [Float], to references: [[Float]]) -> Double {
        guard !references.isEmpty else { return 1 }
        var best = Double.infinity
        for reference in references {
            guard !appearance.isEmpty, appearance.count == reference.count else {
                best = min(best, 1)
                continue
            }
            let limit = best * Double(appearance.count)
            var sum = 0.0
            var index = 0
            // Squared errors never decrease. Once a partial sum exceeds the best
            // complete match, this reference cannot improve it. Use the same Float
            // subtraction and Double accumulation as BoardVision.distance.
            while index < appearance.count && sum <= limit {
                let end = min(index + 32, appearance.count)
                while index < end {
                    let difference = Double(appearance[index] - reference[index])
                    sum += difference * difference
                    index += 1
                }
            }
            if index == appearance.count { best = min(best, sum / Double(appearance.count)) }
            if best == 0 { break }
        }
        return best
    }
}

extension BoardObservation {
    /// Use the most changed square, so one moving pawn cannot disappear in a 64-square average.
    func motionDistance(to other: BoardObservation) -> Double {
        guard squares.count == 64, other.squares.count == 64 else { return 1 }
        var maximum = 0.0
        for square in 0..<64 {
            maximum = max(maximum, BoardVision.distance(squares[square], other.squares[square]))
        }
        return maximum
    }
}
