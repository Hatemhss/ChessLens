import AppKit

final class BoardEditorController: NSWindowController {
    private let boardView: BoardEditorView
    private let sideControl: NSSegmentedControl
    private let playerColorControl: NSSegmentedControl
    private let orientationControl: NSSegmentedControl
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let uncertaintyLabel = NSTextField(wrappingLabelWithString: "")
    private let reviewCheck = NSButton(checkboxWithTitle: "I checked the piece badges against the board", target: nil, action: nil)
    private let requiresReview: Bool
    private let fenField = NSTextField(string: "")
    private var paletteButtons: [NSButton] = []
    private var selectedPaletteTag = 1
    private let onAnalyze: (Position, Bool, PieceColor) -> Void
    private let onLearn: (Position, Bool, PieceColor) -> Void

    init(
        image: CGImage,
        position: Position,
        whiteAtBottom: Bool,
        assistedColor: PieceColor,
        scanStatus: String,
        requiresReview: Bool,
        learnedSummary: String,
        uncertainSquares: Set<Int> = [],
        onAnalyze: @escaping (Position, Bool, PieceColor) -> Void,
        onLearn: @escaping (Position, Bool, PieceColor) -> Void
    ) {
        self.boardView = BoardEditorView(
            image: image, position: position, whiteAtBottom: whiteAtBottom,
            uncertainSquares: uncertainSquares
        )
        self.sideControl = NSSegmentedControl(labels: ["White", "Black"], trackingMode: .selectOne, target: nil, action: nil)
        self.playerColorControl = NSSegmentedControl(labels: ["I play White", "I play Black"], trackingMode: .selectOne, target: nil, action: nil)
        self.orientationControl = NSSegmentedControl(labels: ["White ↓", "Black ↓"], trackingMode: .selectOne, target: nil, action: nil)
        self.requiresReview = requiresReview
        self.onAnalyze = onAnalyze
        self.onLearn = onLearn

        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 950, height: 740),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Confirm chess position"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        buildUI(scanStatus: scanStatus, learnedSummary: learnedSummary)
        sideControl.selectedSegment = position.sideToMove == .white ? 0 : 1
        playerColorControl.selectedSegment = assistedColor == .white ? 0 : 1
        orientationControl.selectedSegment = whiteAtBottom ? 0 : 1
        selectPalette(tag: selectedPaletteTag)
        boardView.onPositionChange = { [weak self] in self?.refreshFEN() }
        refreshFEN()
    }

    required init?(coder: NSCoder) { nil }

    func show() {
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func buildUI(scanStatus: String, learnedSummary: String) {
        guard let content = window?.contentView else { return }
        boardView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(boardView)

        let sidebar = NSStackView()
        sidebar.orientation = .vertical
        sidebar.alignment = .leading
        sidebar.spacing = 9
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(sidebar)

        let title = NSTextField(labelWithString: "Confirm what the screen shows")
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        sidebar.addArrangedSubview(title)

        let help = NSTextField(wrappingLabelWithString: "Correct orange ? squares: choose a piece and click, or right-click if empty.")
        help.textColor = .secondaryLabelColor
        help.maximumNumberOfLines = 3
        sidebar.addArrangedSubview(help)

        statusLabel.stringValue = "\(scanStatus)\n\(learnedSummary)"
        statusLabel.textColor = requiresReview ? .systemOrange : .systemGreen
        statusLabel.maximumNumberOfLines = 6
        sidebar.addArrangedSubview(statusLabel)
        uncertaintyLabel.textColor = .systemOrange
        uncertaintyLabel.maximumNumberOfLines = 2
        sidebar.addArrangedSubview(uncertaintyLabel)

        let paletteGrid = NSGridView()
        paletteGrid.rowSpacing = 5
        paletteGrid.columnSpacing = 5
        let palette: [(String, Int)] = [
            ("⌫", 0), ("♔", 1), ("♕", 2), ("♖", 3), ("♗", 4), ("♘", 5), ("♙", 6),
            ("·", -1), ("♚", 7), ("♛", 8), ("♜", 9), ("♝", 10), ("♞", 11), ("♟", 12)
        ]
        for row in 0..<2 {
            var views: [NSView] = []
            for column in 0..<7 {
                let item = palette[row * 7 + column]
                if item.1 == -1 {
                    let spacer = NSView(frame: CGRect(x: 0, y: 0, width: 27, height: 28))
                    views.append(spacer)
                } else {
                    let button = NSButton(title: item.0, target: self, action: #selector(palettePressed(_:)))
                    button.tag = item.1
                    button.font = .systemFont(ofSize: 19)
                    button.bezelStyle = .texturedRounded
                    button.setContentHuggingPriority(.required, for: .horizontal)
                    paletteButtons.append(button)
                    views.append(button)
                }
            }
            paletteGrid.addRow(with: views)
        }
        sidebar.addArrangedSubview(paletteGrid)

        let quickRow = NSStackView()
        quickRow.orientation = .horizontal
        quickRow.spacing = 6
        let startButton = NSButton(title: "Start position", target: self, action: #selector(loadStart))
        let clearButton = NSButton(title: "Clear", target: self, action: #selector(clearBoard))
        quickRow.addArrangedSubview(startButton)
        quickRow.addArrangedSubview(clearButton)
        sidebar.addArrangedSubview(quickRow)

        sidebar.addArrangedSubview(sectionLabel("Side to move"))
        sideControl.target = self
        sideControl.action = #selector(sideChanged)
        sideControl.segmentStyle = .rounded
        sidebar.addArrangedSubview(sideControl)

        sidebar.addArrangedSubview(sectionLabel("My color"))
        playerColorControl.target = self
        playerColorControl.action = #selector(playerColorChanged)
        playerColorControl.segmentStyle = .rounded
        sidebar.addArrangedSubview(playerColorControl)

        sidebar.addArrangedSubview(sectionLabel("Board orientation"))
        orientationControl.target = self
        orientationControl.action = #selector(orientationChanged)
        orientationControl.segmentStyle = .rounded
        sidebar.addArrangedSubview(orientationControl)

        sidebar.addArrangedSubview(sectionLabel("FEN (optional)"))
        fenField.placeholderString = "Paste a FEN position"
        fenField.translatesAutoresizingMaskIntoConstraints = false
        fenField.widthAnchor.constraint(equalToConstant: 230).isActive = true
        sidebar.addArrangedSubview(fenField)
        let loadFENButton = NSButton(title: "Load FEN", target: self, action: #selector(loadFEN))
        sidebar.addArrangedSubview(loadFENButton)

        let flexible = NSView()
        flexible.translatesAutoresizingMaskIntoConstraints = false
        flexible.heightAnchor.constraint(greaterThanOrEqualToConstant: 8).isActive = true
        sidebar.addArrangedSubview(flexible)

        if requiresReview {
            reviewCheck.state = .off
            sidebar.addArrangedSubview(reviewCheck)
        }

        let learnButton = NSButton(title: "Save piece shapes only", target: self, action: #selector(learnShapes))
        learnButton.toolTip = "Teach ChessLens this board theme without starting analysis"
        sidebar.addArrangedSubview(learnButton)

        let analyzeButton = NSButton(title: "Analyze and show arrow", target: self, action: #selector(analyze))
        analyzeButton.bezelStyle = .rounded
        analyzeButton.keyEquivalent = "\r"
        analyzeButton.contentTintColor = .controlAccentColor
        sidebar.addArrangedSubview(analyzeButton)

        NSLayoutConstraint.activate([
            boardView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            boardView.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            boardView.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            boardView.widthAnchor.constraint(equalTo: boardView.heightAnchor),
            sidebar.leadingAnchor.constraint(equalTo: boardView.trailingAnchor, constant: 20),
            sidebar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            sidebar.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            sidebar.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20)
        ])
    }

    private func sectionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    @objc private func palettePressed(_ sender: NSButton) {
        selectPalette(tag: sender.tag)
    }

    private func selectPalette(tag: Int) {
        selectedPaletteTag = tag
        for button in paletteButtons { button.state = button.tag == tag ? .on : .off }
        boardView.paintPiece = piece(for: tag)
    }

    private func piece(for tag: Int) -> Piece? {
        guard tag > 0 else { return nil }
        let color: PieceColor = tag <= 6 ? .white : .black
        let normalized = tag <= 6 ? tag : tag - 6
        let kind: PieceKind
        switch normalized {
        case 1: kind = .king
        case 2: kind = .queen
        case 3: kind = .rook
        case 4: kind = .bishop
        case 5: kind = .knight
        default: kind = .pawn
        }
        return Piece(color: color, kind: kind)
    }

    @objc private func loadStart() {
        var position = Position.starting
        position.sideToMove = sideControl.selectedSegment == 0 ? .white : .black
        boardView.replacePosition(position)
    }

    @objc private func clearBoard() {
        boardView.replacePosition(Position(sideToMove: sideControl.selectedSegment == 0 ? .white : .black))
    }

    @objc private func sideChanged() {
        boardView.position.sideToMove = sideControl.selectedSegment == 0 ? .white : .black
        refreshFEN()
    }

    @objc private func orientationChanged() {
        boardView.changeOrientation(whiteAtBottom: orientationControl.selectedSegment == 0)
    }

    @objc private func playerColorChanged() {
        reviewCheck.state = .off
    }

    @objc private func loadFEN() {
        guard let position = Position(fen: fenField.stringValue) else {
            showValidation("That FEN is not valid.")
            return
        }
        boardView.replacePosition(position)
        sideControl.selectedSegment = position.sideToMove == .white ? 0 : 1
        refreshFEN()
    }

    @objc private func analyze() {
        guard let position = preparedPosition() else { return }
        onAnalyze(position, boardView.whiteAtBottom, selectedPlayerColor)
        close()
    }

    @objc private func learnShapes() {
        guard let position = preparedPosition() else { return }
        onLearn(position, boardView.whiteAtBottom, selectedPlayerColor)
        close()
    }

    private var selectedPlayerColor: PieceColor {
        playerColorControl.selectedSegment == 0 ? .white : .black
    }

    private func preparedPosition() -> Position? {
        if !boardView.uncertainSquares.isEmpty {
            let squares = boardView.uncertainSquares.sorted().map(ChessMove.squareName).joined(separator: ", ")
            showValidation("Identify the orange ? squares first: \(squares). Choose the correct piece and click each square, or right-click if it is empty.")
            return nil
        }
        if requiresReview && reviewCheck.state != .on {
            showValidation("Check each piece badge against the screenshot, correct any differences, then tick the confirmation box.")
            return nil
        }
        var position = boardView.position
        position.sideToMove = sideControl.selectedSegment == 0 ? .white : .black
        if let issue = position.validationIssue {
            showValidation(issue)
            return nil
        }
        return position
    }

    private func refreshFEN() {
        reviewCheck.state = .off
        reviewCheck.isEnabled = boardView.uncertainSquares.isEmpty
        let count = boardView.uncertainSquares.count
        uncertaintyLabel.stringValue = count == 0 ? "" : "\(count) uncertain square\(count == 1 ? "" : "s") — correct the orange ? markers."
        uncertaintyLabel.isHidden = count == 0
        fenField.stringValue = boardView.position.fen
    }

    private func showValidation(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Check the position"
        alert.informativeText = message
        alert.alertStyle = .warning
        if let window { alert.beginSheetModal(for: window) }
    }
}

final class BoardEditorView: NSView {
    let sourceImage: CGImage
    var position: Position { didSet { needsDisplay = true } }
    var whiteAtBottom: Bool { didSet { needsDisplay = true } }
    private(set) var uncertainSquares: Set<Int> { didSet { needsDisplay = true } }
    var paintPiece: Piece?
    var onPositionChange: (() -> Void)?
    private var highlightedSquare: Int?

    init(image: CGImage, position: Position, whiteAtBottom: Bool, uncertainSquares: Set<Int> = []) {
        self.sourceImage = image
        self.position = position
        self.whiteAtBottom = whiteAtBottom
        self.uncertainSquares = uncertainSquares.filter { (0..<64).contains($0) }
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { nil }

    func setPiece(_ piece: Piece?, at square: Int) {
        guard (0..<64).contains(square) else { return }
        position.setPieceForEditor(piece, at: square)
        // An explicit empty-square click also resolves uncertainty, even when the
        // provisional position already stored nil there.
        uncertainSquares.remove(square)
        highlightedSquare = square
        onPositionChange?()
        needsDisplay = true
    }

    func replacePosition(_ position: Position) {
        self.position = position
        uncertainSquares.removeAll()
        highlightedSquare = nil
        onPositionChange?()
    }

    func changeOrientation(whiteAtBottom: Bool) {
        guard self.whiteAtBottom != whiteAtBottom else { return }
        // The screenshot stays fixed. Remap chess coordinates so all confirmed
        // labels and unresolved markers stay over the same visible pieces.
        position.board.reverse()
        position.enPassantSquare = nil
        position.castling = []
        uncertainSquares = Set(uncertainSquares.map { 63 - $0 })
        highlightedSquare = highlightedSquare.map { 63 - $0 }
        self.whiteAtBottom = whiteAtBottom
        onPositionChange?()
    }

    override func mouseDown(with event: NSEvent) {
        guard let square = square(at: convert(event.locationInWindow, from: nil)) else { return }
        setPiece(paintPiece, at: square)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let square = square(at: convert(event.locationInWindow, from: nil)) else { return }
        setPiece(nil, at: square)
    }

    private func square(at point: CGPoint) -> Int? {
        guard bounds.contains(point) else { return nil }
        let column = min(7, max(0, Int(point.x / (bounds.width / 8))))
        let rowFromBottom = min(7, max(0, Int(point.y / (bounds.height / 8))))
        let file = whiteAtBottom ? column : 7 - column
        let rank = whiteAtBottom ? rowFromBottom : 7 - rowFromBottom
        return rank * 8 + file
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSImage(cgImage: sourceImage, size: bounds.size).draw(in: bounds, from: .zero, operation: .copy, fraction: 1)
        let cellW = bounds.width / 8
        let cellH = bounds.height / 8

        for square in 0..<64 {
            let file = square % 8, rank = square / 8
            let column = whiteAtBottom ? file : 7 - file
            let rowFromBottom = whiteAtBottom ? rank : 7 - rank
            let cell = CGRect(x: CGFloat(column) * cellW, y: CGFloat(rowFromBottom) * cellH, width: cellW, height: cellH)

            NSColor.white.withAlphaComponent(0.22).setStroke()
            let grid = NSBezierPath(rect: cell)
            grid.lineWidth = 0.5
            grid.stroke()

            if highlightedSquare == square {
                NSColor.systemYellow.withAlphaComponent(0.35).setFill()
                cell.fill()
            }
            if uncertainSquares.contains(square) {
                NSColor.systemOrange.withAlphaComponent(0.85).setStroke()
                let outline = NSBezierPath(rect: cell.insetBy(dx: 2, dy: 2))
                outline.lineWidth = 2
                outline.stroke()
                let badge = CGRect(x: cell.minX + 3, y: cell.minY + 3, width: min(25, cellW * 0.38), height: min(25, cellH * 0.38))
                NSColor.systemOrange.setFill()
                NSBezierPath(roundedRect: badge, xRadius: 5, yRadius: 5).fill()
                let text = NSAttributedString(string: "?", attributes: [
                    .font: NSFont.systemFont(ofSize: badge.height * 0.75, weight: .bold),
                    .foregroundColor: NSColor.black
                ])
                text.draw(at: CGPoint(x: badge.midX - text.size().width / 2, y: badge.midY - text.size().height / 2))
            } else if let piece = position.board[square] {
                let badge = CGRect(x: cell.minX + 3, y: cell.minY + 3, width: min(25, cellW * 0.38), height: min(25, cellH * 0.38))
                let badgeColor = piece.color == .white
                    ? NSColor.white.withAlphaComponent(0.90)
                    : NSColor.black.withAlphaComponent(0.78)
                badgeColor.setFill()
                NSBezierPath(roundedRect: badge, xRadius: 5, yRadius: 5).fill()
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: badge.height * 0.75),
                    .foregroundColor: piece.color == .white ? NSColor.black : NSColor.white
                ]
                let text = NSAttributedString(string: piece.symbol, attributes: attributes)
                text.draw(at: CGPoint(x: badge.midX - text.size().width / 2, y: badge.midY - text.size().height / 2))
            }
        }
    }
}

extension Position {
    /// Manual placement cannot establish that a king/rook has never moved, or that
    /// the preceding move was a double pawn advance. Preserve only known rights.
    mutating func setPieceForEditor(_ piece: Piece?, at square: Int) {
        guard board.indices.contains(square), board[square] != piece else { return }
        board[square] = piece
        enPassantSquare = nil
        var possibleRights = self
        possibleRights.inferCastlingRights()
        castling.formIntersection(possibleRights.castling)
    }
}
