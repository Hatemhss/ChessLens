import CoreGraphics
import Foundation
import ImageIO

extension Bundle { static var module: Bundle { .main } }

final class MemoryDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    override func data(forKey defaultName: String) -> Data? { values[defaultName] as? Data }
    override func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
    override func removeObject(forKey defaultName: String) { values.removeValue(forKey: defaultName) }
}

@main
struct Benchmark {
    static let projectRoot = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("--") })
        ?? FileManager.default.currentDirectoryPath
    static func image(_ path: String, crop: CGRect) -> CGImage {
        let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)!
        return CGImageSourceCreateImageAtIndex(source, 0, nil)!.cropping(to: crop)!
    }

    static func main() throws {
        let reference = image("\(projectRoot)/Tests/ChessLensTests/Fixtures/fast-pawn-reply.png", crop: CGRect(x: 51, y: 107, width: 1171, height: 1172))
        let referencePosition = Position(fen: "rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq e6 0 2")!
        let observation = BoardVision().observe(image: reference, whiteAtBottom: true)!
        var templates: [LearnedTemplate] = []
        for square in 0..<64 {
            let label = referencePosition.board[square].map { String($0.fenCharacter) } ?? "."
            guard label != "." else { continue }
            let vector = observation.squares[square]
            if templates.filter({ $0.label == label }).allSatisfy({ BoardVision.distance($0.vector, vector) > 0.0012 }) {
                templates.append(LearnedTemplate(label: label, vector: vector))
            }
        }
        if CommandLine.arguments.contains("--export") {
            let archive = ShapeTemplateArchive(version: 3, templates: templates.map {
                ShapeTemplateArchive.Sample(label: $0.label, pixels: Data($0.vector.map { UInt8(max(0, min(255, Int(($0 * 255).rounded())))) }))
            })
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            print(String(data: try encoder.encode(archive), encoding: .utf8)!)
            return
        }

        let target = image("\(projectRoot)/Tests/ChessLensTests/Fixtures/endgame-rescan.png", crop: CGRect(x: 51, y: 104, width: 1196, height: 1196))
        let expected = Position(fen: "8/8/4K3/r1k5/8/1PP5/8/8 w - - 0 1")!
        let legacy = LegacyBoardScanner()
        legacy.learn(image: reference, position: referencePosition, whiteAtBottom: true)
        let old = legacy.predict(image: target, whiteAtBottom: true, sideToMove: .white)!
        let archiveData = try Data(contentsOf: URL(fileURLWithPath: "\(projectRoot)/Sources/ChessLens/Resources/classic-shapes-v3.json"))
        let archive = try JSONDecoder().decode(ShapeTemplateArchive.self, from: archiveData)
        let bundled = archive.templates.map { LearnedTemplate(label: $0.label, vector: $0.pixels.map { Float($0) / 255 }) }
        let scanner = BoardScanner(defaults: MemoryDefaults(), bundledTemplates: bundled)
        let new = scanner.predict(image: target, whiteAtBottom: true, sideToMove: .white)!
        for (name, position, confidence) in [("old",old.position,old.confidence),("new",new.position,new.confidence)] {
            let errors = (0..<64).filter { position.board[$0] != expected.board[$0] }
            print("\(name): \(64-errors.count)/64 correct, score \(confidence), FEN \(position.fen)")
            print("Errors: \(errors.map { ChessMove.squareName($0)+":"+(position.board[$0].map { String($0.fenCharacter) } ?? ".") }.joined(separator: ", "))")
        }
        print("uncertain: \(new.uncertainSquares.map(ChessMove.squareName)), seed count \(templates.count)")
        print("learning issues: \(scanner.learningIssues(image: target, position: expected, whiteAtBottom: true).map(ChessMove.squareName))")
        if CommandLine.arguments.contains("--timing") {
            for name in ["old", "new", "vision"] {
                var timings: [Double] = []
                for _ in 0..<12 {
                    let start = Date.timeIntervalSinceReferenceDate
                    if name == "old" {
                        _ = legacy.predict(image: target, whiteAtBottom: true, sideToMove: .white)
                    } else if name == "new" {
                        _ = scanner.predict(image: target, whiteAtBottom: true, sideToMove: .white)
                    } else {
                        _ = BoardVision().observe(image: target, whiteAtBottom: true)
                    }
                    timings.append((Date.timeIntervalSinceReferenceDate - start) * 1000)
                }
                timings.sort()
                print("\(name) median \(timings[timings.count / 2])ms min \(timings.first!)ms max \(timings.last!)ms")
            }
        }
        let targetObservation = BoardVision().observe(image: target, whiteAtBottom: true)!
        for square in 0..<64 where expected.board[square] != nil || new.position.board[square] != nil || new.uncertainSquares.contains(square) {
            let vector = targetObservation.squares[square]
            let occupancy = stride(from: 0, to: vector.count, by: 4).reduce(0.0) { $0 + Double(vector[$1]) } / 576
            let grouped = Dictionary(grouping: bundled, by: \.label)
            let best = grouped.map { label, samples in (label, samples.map { BoardVision.distance(vector, $0.vector) }.min()!) }.sorted { $0.1 < $1.1 }
            print("\(ChessMove.squareName(square)): occupancy \(occupancy), \(best.prefix(3)), confidence \(new.squareConfidences[square])")
        }
    }
}
