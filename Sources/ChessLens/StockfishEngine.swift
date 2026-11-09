import Foundation

struct BestMoveService {
    static func bestMove(in position: Position, timeMilliseconds: Int = 1_500) -> SearchResult? {
        if let result = StockfishEngine().bestMove(in: position, timeMilliseconds: timeMilliseconds) {
            return result
        }
        return ChessEngine().bestMove(
            in: position,
            timeLimit: Double(timeMilliseconds) / 1_000,
            maxDepth: 6
        )
    }
}

struct StockfishEngine {
    func bestMove(in position: Position, timeMilliseconds: Int = 1_500) -> SearchResult? {
        guard let executable = locateExecutable() else { return nil }

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = executable
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output

        do {
            try process.run()
        } catch {
            return nil
        }

        let writer = input.fileHandleForWriting
        let reader = output.fileHandleForReading
        func send(_ command: String) {
            if let data = (command + "\n").data(using: .utf8) {
                try? writer.write(contentsOf: data)
            }
        }

        send("uci")
        send("setoption name Threads value 2")
        send("setoption name Hash value 96")
        send("isready")
        send("ucinewgame")
        send("position fen \(position.fen)")
        send("go movetime \(max(100, timeMilliseconds))")

        var pending = ""
        var bestMoveText: String?
        var lastDepth = 0
        var lastScore = 0

        while process.isRunning && bestMoveText == nil {
            let data = reader.availableData
            if data.isEmpty { break }
            pending += String(decoding: data, as: UTF8.self)

            while let newline = pending.firstIndex(of: "\n") {
                let line = String(pending[..<newline]).trimmingCharacters(in: .whitespacesAndNewlines)
                pending.removeSubrange(...newline)

                if line.hasPrefix("info ") {
                    let fields = line.split(separator: " ").map(String.init)
                    if let depthIndex = fields.firstIndex(of: "depth"), depthIndex + 1 < fields.count {
                        lastDepth = Int(fields[depthIndex + 1]) ?? lastDepth
                    }
                    if let scoreIndex = fields.firstIndex(of: "score"), scoreIndex + 2 < fields.count {
                        if fields[scoreIndex + 1] == "cp" {
                            lastScore = Int(fields[scoreIndex + 2]) ?? lastScore
                        } else if fields[scoreIndex + 1] == "mate" {
                            let mate = Int(fields[scoreIndex + 2]) ?? 0
                            lastScore = mate >= 0 ? 900_000 - mate : -900_000 - mate
                        }
                    }
                } else if line.hasPrefix("bestmove ") {
                    bestMoveText = line.split(separator: " ").dropFirst().first.map(String.init)
                }
            }
        }

        send("quit")
        writer.closeFile()
        if process.isRunning { process.waitUntilExit() }

        guard let bestMoveText, bestMoveText != "(none)", bestMoveText != "0000",
              let move = position.legalMoves().first(where: { $0.uci == bestMoveText }) else {
            return nil
        }
        return SearchResult(move: move, score: lastScore, depth: lastDepth)
    }

    private func locateExecutable() -> URL? {
        var candidates: [URL] = []
        if let resource = Bundle.main.resourceURL {
            candidates.append(resource.appendingPathComponent("stockfish"))
        }
        candidates.append(
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("ThirdParty/Stockfish/stockfish")
        )

        return candidates.first {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
    }
}
