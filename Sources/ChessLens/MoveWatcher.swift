import Foundation

/// A board is ready only after a continuous quiet interval. Any new visible
/// change restarts the interval, so a slow animation cannot pass a fixed timer.
struct VisualStabilityGate {
    let quietSeconds: TimeInterval
    let changeThreshold: Double
    private(set) var lastChangeAt: TimeInterval

    init(startedAt: TimeInterval, quietSeconds: TimeInterval, changeThreshold: Double) {
        self.quietSeconds = quietSeconds
        self.changeThreshold = changeThreshold
        self.lastChangeAt = startedAt
    }

    mutating func observe(frameDistance: Double, at time: TimeInterval) -> Bool {
        if frameDistance >= changeThreshold {
            lastChangeAt = time
        }
        return time - lastChangeAt >= quietSeconds
    }
}

struct DetectedBoardMove: Equatable {
    let move: ChessMove
    let confidence: Double
}

/// Infers one legal move from visual changes between two stable board captures.
/// Working from legal moves makes it robust to last-move highlights and board themes.
struct VisualMoveDetector {
    func inferMove(
        in position: Position,
        baseline: [[Float]],
        observed: [[Float]]
    ) -> DetectedBoardMove? {
        guard baseline.count == 64, observed.count == 64 else { return nil }
        let changes = zip(baseline, observed).map(vectorDistance)
        guard let largest = changes.max(), largest > 0.0012 else { return nil }

        var ranked: [(ChessMove, Double)] = []
        for move in position.legalMoves() {
            let expected = changedSquares(for: move, in: position)
            let expectedValues = expected.map { changes[$0] }
            guard expectedValues.count >= 2,
                  let weakestExpected = expectedValues.min(),
                  weakestExpected > max(0.00022, largest * 0.18) else { continue }

            let expectedAverage = expectedValues.reduce(0, +) / Double(expectedValues.count)
            let unexpectedPeak = changes.enumerated()
                .filter { !expected.contains($0.offset) }
                .map(\.element)
                .max() ?? 0
            // A move changes its own squares. Substantial changes elsewhere mean the
            // board is still animating, shifted, or no longer matches this position.
            guard unexpectedPeak < max(0.0012, expectedAverage * 0.65) else { continue }
            let score = expectedAverage - unexpectedPeak * 0.28
            ranked.append((move, score))
        }

        let sorted = ranked.sorted { $0.1 > $1.1 }
        guard let best = sorted.first, best.1 > 0.00055 else { return nil }
        let runnerUp = sorted.dropFirst().first?.1 ?? 0
        let separation = max(0, best.1 - runnerUp)
        let confidence = min(1, 0.55 + separation / 0.004 + best.1 / 0.035)
        return DetectedBoardMove(move: best.0, confidence: confidence)
    }

    func frameDistance(_ lhs: [[Float]], _ rhs: [[Float]]) -> Double {
        guard lhs.count == 64, rhs.count == 64 else { return 1 }
        return zip(lhs, rhs).map(vectorDistance).reduce(0, +) / 64
    }

    private func changedSquares(for move: ChessMove, in position: Position) -> Set<Int> {
        var squares: Set<Int> = [move.from, move.to]
        if move.isEnPassant, let piece = position.board[move.from] {
            squares.insert(move.to + (piece.color == .white ? -8 : 8))
        }
        if move.isCastle {
            switch move.to {
            case 6: squares.formUnion([7, 5])
            case 2: squares.formUnion([0, 3])
            case 62: squares.formUnion([63, 61])
            case 58: squares.formUnion([56, 59])
            default: break
            }
        }
        return squares
    }

    private func vectorDistance(_ lhs: [Float], _ rhs: [Float]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return 1 }
        var sum = 0.0
        for index in lhs.indices {
            let delta = Double(lhs[index] - rhs[index])
            sum += delta * delta
        }
        return sum / Double(lhs.count)
    }
}
