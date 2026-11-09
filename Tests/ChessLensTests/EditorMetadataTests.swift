import XCTest
@testable import ChessLens

final class EditorMetadataTests: XCTestCase {
    func testRepaintingSamePiecePreservesFENMetadata() throws {
        var position = try XCTUnwrap(Position(fen: "r3k2r/8/8/3pP3/8/8/8/R3K2R w - d6 7 18"))
        let originalFEN = position.fen
        let square = Position.index(of: "e5")!

        position.setPieceForEditor(position.board[square], at: square)

        XCTAssertEqual(position.fen, originalFEN)
    }

    func testManualPlacementNeverGrantsCastlingAndClearsEnPassant() throws {
        var position = try XCTUnwrap(Position(fen: "r3k2r/8/8/3pP3/8/8/8/R3K2R w - d6 7 18"))
        position.setPieceForEditor(Piece(color: .white, kind: .knight), at: Position.index(of: "c3")!)

        XCTAssertTrue(position.castling.isEmpty)
        XCTAssertNil(position.enPassantSquare)
        XCTAssertEqual(position.halfmoveClock, 7)
        XCTAssertEqual(position.fullmoveNumber, 18)
    }

    func testRemovingThenReplacingRookDoesNotRestoreItsRight() {
        var position = Position.starting
        let square = Position.index(of: "h1")!
        let rook = position.board[square]
        position.setPieceForEditor(nil, at: square)
        position.setPieceForEditor(rook, at: square)

        XCTAssertFalse(position.castling.contains(.whiteKing))
        XCTAssertTrue(position.castling.contains(.whiteQueen))
        XCTAssertTrue(position.castling.contains(.blackKing))
        XCTAssertTrue(position.castling.contains(.blackQueen))
    }

    func testUnrelatedPieceEditKeepsExistingPossibleRights() {
        var position = Position.starting
        position.setPieceForEditor(nil, at: Position.index(of: "a2")!)

        XCTAssertEqual(position.castling, Position.starting.castling)
    }
}
