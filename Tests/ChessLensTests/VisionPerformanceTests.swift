import XCTest
import ImageIO
@testable import ChessLens

final class VisionPerformanceTests: XCTestCase {
    func testVisionReleaseBenchmark() throws {
        guard ProcessInfo.processInfo.environment["CHESSLENS_BENCHMARK"] == "1" else {
            throw XCTSkip("Opt-in appearance extraction benchmark")
        }
        let url = try XCTUnwrap(Bundle.module.url(forResource: "fast-pawn-reply", withExtension: "png", subdirectory: "Fixtures"))
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let board = try XCTUnwrap(image.cropping(to: CGRect(x: 51, y: 107, width: 1171, height: 1172)))
        var samples = [Double]()
        var checksum: Float = 0
        for index in 0..<40 {
            let start = ProcessInfo.processInfo.systemUptime
            let observation = try XCTUnwrap(BoardVision().observe(image: board, whiteAtBottom: true))
            let milliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1000
            XCTAssertEqual(observation.squares.count, 64)
            checksum += observation.squares[0].reduce(0, +)
            if index >= 5 { samples.append(milliseconds) }
        }
        samples.sort()
        print("VISION_BENCHMARK median_ms=\(samples[samples.count / 2]) p95_ms=\(samples[Int(Double(samples.count - 1) * 0.95)]) checksum=\(checksum)")
        XCTAssertGreaterThan(checksum, 0)
    }
}
