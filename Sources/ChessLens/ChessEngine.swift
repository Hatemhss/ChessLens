import Foundation

struct SearchResult: Sendable {
    let move: ChessMove
    let score: Int
    let depth: Int
}

struct ChessEngine: Sendable {
    private let infinity = 1_000_000
    private let mateScore = 900_000

    func bestMove(in original: Position, timeLimit: TimeInterval = 1.8, maxDepth: Int = 5) -> SearchResult? {
        let moves = original.legalMoves()
        guard !moves.isEmpty else { return nil }

        // Never let a short time budget hide an immediately available checkmate.
        for move in moves {
            let child = original.applying(move)
            if child.isKingInCheck(child.sideToMove) && child.legalMoves().isEmpty {
                return SearchResult(move: move, score: mateScore, depth: 1)
            }
        }

        let deadline = Date().addingTimeInterval(timeLimit)
        var lastComplete: SearchResult?
        var preferred: ChessMove?

        for depth in 1...maxDepth {
            var best: ChessMove?
            var bestScore = -infinity
            var alpha = -infinity
            let ordered = order(moves: moves, in: original, preferred: preferred)

            for move in ordered {
                if Date() >= deadline { return lastComplete ?? best.map { SearchResult(move: $0, score: bestScore, depth: depth) } }
                let child = original.applying(move)
                let score = -negamax(child, depth: depth - 1, alpha: -infinity, beta: -alpha, ply: 1, deadline: deadline)
                if score > bestScore {
                    bestScore = score
                    best = move
                }
                alpha = max(alpha, score)
            }

            if let best {
                lastComplete = SearchResult(move: best, score: bestScore, depth: depth)
                preferred = best
            }
        }
        return lastComplete
    }

    private func negamax(_ position: Position, depth: Int, alpha initialAlpha: Int, beta: Int, ply: Int, deadline: Date) -> Int {
        if Date() >= deadline { return evaluate(position) }
        if depth == 0 { return quiescence(position, alpha: initialAlpha, beta: beta, remaining: 5, deadline: deadline) }

        let moves = position.legalMoves()
        if moves.isEmpty {
            return position.isKingInCheck(position.sideToMove) ? -mateScore + ply : 0
        }

        var alpha = initialAlpha
        for move in order(moves: moves, in: position, preferred: nil) {
            let score = -negamax(position.applying(move), depth: depth - 1, alpha: -beta, beta: -alpha, ply: ply + 1, deadline: deadline)
            if score >= beta { return beta }
            alpha = max(alpha, score)
        }
        return alpha
    }

    private func quiescence(_ position: Position, alpha initialAlpha: Int, beta: Int, remaining: Int, deadline: Date) -> Int {
        var alpha = initialAlpha
        if remaining <= 0 || Date() >= deadline { return evaluate(position) }

        if position.isKingInCheck(position.sideToMove) {
            let evasions = position.legalMoves()
            if evasions.isEmpty { return -mateScore }
            for move in order(moves: evasions, in: position, preferred: nil) {
                let score = -quiescence(position.applying(move), alpha: -beta, beta: -alpha, remaining: remaining - 1, deadline: deadline)
                if score >= beta { return beta }
                alpha = max(alpha, score)
            }
            return alpha
        }

        let standing = evaluate(position)
        if standing >= beta { return beta }
        alpha = max(alpha, standing)

        let captures = position.legalMoves().filter { position.board[$0.to] != nil || $0.isEnPassant }
        for move in order(moves: captures, in: position, preferred: nil) {
            let score = -quiescence(position.applying(move), alpha: -beta, beta: -alpha, remaining: remaining - 1, deadline: deadline)
            if score >= beta { return beta }
            alpha = max(alpha, score)
        }
        return alpha
    }

    private func evaluate(_ position: Position) -> Int {
        var score = 0
        for (square, piece) in position.board.enumerated() {
            guard let piece else { continue }
            let file = square % 8
            let rank = square / 8
            let relativeRank = piece.color == .white ? rank : 7 - rank
            let center = 7 - (abs(file * 2 - 7) + abs(rank * 2 - 7)) / 2
            var bonus = 0
            switch piece.kind {
            case .pawn: bonus = relativeRank * 7 + center * 2
            case .knight: bonus = center * 8
            case .bishop: bonus = center * 5
            case .rook: bonus = relativeRank * 2
            case .queen: bonus = center * 2
            case .king: bonus = relativeRank < 2 ? -center * 2 : center * 3
            }
            let signed = piece.kind.value + bonus
            score += piece.color == position.sideToMove ? signed : -signed
        }
        return score
    }

    private func order(moves: [ChessMove], in position: Position, preferred: ChessMove?) -> [ChessMove] {
        moves.sorted { lhs, rhs in
            moveOrderScore(lhs, in: position, preferred: preferred) > moveOrderScore(rhs, in: position, preferred: preferred)
        }
    }

