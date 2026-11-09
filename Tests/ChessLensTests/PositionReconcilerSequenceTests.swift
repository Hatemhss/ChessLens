import CoreGraphics
import ImageIO
import XCTest
@testable import ChessLens

final class PositionReconcilerSequenceTests: XCTestCase {
    private func fixtures() throws -> (start: BoardObservation, afterWhite: BoardObservation, afterBlack: BoardObservation) {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "fast-pawn-reply", withExtension: "png", subdirectory: "Fixtures"
        ))
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let board = try XCTUnwrap(image.cropping(to: CGRect(x: 51, y: 107, width: 1171, height: 1172)))
        let afterBlack = try XCTUnwrap(BoardVision().observe(image: board, whiteAtBottom: true))
        var start = afterBlack.squares
        for (destination, sourceSquare) in [("e2", "g2"), ("e7", "g7"), ("e4", "a4"), ("e5", "a5")] {
            start[Position.index(of: destination)!] = afterBlack.squares[Position.index(of: sourceSquare)!]
        }
        var afterWhite = afterBlack.squares
        for square in ["e7", "e5"] {
            afterWhite[Position.index(of: square)!] = start[Position.index(of: square)!]
        }
        return (BoardObservation(squares: start), BoardObservation(squares: afterWhite), afterBlack)
    }

    func testRealPieceSequenceWaitsForOpponentThenResumesOwnTurn() throws {
        let frames = try fixtures()
        let model = SessionBoardModel(position: .starting, observation: frames.start)
        let ownMove = try XCTUnwrap(model.reconcile(
            position: .starting, baseline: frames.start, observed: frames.afterWhite
        ))
        XCTAssertEqual(ownMove.moves.map(\.uci), ["e2e4"])
        XCTAssertEqual(ownMove.position.sideToMove, .black)

        // A stationary opponent turn must not be mistaken for another move.
        let unchanged = try XCTUnwrap(model.reconcile(
            position: ownMove.position, baseline: frames.afterWhite, observed: frames.afterWhite
        ))
        XCTAssertTrue(unchanged.moves.isEmpty)
        XCTAssertEqual(unchanged.position.fen, ownMove.position.fen)

        let reply = try XCTUnwrap(model.reconcile(
            position: ownMove.position, baseline: frames.afterWhite, observed: frames.afterBlack
        ))
        XCTAssertEqual(reply.moves.map(\.uci), ["e7e5"])
        XCTAssertEqual(reply.position.sideToMove, .white)
        XCTAssertEqual(reply.position.fen, "rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq e6 0 2")
    }

    func testOccludedFrameDoesNotPoisonFollowingCleanCapture() throws {
        let frames = try fixtures()
        let model = SessionBoardModel(position: .starting, observation: frames.start)
        var occluded = frames.afterBlack.squares
        // An unrelated foreground overlay on empty squares is not a legal move.
        for square in ["c4", "d4", "f4"] {
            let index = Position.index(of: square)!
            occluded[index] = [Float](repeating: 1, count: occluded[index].count)
        }
        XCTAssertNil(model.reconcile(
            position: .starting, baseline: frames.start,
            observed: BoardObservation(squares: occluded)
        ))

        let clean = try XCTUnwrap(model.reconcile(
            position: .starting, baseline: frames.start, observed: frames.afterBlack
        ))
        XCTAssertEqual(clean.moves.map(\.uci), ["e2e4", "e7e5"])
        XCTAssertEqual(clean.position.sideToMove, .white)
    }

    func testBriefMissingPawnFrameDoesNotAdvanceTurnAndCleanReplyRecovers() throws {
        let frames = try fixtures()
        let model = SessionBoardModel(position: .starting, observation: frames.start)
        let ownMove = try XCTUnwrap(model.reconcile(
            position: .starting, baseline: frames.start, observed: frames.afterWhite
        ))
        var inFlight = frames.afterBlack.squares
        inFlight[Position.index(of: "e5")!] = frames.start.squares[Position.index(of: "e5")!]
        XCTAssertNil(model.reconcile(
            position: ownMove.position, baseline: frames.afterWhite,
            observed: BoardObservation(squares: inFlight)
        ), "A black pawn absent from both its origin and destination is not a completed legal move")

        let reply = try XCTUnwrap(model.reconcile(
            position: ownMove.position, baseline: frames.afterWhite, observed: frames.afterBlack
        ))
        XCTAssertEqual(reply.moves.map(\.uci), ["e7e5"])
        XCTAssertEqual(reply.position.sideToMove, .white)
    }
}
