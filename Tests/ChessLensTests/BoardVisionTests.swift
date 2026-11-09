import CoreGraphics
import ImageIO
import XCTest
@testable import ChessLens

final class BoardVisionTests: XCTestCase {
    func testPieceAppearanceIgnoresBackgroundAndCornerBadge() throws {
        for isWhite in [true, false] {
            let ordinary = try observation(background: cream, isWhite: isWhite)
            let green = try observation(background: green, isWhite: isWhite)
            let highlighted = try observation(background: yellow, isWhite: isWhite, badge: true)
            let empty = try observation(background: yellow, isWhite: nil, badge: true)
            let pieceSquare = Position.index(of: "e4")!
            let reference = ordinary.squares[pieceSquare]
            XCTAssertLessThan(BoardVision.distance(reference, green.squares[pieceSquare]), 0.012)
            XCTAssertLessThan(BoardVision.distance(reference, highlighted.squares[pieceSquare]), 0.012)
            XCTAssertGreaterThan(BoardVision.distance(reference, empty.squares[pieceSquare]), 0.04)
            XCTAssertLessThan(BoardVision.distance(empty.squares[pieceSquare], empty.squares[0]), 0.002)
        }
    }

    func testPieceColorRemainsDistinguishable() throws {
        let white = try observation(background: cream, isWhite: true)
        let black = try observation(background: cream, isWhite: false)
        let square = Position.index(of: "e4")!
        XCTAssertGreaterThan(BoardVision.distance(white.squares[square], black.squares[square]), 0.020)
    }

    func testChessSquareMappingForEitherOrientationAndScale() throws {
        let normal = try observation(background: cream, isWhite: true)
        let flipped = try observation(background: green, isWhite: true, whiteAtBottom: false, squareSize: 97)
        let square = Position.index(of: "e4")!
        XCTAssertLessThan(BoardVision.distance(normal.squares[square], flipped.squares[square]), 0.012)
        for index in 0..<64 where index != square {
            XCTAssertLessThan(BoardVision.distance(normal.squares[index], flipped.squares[index]), 0.002)
            XCTAssertGreaterThan(BoardVision.distance(normal.squares[square], flipped.squares[index]), 0.04)
        }
    }

    func testInvalidAppearancesDoNotMatch() {
        XCTAssertEqual(BoardVision.distance([], []), 1)
        XCTAssertEqual(BoardVision.distance([0], [0, 1]), 1)
    }

    func testPawnAnimationThenCornerBadgeAllowsContinuousQuietInterval() throws {
        let before = try observation(background: cream, isWhite: true, pieceSquare: "e2")
        let moving = try observation(background: cream, isWhite: true, pieceSquare: "e3", pawnOffset: -0.18)
        let final = try observation(background: yellow, isWhite: true, pieceSquare: "e4")
        let finalWithBadge = try observation(background: yellow, isWhite: true, badge: true, pieceSquare: "e4")
        let threshold = 0.002
        var gate = VisualStabilityGate(startedAt: 0, quietSeconds: 2, changeThreshold: threshold)

        XCTAssertGreaterThan(before.motionDistance(to: moving), threshold)
        XCTAssertGreaterThan(moving.motionDistance(to: final), threshold)
        XCTAssertFalse(gate.observe(frameDistance: before.motionDistance(to: moving), at: 0.2))
        XCTAssertFalse(gate.observe(frameDistance: moving.motionDistance(to: final), at: 0.4))
        XCTAssertFalse(gate.observe(frameDistance: final.motionDistance(to: final), at: 1.8))
        // Move-quality icons may blink after the piece has landed. Their masked corner
        // pixels must not postpone stability or hide the next suggestion indefinitely.
        XCTAssertLessThan(final.motionDistance(to: finalWithBadge), threshold)
        XCTAssertFalse(gate.observe(frameDistance: final.motionDistance(to: finalWithBadge), at: 2.2))
        XCTAssertTrue(gate.observe(frameDistance: finalWithBadge.motionDistance(to: final), at: 2.41))
    }