    private func moveOrderScore(_ move: ChessMove, in position: Position, preferred: ChessMove?) -> Int {
        if move == preferred { return 100_000 }
        var score = 0
        if let victim = position.board[move.to], let attacker = position.board[move.from] {
            score += 10_000 + victim.kind.value - attacker.kind.value / 10
        }
        if move.isEnPassant { score += 10_000 }
        if let promotion = move.promotion { score += 8_000 + promotion.value }
        if move.isCastle { score += 500 }
        return score
    }
}

extension Position {
    func legalMoves() -> [ChessMove] {
        let movingColor = sideToMove
        return pseudoLegalMoves().filter { !moveLeavesKingInCheck($0, color: movingColor) }
    }

    func applying(_ move: ChessMove) -> Position {
        var next = self
        guard var piece = next.board[move.from] else { return next }
        let captured = next.board[move.to]
        next.board[move.from] = nil

        if move.isEnPassant {
            let capturedSquare = move.to + (piece.color == .white ? -8 : 8)
            next.board[capturedSquare] = nil
        }
        if move.isCastle {
            if move.to == 6 { next.board[5] = next.board[7]; next.board[7] = nil }
            if move.to == 2 { next.board[3] = next.board[0]; next.board[0] = nil }
            if move.to == 62 { next.board[61] = next.board[63]; next.board[63] = nil }
            if move.to == 58 { next.board[59] = next.board[56]; next.board[56] = nil }
        }
        if let promotion = move.promotion { piece.kind = promotion }
        next.board[move.to] = piece

        if piece.kind == .king {
            if piece.color == .white { next.castling.remove([.whiteKing, .whiteQueen]) }
            else { next.castling.remove([.blackKing, .blackQueen]) }
        }
        switch move.from {
        case 0: next.castling.remove(.whiteQueen)
        case 7: next.castling.remove(.whiteKing)
        case 56: next.castling.remove(.blackQueen)
        case 63: next.castling.remove(.blackKing)
        default: break
        }
        switch move.to {
        case 0: next.castling.remove(.whiteQueen)
        case 7: next.castling.remove(.whiteKing)
        case 56: next.castling.remove(.blackQueen)
        case 63: next.castling.remove(.blackKing)
        default: break
        }

        if piece.kind == .pawn && abs(move.to - move.from) == 16 {
            next.enPassantSquare = (move.from + move.to) / 2
        } else {
            next.enPassantSquare = nil
        }
        next.halfmoveClock = piece.kind == .pawn || captured != nil ? 0 : halfmoveClock + 1
        if sideToMove == .black { next.fullmoveNumber += 1 }
        next.sideToMove = sideToMove.opposite
        return next
    }

    func isKingInCheck(_ color: PieceColor) -> Bool {
        guard let king = board.firstIndex(of: Piece(color: color, kind: .king)) else { return true }
        return isSquareAttacked(king, by: color.opposite)
    }

    func isSquareAttacked(_ square: Int, by attacker: PieceColor) -> Bool {
        let file = square % 8
        let rank = square / 8

        let pawnSourceRank = rank + (attacker == .white ? -1 : 1)
        if (0..<8).contains(pawnSourceRank) {
            for pawnFile in [file - 1, file + 1] where (0..<8).contains(pawnFile) {
                if board[pawnSourceRank * 8 + pawnFile] == Piece(color: attacker, kind: .pawn) { return true }
            }
        }

        let knightOffsets = [(1, 2), (2, 1), (2, -1), (1, -2), (-1, -2), (-2, -1), (-2, 1), (-1, 2)]
        for (df, dr) in knightOffsets {
            let f = file + df, r = rank + dr
            if inside(f, r), board[r * 8 + f] == Piece(color: attacker, kind: .knight) { return true }
        }

        if rayAttacks(file: file, rank: rank, color: attacker, directions: [(1, 0), (-1, 0), (0, 1), (0, -1)], kinds: [.rook, .queen]) { return true }
        if rayAttacks(file: file, rank: rank, color: attacker, directions: [(1, 1), (1, -1), (-1, 1), (-1, -1)], kinds: [.bishop, .queen]) { return true }

        for df in -1...1 {
            for dr in -1...1 where df != 0 || dr != 0 {
                let f = file + df, r = rank + dr
                if inside(f, r), board[r * 8 + f] == Piece(color: attacker, kind: .king) { return true }
            }
        }
        return false
    }

