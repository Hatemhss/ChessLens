import AppKit
import XCTest
@testable import ChessLens

@MainActor
final class EditorUncertaintyTests: XCTestCase {
    private func editor(position: Position = Position(), uncertainSquares: Set<Int>) throws -> BoardEditorView {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 64 * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        return BoardEditorView(
            image: try XCTUnwrap(context.makeImage()), position: position,
            whiteAtBottom: true, uncertainSquares: uncertainSquares
        )
    }

    func testMarkingAlreadyEmptySquareResolvesOnlyThatSquareAndInvalidatesReview() throws {
        let e4 = Position.index(of: "e4")!
        let c5 = Position.index(of: "c5")!
        let view = try editor(uncertainSquares: [e4, c5])
        var changes = 0
        view.onPositionChange = { changes += 1 }

        view.setPiece(nil, at: e4)

        XCTAssertNil(view.position.board[e4])
        XCTAssertEqual(view.uncertainSquares, [c5])
        XCTAssertEqual(changes, 1, "The controller must invalidate review even when nil was already stored")
    }

    func testExplicitSamePieceConfirmationResolvesUnknownWithoutLosingHistory() throws {
        let e5 = Position.index(of: "e5")!
        let position = try XCTUnwrap(Position(fen: "4k3/8/8/3pP3/8/8/8/4K3 w - d6 7 18"))
        let view = try editor(position: position, uncertainSquares: [e5])

        view.setPiece(position.board[e5], at: e5)

        XCTAssertTrue(view.uncertainSquares.isEmpty)
        XCTAssertEqual(view.position.fen, position.fen)
    }

    func testOrientationCorrectionKeepsScreenLocationsAndClearsUnsupportedHistory() throws {
        let position = try XCTUnwrap(Position(fen: "r3k2r/8/8/3pP3/8/8/8/R3K2R w KQkq d6 7 18"))
        let e5 = Position.index(of: "e5")!
        let d6 = Position.index(of: "d6")!
        let view = try editor(position: position, uncertainSquares: [e5, d6])
        var changes = 0
        view.onPositionChange = { changes += 1 }

        view.changeOrientation(whiteAtBottom: false)

        XCTAssertFalse(view.whiteAtBottom)
        for square in 0..<64 {
            XCTAssertEqual(view.position.board[63 - square], position.board[square])
        }
        XCTAssertEqual(view.uncertainSquares, [63 - e5, 63 - d6])
        XCTAssertTrue(view.position.castling.isEmpty)
        XCTAssertNil(view.position.enPassantSquare)
        XCTAssertEqual(view.position.sideToMove, position.sideToMove)
        XCTAssertEqual(changes, 1)

        view.changeOrientation(whiteAtBottom: true)
        XCTAssertEqual(view.position.board, position.board)
        XCTAssertEqual(view.uncertainSquares, [e5, d6])
        XCTAssertTrue(view.position.castling.isEmpty, "Changing orientation back cannot restore unsupported rights")
        XCTAssertEqual(changes, 2)
    }

    func testExplicitReplacementClearsUnknownMarkersAndInvalidatesReview() throws {
        let view = try editor(uncertainSquares: [0, 12, 63])
        var changes = 0
        view.onPositionChange = { changes += 1 }

        view.replacePosition(.starting)

        XCTAssertTrue(view.uncertainSquares.isEmpty)
        XCTAssertEqual(view.position.fen, Position.starting.fen)
        XCTAssertEqual(changes, 1)

        view.replacePosition(Position())
        XCTAssertTrue(view.position.board.allSatisfy { $0 == nil })
        XCTAssertEqual(changes, 2)
    }
}
