import XCTest
@testable import ChessLens

final class ChessEngineTests: XCTestCase {
    func testStartingPositionHasTwentyLegalMoves() {
        XCTAssertEqual(Position.starting.legalMoves().count, 20)
    }

    func testStartingPositionPerftDepthTwo() {
        let nodes = Position.starting.legalMoves().reduce(0) { total, move in
            total + Position.starting.applying(move).legalMoves().count
        }
        XCTAssertEqual(nodes, 400)
    }

    func testFENRoundTrip() {
        let fen = "r3k2r/ppp2ppp/2n5/3qp3/8/2N2N2/PPP2PPP/R2Q1RK1 w kq - 2 11"
        let position = Position(fen: fen)
        XCTAssertNotNil(position)
        XCTAssertEqual(position?.fen, fen)
    }

    func testPawnCanAdvanceTwoSquares() {
        let position = Position.starting
        let moves = position.legalMoves().map(\.uci)
        XCTAssertTrue(moves.contains("e2e4"))
    }

    func testCheckmateHasNoMove() {
        let position = Position(fen: "7k/6Q1/6K1/8/8/8/8/8 b - - 0 1")!
        XCTAssertTrue(position.isKingInCheck(.black))
        XCTAssertTrue(position.legalMoves().isEmpty)
        XCTAssertNil(ChessEngine().bestMove(in: position, timeLimit: 0.05, maxDepth: 2))
    }

    func testEngineFindsMateInOne() {
        let position = Position(fen: "7k/8/5KQ1/8/8/8/8/8 w - - 0 1")!
        let result = ChessEngine().bestMove(in: position, timeLimit: 0.3, maxDepth: 3)
        XCTAssertNotNil(result)
        if let result {
            let next = position.applying(result.move)
            XCTAssertTrue(next.isKingInCheck(.black))
            XCTAssertTrue(next.legalMoves().isEmpty, "Engine chose \(result.move.uci)")
        }
    }

    func testVisualDetectorFindsPawnMove() {
        let baseline = Array(repeating: [Float(0)], count: 64)
        var observed = baseline
        observed[Position.index(of: "e2")!] = [0.25]
        observed[Position.index(of: "e4")!] = [0.30]

        let detected = VisualMoveDetector().inferMove(
            in: .starting,
            baseline: baseline,
            observed: observed
        )
        XCTAssertEqual(detected?.move.uci, "e2e4")
    }

    func testVisualDetectorRequiresBothMoveSquaresToChange() {
        let baseline = Array(repeating: [Float(0)], count: 64)
        var observed = baseline
        observed[Position.index(of: "e2")!] = [0.25]

        let detected = VisualMoveDetector().inferMove(
            in: .starting,
            baseline: baseline,
            observed: observed
        )
        XCTAssertNil(detected)
    }

    func testVisualDetectorRejectsMultipleSimultaneousChanges() {
        let baseline = Array(repeating: [Float(0)], count: 64)
        var observed = baseline
        for square in ["e2", "e4", "d2", "d4"] {
            observed[Position.index(of: square)!] = [0.30]
        }
        XCTAssertNil(VisualMoveDetector().inferMove(
            in: .starting,
            baseline: baseline,
            observed: observed
        ))
    }

    func testBoardStabilityRestartsAfterEveryVisibleChange() {
        var gate = VisualStabilityGate(startedAt: 0, quietSeconds: 2.0, changeThreshold: 0.00018)
        XCTAssertFalse(gate.observe(frameDistance: 0, at: 1.5))
        XCTAssertFalse(gate.observe(frameDistance: 0.00030, at: 1.8))
        XCTAssertFalse(gate.observe(frameDistance: 0, at: 3.3))
        XCTAssertTrue(gate.observe(frameDistance: 0, at: 3.81))
    }

    func testVisualDetectorCanFollowQuickOpponentReply() {
        let detector = VisualMoveDetector()
        let original = Array(repeating: [Float(0)], count: 64)
        var afterWhite = original
        for square in ["e2", "e4"] {
            afterWhite[Position.index(of: square)!] = [0.30]
        }
        let first = detector.inferMove(in: .starting, baseline: original, observed: afterWhite)
        XCTAssertEqual(first?.move.uci, "e2e4")
        var afterBlack = afterWhite
        for square in ["e7", "e5"] {
            afterBlack[Position.index(of: square)!] = [0.30]
        }
        if let first {
            let reply = detector.inferMove(
                in: Position.starting.applying(first.move),
                baseline: afterWhite,
                observed: afterBlack
            )
            XCTAssertEqual(reply?.move.uci, "e7e5")
        }
    }

    func testVisualDetectorFindsCastling() {
        let position = Position(fen: "4k3/8/8/8/8/8/8/4K2R w K - 0 1")!
        let baseline = Array(repeating: [Float(0)], count: 64)
        var observed = baseline
        for square in ["e1", "g1", "h1", "f1"] {
            observed[Position.index(of: square)!] = [0.30]
        }

        let detected = VisualMoveDetector().inferMove(
            in: position,
            baseline: baseline,
            observed: observed
        )
        XCTAssertEqual(detected?.move.uci, "e1g1")
    }

    func testStockfishReturnsLegalMove() throws {
        let result = StockfishEngine().bestMove(in: .starting, timeMilliseconds: 150)
        XCTAssertNotNil(result, "The bundled Stockfish engine should launch and answer UCI commands")
        if let result {
            XCTAssertTrue(Position.starting.legalMoves().contains(result.move))
            XCTAssertGreaterThan(result.depth, 0)
        }
    }

    func testStructuralValidationRejectsRecognitionNoise() {
        var position = Position.starting
        position.board[16] = Piece(color: .white, kind: .king)
        XCTAssertFalse(position.isStructurallyPlausible)
        XCTAssertNotNil(position.validationIssue)
    }
}