    private func pseudoLegalMoves() -> [ChessMove] {
        var moves: [ChessMove] = []
        for square in 0..<64 {
            guard let piece = board[square], piece.color == sideToMove else { continue }
            switch piece.kind {
            case .pawn: addPawnMoves(from: square, piece: piece, to: &moves)
            case .knight: addJumpMoves(from: square, offsets: [(1, 2), (2, 1), (2, -1), (1, -2), (-1, -2), (-2, -1), (-2, 1), (-1, 2)], to: &moves)
            case .bishop: addRayMoves(from: square, directions: [(1, 1), (1, -1), (-1, 1), (-1, -1)], to: &moves)
            case .rook: addRayMoves(from: square, directions: [(1, 0), (-1, 0), (0, 1), (0, -1)], to: &moves)
            case .queen: addRayMoves(from: square, directions: [(1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (1, -1), (-1, 1), (-1, -1)], to: &moves)
            case .king:
                addJumpMoves(from: square, offsets: [(1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (1, -1), (-1, 1), (-1, -1)], to: &moves)
                addCastlingMoves(from: square, color: piece.color, to: &moves)
            }
        }
        return moves
    }

    private func moveLeavesKingInCheck(_ move: ChessMove, color: PieceColor) -> Bool {
        applying(move).isKingInCheck(color)
    }

    private func addPawnMoves(from square: Int, piece: Piece, to moves: inout [ChessMove]) {
        let file = square % 8, rank = square / 8
        let direction = piece.color == .white ? 1 : -1
        let startRank = piece.color == .white ? 1 : 6
        let promotionRank = piece.color == .white ? 7 : 0
        let oneRank = rank + direction

        if inside(file, oneRank) && board[oneRank * 8 + file] == nil {
            addPawnMove(from: square, to: oneRank * 8 + file, promotionRank: promotionRank, into: &moves)
            let twoRank = rank + direction * 2
            if rank == startRank && board[twoRank * 8 + file] == nil {
                moves.append(ChessMove(from: square, to: twoRank * 8 + file))
            }
        }
        for captureFile in [file - 1, file + 1] where inside(captureFile, oneRank) {
            let target = oneRank * 8 + captureFile
            if let victim = board[target], victim.color != piece.color {
                addPawnMove(from: square, to: target, promotionRank: promotionRank, into: &moves)
            } else if target == enPassantSquare {
                moves.append(ChessMove(from: square, to: target, isEnPassant: true))
            }
        }
    }

    private func addPawnMove(from: Int, to: Int, promotionRank: Int, into moves: inout [ChessMove]) {
        if to / 8 == promotionRank {
            for kind in [PieceKind.queen, .rook, .bishop, .knight] {
                moves.append(ChessMove(from: from, to: to, promotion: kind))
            }
        } else {
            moves.append(ChessMove(from: from, to: to))
        }
    }

    private func addJumpMoves(from square: Int, offsets: [(Int, Int)], to moves: inout [ChessMove]) {
        let file = square % 8, rank = square / 8
        guard let piece = board[square] else { return }
        for (df, dr) in offsets {
            let f = file + df, r = rank + dr
            guard inside(f, r) else { continue }
            let target = r * 8 + f
            if board[target]?.color != piece.color { moves.append(ChessMove(from: square, to: target)) }
        }
    }

    private func addRayMoves(from square: Int, directions: [(Int, Int)], to moves: inout [ChessMove]) {
        let file = square % 8, rank = square / 8
        guard let piece = board[square] else { return }
        for (df, dr) in directions {
            var f = file + df, r = rank + dr
            while inside(f, r) {
                let target = r * 8 + f
                if let occupant = board[target] {
                    if occupant.color != piece.color { moves.append(ChessMove(from: square, to: target)) }
                    break
                }
                moves.append(ChessMove(from: square, to: target))
                f += df; r += dr
            }
        }
    }

    private func addCastlingMoves(from square: Int, color: PieceColor, to moves: inout [ChessMove]) {
        let home = color == .white ? 4 : 60
        guard square == home, !isKingInCheck(color) else { return }
        let kingRight: CastlingRights = color == .white ? .whiteKing : .blackKing
        let queenRight: CastlingRights = color == .white ? .whiteQueen : .blackQueen
        if castling.contains(kingRight), board[home + 1] == nil, board[home + 2] == nil,
           board[home + 3] == Piece(color: color, kind: .rook),
           !isSquareAttacked(home + 1, by: color.opposite), !isSquareAttacked(home + 2, by: color.opposite) {
            moves.append(ChessMove(from: home, to: home + 2, isCastle: true))
        }
        if castling.contains(queenRight), board[home - 1] == nil, board[home - 2] == nil, board[home - 3] == nil,
           board[home - 4] == Piece(color: color, kind: .rook),
           !isSquareAttacked(home - 1, by: color.opposite), !isSquareAttacked(home - 2, by: color.opposite) {
            moves.append(ChessMove(from: home, to: home - 2, isCastle: true))
        }
    }

    private func rayAttacks(file: Int, rank: Int, color: PieceColor, directions: [(Int, Int)], kinds: [PieceKind]) -> Bool {
        for (df, dr) in directions {
            var f = file + df, r = rank + dr
            while inside(f, r) {
                if let piece = board[r * 8 + f] {
                    if piece.color == color && kinds.contains(piece.kind) { return true }
                    break
                }
                f += df; r += dr
            }
        }
        return false
    }

    private func inside(_ file: Int, _ rank: Int) -> Bool {
        (0..<8).contains(file) && (0..<8).contains(rank)
    }
}
