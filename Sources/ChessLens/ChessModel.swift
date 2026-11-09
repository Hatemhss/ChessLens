import Foundation

enum PieceColor: String, Codable, Sendable {
    case white, black

    var opposite: PieceColor { self == .white ? .black : .white }
}

enum PieceKind: String, CaseIterable, Codable, Sendable {
    case pawn, knight, bishop, rook, queen, king

    var letter: Character {
        switch self {
        case .pawn: return "p"
        case .knight: return "n"
        case .bishop: return "b"
        case .rook: return "r"
        case .queen: return "q"
        case .king: return "k"
        }
    }

    var value: Int {
        switch self {
        case .pawn: return 100
        case .knight: return 320
        case .bishop: return 330
        case .rook: return 500
        case .queen: return 900
        case .king: return 20_000
        }
    }
}

struct Piece: Equatable, Codable, Sendable {
    var color: PieceColor
    var kind: PieceKind

    var fenCharacter: Character {
        let letter = kind.letter
        return color == .white ? Character(String(letter).uppercased()) : letter
    }

    var symbol: String {
        switch (color, kind) {
        case (.white, .king): return "♔"
        case (.white, .queen): return "♕"
        case (.white, .rook): return "♖"
        case (.white, .bishop): return "♗"
        case (.white, .knight): return "♘"
        case (.white, .pawn): return "♙"
        case (.black, .king): return "♚"
        case (.black, .queen): return "♛"
        case (.black, .rook): return "♜"
        case (.black, .bishop): return "♝"
        case (.black, .knight): return "♞"
        case (.black, .pawn): return "♟"
        }
    }

    init?(fenCharacter: Character) {
        let lower = Character(String(fenCharacter).lowercased())
        guard let kind = PieceKind.allCases.first(where: { $0.letter == lower }) else { return nil }
        self.color = fenCharacter.isUppercase ? .white : .black
        self.kind = kind
    }

    init(color: PieceColor, kind: PieceKind) {
        self.color = color
        self.kind = kind
    }
}

struct ChessMove: Equatable, Sendable {
    var from: Int
    var to: Int
    var promotion: PieceKind?
    var isEnPassant = false
    var isCastle = false

    var uci: String {
        var result = Self.squareName(from) + Self.squareName(to)
        if let promotion { result.append(promotion.letter) }
        return result
    }

    static func squareName(_ index: Int) -> String {
        let file = String(UnicodeScalar(97 + index % 8)!)
        return file + String(index / 8 + 1)
    }
}

struct CastlingRights: OptionSet, Codable, Sendable {
    let rawValue: Int
    static let whiteKing = CastlingRights(rawValue: 1 << 0)
    static let whiteQueen = CastlingRights(rawValue: 1 << 1)
    static let blackKing = CastlingRights(rawValue: 1 << 2)
    static let blackQueen = CastlingRights(rawValue: 1 << 3)
}

struct Position: Codable, Sendable {
    var board: [Piece?]
    var sideToMove: PieceColor
    var castling: CastlingRights
    var enPassantSquare: Int?
    var halfmoveClock: Int
    var fullmoveNumber: Int

    init(
        board: [Piece?] = Array(repeating: nil, count: 64),
        sideToMove: PieceColor = .white,
        castling: CastlingRights = [],
        enPassantSquare: Int? = nil,
        halfmoveClock: Int = 0,
        fullmoveNumber: Int = 1
    ) {
        self.board = board
        self.sideToMove = sideToMove
        self.castling = castling
        self.enPassantSquare = enPassantSquare
        self.halfmoveClock = halfmoveClock
        self.fullmoveNumber = fullmoveNumber
    }

    static var starting: Position {
        // Board indexes are a1...h8.
        var position = Position(sideToMove: .white, castling: [.whiteKing, .whiteQueen, .blackKing, .blackQueen])
        let order: [PieceKind] = [.rook, .knight, .bishop, .queen, .king, .bishop, .knight, .rook]
        for file in 0..<8 {
            position.board[file] = Piece(color: .white, kind: order[file])
            position.board[8 + file] = Piece(color: .white, kind: .pawn)
            position.board[48 + file] = Piece(color: .black, kind: .pawn)
            position.board[56 + file] = Piece(color: .black, kind: order[file])
        }
        return position
    }

