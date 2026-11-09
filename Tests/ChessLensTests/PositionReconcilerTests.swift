import CoreGraphics
import ImageIO
import XCTest
@testable import ChessLens

final class PositionReconcilerTests: XCTestCase {
    private let labels = Array(".PNBRQKpnbrqk")

    private func observation(_ position: Position) -> BoardObservation {
        BoardObservation(squares: position.board.map { piece in
            var vector = [Float](repeating: 0, count: labels.count)
            vector[labels.firstIndex(of: piece?.fenCharacter ?? ".")!] = 1
            return vector
        })
    }

    private func apply(_ uci: String, to position: Position) throws -> Position {
        let move = try XCTUnwrap(position.legalMoves().first { $0.uci == uci })
        return position.applying(move)
    }

    func testReconciliationReleaseBenchmark() throws {
        guard ProcessInfo.processInfo.environment["CHESSLENS_BENCHMARK"] == "1" else {
            throw XCTSkip("Opt-in release benchmark: CHESSLENS_BENCHMARK=1 swift test -c release --filter testReconciliationReleaseBenchmark")
        }
        let fixture = try XCTUnwrap(Bundle.module.url(
            forResource: "fast-pawn-reply", withExtension: "png", subdirectory: "Fixtures"
        ))
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(fixture as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let board = try XCTUnwrap(image.cropping(to: CGRect(x: 51, y: 107, width: 1171, height: 1172)))
        let observed = try XCTUnwrap(BoardVision().observe(image: board, whiteAtBottom: true))
        var initial = observed.squares
        for (destination, sourceSquare) in [("e2", "g2"), ("e7", "g7"), ("e4", "a4"), ("e5", "a5")] {
            initial[Position.index(of: destination)!] = observed.squares[Position.index(of: sourceSquare)!]
        }
        let baseline = BoardObservation(squares: initial)
        let model = SessionBoardModel(position: .starting, observation: baseline)
        for (name, sample) in [("idle", baseline), ("two-ply", observed)] {
            var times = [Double]()
            for iteration in 0..<35 {
                let start = ProcessInfo.processInfo.systemUptime
                let result = try XCTUnwrap(model.reconcile(position: .starting, baseline: baseline, observed: sample))
                let elapsed = ProcessInfo.processInfo.systemUptime - start
                XCTAssertEqual(result.moves.count, name == "idle" ? 0 : 2)
                if iteration >= 5 { times.append(elapsed * 1_000) }
            }
            times.sort()
            print("RECONCILER_BENCHMARK \(name) median_ms=\(times[times.count / 2]) p95_ms=\(times[Int(Double(times.count) * 0.95)])")
        }
    }

    func testRecoversBothPawnMovesWithoutIntermediateFrame() throws {
        let baseline = observation(.starting)
        let afterWhite = try apply("e2e4", to: .starting)
        let expected = try apply("e7e5", to: afterWhite)
        let model = SessionBoardModel(position: .starting, observation: baseline)
        let result = try XCTUnwrap(model.reconcile(
            position: .starting, baseline: baseline, observed: observation(expected)
        ))

        XCTAssertEqual(result.moves.map(\.uci), ["e2e4", "e7e5"])
        XCTAssertEqual(result.position.fen, expected.fen)
        XCTAssertEqual(result.position.sideToMove, .white)
        XCTAssertEqual(result.position.enPassantSquare, Position.index(of: "e6"))
        XCTAssertEqual(result.position.fullmoveNumber, 2)
    }

    func testSingleMoveWaitsForOpponentAndPreservesEnPassant() throws {
        let baseline = observation(.starting)
        let expected = try apply("e2e4", to: .starting)
        let result = try XCTUnwrap(SessionBoardModel(position: .starting, observation: baseline).reconcile(
            position: .starting, baseline: baseline, observed: observation(expected)
        ))

        XCTAssertEqual(result.moves.map(\.uci), ["e2e4"])
        XCTAssertEqual(result.position.sideToMove, .black)
        XCTAssertEqual(result.position.enPassantSquare, Position.index(of: "e3"))
        XCTAssertEqual(result.position.fen, expected.fen)
    }

    func testZeroPlyLimitNeverAcceptsMovedBoard() throws {
        let baseline = observation(.starting)
        let expected = try apply("e2e4", to: .starting)
        let model = SessionBoardModel(position: .starting, observation: baseline)
        XCTAssertNil(model.reconcile(
            position: .starting, baseline: baseline, observed: observation(expected), maximumPlies: 0
        ))
        XCTAssertEqual(model.reconcile(
            position: .starting, baseline: baseline, observed: baseline, maximumPlies: 0
        )?.position.fen, Position.starting.fen)
    }

    func testOnePlyLimitCannotSkipOpponentReply() throws {
        let baseline = observation(.starting)
        let afterWhite = try apply("e2e4", to: .starting)
        let afterBlack = try apply("e7e5", to: afterWhite)
        let model = SessionBoardModel(position: .starting, observation: baseline)
        XCTAssertNil(model.reconcile(
            position: .starting, baseline: baseline, observed: observation(afterBlack), maximumPlies: 1
        ))
    }

    func testIdenticalAppearanceInFreshBuffersPreservesMetadata() throws {
        let position = try XCTUnwrap(Position(fen: "r3k2r/8/8/3pP3/8/8/8/R3K2R w - d6 0 18"))
        let baseline = observation(position)
        let separateSnapshot = BoardObservation(squares: baseline.squares.map { vector in
            vector.map { value in value }
        })
        let model = SessionBoardModel(position: position, observation: baseline)
        let result = try XCTUnwrap(model.reconcile(
            position: position, baseline: baseline, observed: separateSnapshot
        ))
        XCTAssertTrue(result.moves.isEmpty)
        XCTAssertEqual(result.position.fen, position.fen)
    }

    func testNoisyAppearancesRecoverEveryLegalOpeningMoveAndReply() throws {
        // Dense features exercise early-abandoned distance scans, without assuming
        // exact pixel equality between identical pieces on different squares.
        func noisyObservation(_ position: Position, phase: Int) -> BoardObservation {
            BoardObservation(squares: position.board.enumerated().map { square, piece in
                let label = labels.firstIndex(of: piece?.fenCharacter ?? ".")!
                return (0..<130).map { channel in
                    let value: Float = channel % labels.count == label ? 1 : 0
                    let noise = Float((square * 7 + channel * 3 + phase) % 11 - 5) * 0.001
                    return value + noise
                }
            })
        }
        let baseline = noisyObservation(.starting, phase: 0)
        let model = SessionBoardModel(position: .starting, observation: baseline)
        for firstMove in Position.starting.legalMoves() {
            let afterWhite = Position.starting.applying(firstMove)
            let expected = try apply("e7e5", to: afterWhite)
            let result = try XCTUnwrap(model.reconcile(
                position: .starting, baseline: baseline,
                observed: noisyObservation(expected, phase: 5)
            ), "Could not recover \(firstMove.uci), e7e5")
            XCTAssertEqual(result.moves.map(\.uci), [firstMove.uci, "e7e5"])
            XCTAssertEqual(result.position.fen, expected.fen)
        }
    }

    func testUnchangedPositionDoesNotRestoreLostCastlingRights() throws {
        let position = try XCTUnwrap(Position(fen: "r3k2r/8/8/8/8/8/8/R3K2R b - - 5 14"))
        let baseline = observation(position)
        let result = try XCTUnwrap(SessionBoardModel(position: position, observation: baseline).reconcile(
            position: position, baseline: baseline, observed: baseline
        ))

        XCTAssertTrue(result.moves.isEmpty)
        XCTAssertEqual(result.position.fen, position.fen)
    }

    func testRecoversTwoCastlesAndTheirRooks() throws {
        let position = try XCTUnwrap(Position(fen: "r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1"))
        let baseline = observation(position)
        let afterWhite = try apply("e1g1", to: position)
        let expected = try apply("e8c8", to: afterWhite)
        let result = try XCTUnwrap(SessionBoardModel(position: position, observation: baseline).reconcile(
            position: position, baseline: baseline, observed: observation(expected)
        ))

        XCTAssertEqual(result.moves.map(\.uci), ["e1g1", "e8c8"])
        XCTAssertEqual(result.position.fen, expected.fen)
        XCTAssertTrue(result.position.castling.isEmpty)
    }

    func testEnPassantRemovesPawnFromThirdSquare() throws {
        let position = try XCTUnwrap(Position(fen: "4k3/8/8/3pP3/8/8/8/4K3 w - d6 0 12"))
        let baseline = observation(position)
        let expected = try apply("e5d6", to: position)
        let result = try XCTUnwrap(SessionBoardModel(position: position, observation: baseline).reconcile(
            position: position, baseline: baseline, observed: observation(expected)
        ))

        XCTAssertEqual(result.moves.map(\.uci), ["e5d6"])
        XCTAssertNil(result.position.board[Position.index(of: "d5")!])
        XCTAssertNil(result.position.enPassantSquare)
        XCTAssertEqual(result.position.fen, expected.fen)
    }

    func testCaptureUsesFinalPieceColorAtDestination() throws {
        let position = try XCTUnwrap(Position(fen: "4k3/8/8/3p4/4P3/8/8/4K3 w - - 0 12"))
        let baseline = observation(position)
        let expected = try apply("e4d5", to: position)
        let result = try XCTUnwrap(SessionBoardModel(position: position, observation: baseline).reconcile(
            position: position, baseline: baseline, observed: observation(expected)
        ))

        XCTAssertEqual(result.moves.map(\.uci), ["e4d5"])
        XCTAssertEqual(result.position.fen, expected.fen)
    }

    func testRejectsIllegalFinalPosition() {
        let baseline = observation(.starting)
        var impossible = Position.starting
        impossible.board[Position.index(of: "e5")!] = impossible.board[Position.index(of: "e2")!]
        impossible.board[Position.index(of: "e2")!] = nil
        XCTAssertNil(SessionBoardModel(position: .starting, observation: baseline).reconcile(
            position: .starting, baseline: baseline, observed: observation(impossible)
        ))
    }

    func testRejectsAmbiguousKnightDestination() {
        let baseline = observation(.starting)
        var uncertain = baseline.squares
        let empty = baseline.squares[Position.index(of: "a3")!]
        let knight = baseline.squares[Position.index(of: "b1")!]
        let blurred = zip(empty, knight).map { ($0 + $1) * 0.5 }
        uncertain[Position.index(of: "b1")!] = empty
        uncertain[Position.index(of: "a3")!] = blurred
        uncertain[Position.index(of: "c3")!] = blurred

        XCTAssertNil(SessionBoardModel(position: .starting, observation: baseline).reconcile(
            position: .starting, baseline: baseline, observed: BoardObservation(squares: uncertain)
        ))
    }

    func testRealScreenshotRecoversFastPawnReplyDespiteHighlightsAndBadges() throws {
        let fixture = try XCTUnwrap(Bundle.module.url(
            forResource: "fast-pawn-reply", withExtension: "png", subdirectory: "Fixtures"
        ))
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(fixture as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let board = try XCTUnwrap(image.cropping(to: CGRect(x: 51, y: 107, width: 1171, height: 1172)))
        let observed = try XCTUnwrap(BoardVision().observe(image: board, whiteAtBottom: true))

        // Reconstruct only the initial pawn locations using unedited square appearances
        // from this screenshot. No intermediate e4 capture is supplied to the tracker.
        var initialSquares = observed.squares
        for (destination, sourceSquare) in [("e2", "g2"), ("e7", "g7"), ("e4", "a4"), ("e5", "a5")] {
            initialSquares[Position.index(of: destination)!] = observed.squares[Position.index(of: sourceSquare)!]
        }
        let baseline = BoardObservation(squares: initialSquares)
        let result = try XCTUnwrap(SessionBoardModel(position: .starting, observation: baseline).reconcile(
            position: .starting, baseline: baseline, observed: observed
        ), "The real e4/e5 board must be recognized even when both moves occur between captures")
        let expected = try apply("e7e5", to: apply("e2e4", to: .starting))

        XCTAssertEqual(result.moves.map(\.uci), ["e2e4", "e7e5"])
        XCTAssertEqual(result.position.fen, expected.fen)
        XCTAssertEqual(result.position.sideToMove, .white)
        let suggestion = try XCTUnwrap(StockfishEngine().bestMove(in: result.position, timeMilliseconds: 150))
        XCTAssertTrue(result.position.legalMoves().contains(suggestion.move))
        XCTAssertEqual(result.position.board[suggestion.move.from]?.color, .white)
    }
}
