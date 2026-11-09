import AppKit
import XCTest
@testable import ChessLens

final class EditorLayoutTests: XCTestCase {
    @MainActor
    func testReviewControlsFitDefaultWindow() throws {
        _ = NSApplication.shared
        let context = try XCTUnwrap(CGContext(data: nil, width: 640, height: 640,
                                            bitsPerComponent: 8, bytesPerRow: 640 * 4,
                                            space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let controller = BoardEditorController(
            image: image, position: .starting, whiteAtBottom: true, assistedColor: .white,
            scanStatus: "Current image: 63/64 squares matched. Correct the orange ? squares, then check whose turn it is.",
            requiresReview: true,
            learnedSummary: "Local shapes: 6/6 white • 6/6 black • 312 confirmed samples + 29 built-in",
            uncertainSquares: [32], onAnalyze: { _, _, _ in }, onLearn: { _, _, _ in }
        )
        let content = try XCTUnwrap(controller.window?.contentView)
        content.layoutSubtreeIfNeeded()
        let sidebar = try XCTUnwrap(content.subviews.first { $0 is NSStackView } as? NSStackView)
        let analyze = try XCTUnwrap(sidebar.arrangedSubviews.compactMap { $0 as? NSButton }.first { $0.title == "Analyze and show arrow" })
        let buttonFrame = analyze.convert(analyze.bounds, to: content)
        XCTAssertGreaterThanOrEqual(buttonFrame.minY, 0, "Analyze must not fall below the window")
        XCTAssertLessThanOrEqual(buttonFrame.maxY, content.bounds.height)
        XCTAssertLessThanOrEqual(sidebar.fittingSize.height, content.bounds.height - 40)
        controller.close()
    }
}