    init?(fen: String) {
        let parts = fen.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let ranks = parts[0].split(separator: "/")
        guard ranks.count == 8 else { return nil }

        var decoded = Array<Piece?>(repeating: nil, count: 64)
        for (visualRank, rankText) in ranks.enumerated() {
            var file = 0
            for character in rankText {
                if let emptyCount = character.wholeNumberValue {
                    file += emptyCount
                } else if let piece = Piece(fenCharacter: character), file < 8 {
                    decoded[(7 - visualRank) * 8 + file] = piece
                    file += 1
                } else {
                    return nil
                }
            }
            guard file == 8 else { return nil }
        }

        board = decoded
        sideToMove = parts[1] == "b" ? .black : .white
        castling = []
        if parts.count > 2 {
            if parts[2].contains("K") { castling.insert(.whiteKing) }
            if parts[2].contains("Q") { castling.insert(.whiteQueen) }
            if parts[2].contains("k") { castling.insert(.blackKing) }
            if parts[2].contains("q") { castling.insert(.blackQueen) }
        }
        enPassantSquare = parts.count > 3 && parts[3] != "-" ? Self.index(of: String(parts[3])) : nil
        halfmoveClock = parts.count > 4 ? Int(parts[4]) ?? 0 : 0
        fullmoveNumber = parts.count > 5 ? Int(parts[5]) ?? 1 : 1
    }

    var fen: String {
        var ranks: [String] = []
        for rank in stride(from: 7, through: 0, by: -1) {
            var text = ""
            var empty = 0
            for file in 0..<8 {
                if let piece = board[rank * 8 + file] {
                    if empty > 0 { text += String(empty); empty = 0 }
                    text.append(piece.fenCharacter)
                } else {
                    empty += 1
                }
            }
            if empty > 0 { text += String(empty) }
            ranks.append(text)
        }
        var rights = ""
        if castling.contains(.whiteKing) { rights += "K" }
        if castling.contains(.whiteQueen) { rights += "Q" }
        if castling.contains(.blackKing) { rights += "k" }
        if castling.contains(.blackQueen) { rights += "q" }
        if rights.isEmpty { rights = "-" }
        let ep = enPassantSquare.map(ChessMove.squareName) ?? "-"
        return "\(ranks.joined(separator: "/")) \(sideToMove == .white ? "w" : "b") \(rights) \(ep) \(halfmoveClock) \(fullmoveNumber)"
    }

    mutating func inferCastlingRights() {
        castling = []
        if board[4] == Piece(color: .white, kind: .king) {
            if board[7] == Piece(color: .white, kind: .rook) { castling.insert(.whiteKing) }
            if board[0] == Piece(color: .white, kind: .rook) { castling.insert(.whiteQueen) }
        }
        if board[60] == Piece(color: .black, kind: .king) {
            if board[63] == Piece(color: .black, kind: .rook) { castling.insert(.blackKing) }
            if board[56] == Piece(color: .black, kind: .rook) { castling.insert(.blackQueen) }
        }
    }

    static func index(of square: String) -> Int? {
        guard square.count == 2,
              let first = square.utf8.first,
              let last = square.utf8.last,
              first >= 97, first <= 104,
              last >= 49, last <= 56 else { return nil }
        return Int(last - 49) * 8 + Int(first - 97)
    }
}

extension Position {
    var isStructurallyPlausible: Bool { validationIssue == nil }

    var validationIssue: String? {
        let pieces = board.compactMap { $0 }
        let whitePieces = pieces.filter { $0.color == .white }
        let blackPieces = pieces.filter { $0.color == .black }
        guard whitePieces.filter({ $0.kind == .king }).count == 1,
              blackPieces.filter({ $0.kind == .king }).count == 1 else {
            return "The position needs exactly one white king and one black king."
        }
        guard whitePieces.count <= 16, blackPieces.count <= 16 else {
            return "A color cannot have more than 16 pieces. Correct the detected squares."
        }
        guard whitePieces.filter({ $0.kind == .pawn }).count <= 8,
              blackPieces.filter({ $0.kind == .pawn }).count <= 8 else {
            return "A color cannot have more than eight pawns. Correct the detected squares."
        }
        for square in 0..<64 where board[square]?.kind == .pawn {
            if square / 8 == 0 || square / 8 == 7 {
                return "A pawn cannot remain on the first or eighth rank. Correct that square or choose its promoted piece."
            }
        }
        guard let whiteKing = board.firstIndex(of: Piece(color: .white, kind: .king)),
              let blackKing = board.firstIndex(of: Piece(color: .black, kind: .king)) else {
            return "Both kings are required."
        }
        let fileDistance = abs(whiteKing % 8 - blackKing % 8)
        let rankDistance = abs(whiteKing / 8 - blackKing / 8)
        if fileDistance <= 1 && rankDistance <= 1 {
            return "The kings cannot stand next to each other."
        }
        if isKingInCheck(sideToMove.opposite) {
            return "The position or Side to move is inconsistent: the player who just moved is still in check."
        }
        return nil
    }
}
