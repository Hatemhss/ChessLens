import CoreGraphics
import ImageIO
import XCTest
@testable import ChessLens

final class BoardScannerTests: XCTestCase {
    private final class MemoryDefaults: UserDefaults {
        private var values: [String: Any] = [:]
        override func data(forKey defaultName: String) -> Data? { values[defaultName] as? Data }
        override func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
        override func removeObject(forKey defaultName: String) { values.removeValue(forKey: defaultName) }
    }

    private func fixture(_ name: String, crop: CGRect) throws -> CGImage {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "Fixtures"))
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return try XCTUnwrap(image.cropping(to: crop))
    }

    private func endgameImage() throws -> CGImage {
        try fixture("endgame-rescan", crop: CGRect(x: 51, y: 104, width: 1196, height: 1196))
    }

    private var endgame: Position {
        Position(fen: "8/8/4K3/r1k5/8/1PP5/8/8 w - - 0 1")!
    }

    func testBundledShapesRecognizeIndependentEndgameWithoutUserTraining() throws {
        let scanner = BoardScanner(defaults: MemoryDefaults())
        let scan = try XCTUnwrap(scanner.predict(image: endgameImage(), whiteAtBottom: true, sideToMove: .white))
        // This image is held out of the bundled reference samples. Its stale editor badges
        // mark unrelated empty cells; the actual image contains only these five pieces.
        XCTAssertEqual(scan.position.board, endgame.board)
        XCTAssertEqual(scan.position.board.compactMap { $0 }.count, 5)
        // A correct nearest match may still request review when two shapes are similar;
        // do not weaken ambiguity thresholds merely to remove an accurate review marker.
        XCTAssertTrue(scan.uncertainSquares.allSatisfy { endgame.board[$0] != nil })
        XCTAssertGreaterThan(scan.confidence, 0.70)
        XCTAssertTrue(scan.position.castling.isEmpty)
    }

    func testReferenceThemeIncludesEveryPieceKindAndBothColors() throws {
        let board = try fixture("fast-pawn-reply", crop: CGRect(x: 51, y: 107, width: 1171, height: 1172))
        let expected = try XCTUnwrap(Position(fen: "rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq e6 0 2"))
        let scanner = BoardScanner(defaults: MemoryDefaults())
        let scan = try XCTUnwrap(scanner.predict(image: board, whiteAtBottom: true, sideToMove: .white))
        XCTAssertEqual(scan.position.board, expected.board)
        XCTAssertTrue(scan.uncertainSquares.isEmpty)
        XCTAssertEqual(Set(scan.position.board.compactMap { $0?.fenCharacter }).count, 12)
        XCTAssertTrue(scanner.learningIssues(image: board, position: expected, whiteAtBottom: true).isEmpty)
    }

    func testOrientationMapsEveryCellWithoutSwappingPieceColor() throws {
        let scanner = BoardScanner(defaults: MemoryDefaults())
        let scan = try XCTUnwrap(scanner.predict(image: endgameImage(), whiteAtBottom: false, sideToMove: .black))
        XCTAssertEqual(scan.position.board, Array(endgame.board.reversed()))
        XCTAssertEqual(scan.position.sideToMove, .black)
    }

    func testCorruptLegacySamplesAreIgnoredAndRetainedForRecovery() throws {
        let defaults = MemoryDefaults()
        let legacy = try JSONEncoder().encode(Array(repeating: LearnedTemplate(label: "p", vector: [1, 1, 1]), count: 312))
        defaults.set(legacy, forKey: "ChessLens.learnedTemplates.v2")
        let scanner = BoardScanner(defaults: defaults)
        let scan = try XCTUnwrap(scanner.predict(image: endgameImage(), whiteAtBottom: true, sideToMove: .white))
        XCTAssertEqual(scan.position.board, endgame.board)
        XCTAssertTrue(scanner.learnedSummary.contains("0 confirmed samples"))
        scanner.reset()
        XCTAssertEqual(defaults.data(forKey: "ChessLens.learnedTemplates.v2"), legacy)
        XCTAssertTrue(scanner.hasTraining, "Resetting personal samples retains the known-theme starter set")
    }

    func testLearningRejectsStaleBadgesAtomically() throws {
        let defaults = MemoryDefaults()
        let scanner = BoardScanner(defaults: defaults)
        let stale = try XCTUnwrap(Position(fen: "5k2/8/6KP/1N6/8/8/8/8 b - - 0 5"))
        let image = try endgameImage()
        let issues = scanner.learningIssues(image: image, position: stale, whiteAtBottom: true)
        XCTAssertTrue(issues.contains(Position.index(of: "f8")!), "A king label on empty f8 must be rejected")
        XCTAssertTrue(issues.contains(Position.index(of: "e6")!), "An unlabeled visible king must be rejected")
        let learned = scanner.learn(image: image, position: stale, whiteAtBottom: true)
        XCTAssertFalse(learned.accepted)
        XCTAssertEqual(learned.rejectedSquares, issues)
        XCTAssertTrue(learned.learnedSquares.isEmpty)
        XCTAssertNil(defaults.data(forKey: "ChessLens.learnedTemplates.v3"))
    }

    func testConfirmedSamplesPersistAndReload() throws {
        let defaults = MemoryDefaults()
        let scanner = BoardScanner(defaults: defaults, bundledTemplates: [])
        let image = try endgameImage()
        XCTAssertTrue(scanner.learningIssues(image: image, position: endgame, whiteAtBottom: true).isEmpty)
        let learned = scanner.learn(image: image, position: endgame, whiteAtBottom: true)
        XCTAssertTrue(learned.accepted)
        XCTAssertEqual(learned.learnedSquares.count, 64)
        XCTAssertNotNil(defaults.data(forKey: "ChessLens.learnedTemplates.v3"))
        let reloaded = BoardScanner(defaults: defaults, bundledTemplates: [])
        let scan = try XCTUnwrap(reloaded.predict(image: image, whiteAtBottom: true, sideToMove: .white))
        XCTAssertEqual(scan.position.board, endgame.board)
        XCTAssertTrue(scan.uncertainSquares.isEmpty)
    }

    func testUnknownPiecesCannotBeHiddenByManyConfidentEmptySquares() throws {
        let scanner = BoardScanner(defaults: MemoryDefaults(), bundledTemplates: [])
        let scan = try XCTUnwrap(scanner.predict(image: endgameImage(), whiteAtBottom: true, sideToMove: .white))
        let occupied = Set(endgame.board.indices.filter { endgame.board[$0] != nil })
        XCTAssertEqual(Set(scan.uncertainSquares), occupied)
        XCTAssertLessThan(scan.confidence, 0.20)
        XCTAssertTrue(scan.position.board.allSatisfy { $0 == nil })
    }

    func testUnfamiliarForegroundIsMarkedUncertain() throws {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 640, height: 640, bitsPerComponent: 8, bytesPerRow: 640 * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.45, green: 0.58, blue: 0.30, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 640, height: 640))
        context.setFillColor(CGColor(red: 0.93, green: 0.08, blue: 0.13, alpha: 1))
        context.fillEllipse(in: CGRect(x: 330, y: 250, width: 60, height: 60))
        let image = try XCTUnwrap(context.makeImage())
        let scanner = BoardScanner(defaults: MemoryDefaults())
        let scan = try XCTUnwrap(scanner.predict(image: image, whiteAtBottom: true, sideToMove: .white))
        XCTAssertFalse(scan.uncertainSquares.isEmpty)
        XCTAssertLessThan(scan.confidence, 0.86)
    }

    func testExplicitPieceCorrectionReplacesContradictoryUserSample() throws {
        let defaults = MemoryDefaults()
        let image = try endgameImage()
        let scanner = BoardScanner(defaults: defaults, bundledTemplates: [])
        var incorrect = endgame
        incorrect.board[Position.index(of: "a5")!] = Piece(color: .black, kind: .bishop)
        // Geometry can reject a piece-on-empty mistake, but cannot independently know a
        // user's first explicit rook-vs-bishop label. Their subsequent correction must win.
        XCTAssertTrue(scanner.learn(image: image, position: incorrect, whiteAtBottom: true).accepted)
        XCTAssertTrue(scanner.learn(image: image, position: endgame, whiteAtBottom: true).accepted)
        let scan = try XCTUnwrap(scanner.predict(image: image, whiteAtBottom: true, sideToMove: .white))
        XCTAssertEqual(scan.position.board, endgame.board)
        XCTAssertTrue(scan.uncertainSquares.isEmpty)
    }
}