    func testRepeatedRealScreenshotDoesNotCreateArtificialMotion() throws {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "fast-pawn-reply", withExtension: "png", subdirectory: "Fixtures"
        ))
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let board = try XCTUnwrap(image.cropping(to: CGRect(x: 51, y: 107, width: 1171, height: 1172)))
        let vision = BoardVision()
        let baseline = try XCTUnwrap(vision.observe(image: board, whiteAtBottom: true))
        for _ in 0..<4 {
            let repeated = try XCTUnwrap(vision.observe(image: board, whiteAtBottom: true))
            XCTAssertEqual(baseline.motionDistance(to: repeated), 0)
        }
    }

    private let cream = CGColor(red: 0.93, green: 0.94, blue: 0.80, alpha: 1)
    private let green = CGColor(red: 0.45, green: 0.58, blue: 0.30, alpha: 1)
    private let yellow = CGColor(red: 0.86, green: 0.89, blue: 0.22, alpha: 1)

    private func observation(
        background: CGColor, isWhite: Bool?, badge: Bool = false,
        whiteAtBottom: Bool = true, squareSize: Int = 80,
        pieceSquare: String = "e4", pawnOffset: CGFloat = 0
    ) throws -> BoardObservation {
        let size = squareSize * 8
        let context = try XCTUnwrap(CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(background)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        context.translateBy(x: 0, y: CGFloat(size))
        context.scaleBy(x: 1, y: -1)
        let square = try XCTUnwrap(Position.index(of: pieceSquare))
        let file = square % 8
        let rank = square / 8
        let column = whiteAtBottom ? file : 7 - file
        let row = whiteAtBottom ? 7 - rank : rank
        context.translateBy(x: CGFloat(column * squareSize), y: CGFloat(row * squareSize))
        context.scaleBy(x: CGFloat(squareSize), y: CGFloat(squareSize))
        if let isWhite {
            context.saveGState()
            context.translateBy(x: 0, y: pawnOffset)
            context.setFillColor(isWhite
                ? CGColor(gray: 0.97, alpha: 1) : CGColor(gray: 0.30, alpha: 1))
            context.setStrokeColor(CGColor(gray: 0.13, alpha: 1))
            context.setLineWidth(0.025)
            // A closed, outlined pawn silhouette with a near-background white interior.
            context.addEllipse(in: CGRect(x: 0.36, y: 0.16, width: 0.28, height: 0.28))
            context.drawPath(using: .fillStroke)
            context.move(to: CGPoint(x: 0.42, y: 0.39))
            context.addLine(to: CGPoint(x: 0.37, y: 0.60))
            context.addLine(to: CGPoint(x: 0.24, y: 0.80))
            context.addLine(to: CGPoint(x: 0.24, y: 0.86))
            context.addLine(to: CGPoint(x: 0.76, y: 0.86))
            context.addLine(to: CGPoint(x: 0.76, y: 0.80))
            context.addLine(to: CGPoint(x: 0.63, y: 0.60))
            context.addLine(to: CGPoint(x: 0.58, y: 0.39))
            context.closePath()
            context.drawPath(using: .fillStroke)
            context.restoreGState()
        }
        if badge {
            context.setFillColor(CGColor(red: 0.88, green: 0.50, blue: 0.15, alpha: 1))
            context.fillEllipse(in: CGRect(x: 0.77, y: 0, width: 0.23, height: 0.23))
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0.84, y: 0.05, width: 0.06, height: 0.10))
            context.fill(CGRect(x: 0.03, y: 0.06, width: 0.05, height: 0.13))
            context.fill(CGRect(x: 0.87, y: 0.91, width: 0.06, height: 0.07))
        }
        return try XCTUnwrap(BoardVision().observe(
            image: XCTUnwrap(context.makeImage()), whiteAtBottom: whiteAtBottom
        ))
    }
}
