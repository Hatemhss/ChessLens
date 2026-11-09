import AppKit

final class MoveOverlayController {
    private var arrowWindow: NSWindow?
    private var controlWindow: NSWindow?
    private var controlLabel: NSTextField?
    private var refreshButton: NSButton?
    private var closeButton: NSButton?
    private let onHide: () -> Void
    private let onRefresh: () -> Void

    init(onHide: @escaping () -> Void, onRefresh: @escaping () -> Void) {
        self.onHide = onHide
        self.onRefresh = onRefresh
    }

    var isVisible: Bool { arrowWindow?.isVisible == true || controlWindow?.isVisible == true }

    func show(move: ChessMove, on rect: CGRect, whiteAtBottom: Bool, detail: String) {
        hideArrow()
        let arrowView = MoveArrowView(frame: CGRect(origin: .zero, size: rect.size), move: move, whiteAtBottom: whiteAtBottom)
        let arrow = NSWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
        arrow.level = .floating
        arrow.isOpaque = false
        arrow.backgroundColor = .clear
        arrow.hasShadow = false
        arrow.ignoresMouseEvents = true
        arrow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        arrow.contentView = arrowView
        arrow.orderFrontRegardless()
        arrowWindow = arrow
        showControls(on: rect, detail: detail)
    }

    /// Keep refresh and stop available while there is no move to draw.
    func showStatus(on rect: CGRect, detail: String) {
        hideArrow()
        showControls(on: rect, detail: detail)
    }

    private func showControls(on rect: CGRect, detail: String) {
        let visibleFrame = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: rect.midX, y: rect.midY)) })?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? rect
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold)
        let labelWidth = ceil((detail as NSString).size(withAttributes: [.font: font]).width)
        let controlWidth: CGFloat = min(360, max(214, labelWidth + 88))
        let controlHeight: CGFloat = 34
        let proposedY = rect.maxY + 8
        let controlY = proposedY + controlHeight <= visibleFrame.maxY ? proposedY : rect.maxY - controlHeight - 8
        let controlX = min(max(rect.maxX - controlWidth, visibleFrame.minX + 4), visibleFrame.maxX - controlWidth - 4)
        let controlRect = CGRect(x: controlX, y: controlY, width: controlWidth, height: controlHeight)
        if let control = controlWindow {
            control.setFrame(controlRect, display: true)
            controlLabel?.stringValue = detail
            controlLabel?.toolTip = detail
            controlLabel?.setAccessibilityLabel(detail)
            controlLabel?.frame = CGRect(x: 10, y: 7, width: controlWidth - 84, height: 20)
            refreshButton?.frame = CGRect(x: controlWidth - 69, y: 2, width: 31, height: 29)
            closeButton?.frame = CGRect(x: controlWidth - 35, y: 2, width: 31, height: 29)
            control.orderFrontRegardless()
            return
        }
        let control = NSWindow(contentRect: controlRect, styleMask: .borderless, backing: .buffered, defer: false)
        control.level = .floating
        control.isOpaque = false
        control.backgroundColor = .clear
        control.hasShadow = true
        control.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let effect = NSVisualEffectView(frame: CGRect(origin: .zero, size: controlRect.size))
        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 9
        let label = NSTextField(labelWithString: detail)
        label.font = font
        label.textColor = .white
        label.lineBreakMode = .byTruncatingTail
        label.toolTip = detail
        label.setAccessibilityLabel(detail)
        label.frame = CGRect(x: 10, y: 7, width: controlWidth - 84, height: 20)
        effect.addSubview(label)
        controlLabel = label
        let refresh = NSButton(title: "↻", target: self, action: #selector(refreshPressed))
        refresh.isBordered = false
        refresh.font = .systemFont(ofSize: 20, weight: .medium)
        refresh.contentTintColor = .white
        refresh.frame = CGRect(x: controlWidth - 69, y: 2, width: 31, height: 29)
        refresh.toolTip = "Recapture board and calculate next move"
        refresh.setAccessibilityLabel("Refresh board and next move")
        effect.addSubview(refresh)
        refreshButton = refresh
        let close = NSButton(title: "×", target: self, action: #selector(closePressed))
        close.isBordered = false
        close.font = .systemFont(ofSize: 22, weight: .medium)
        close.contentTintColor = .white
        close.frame = CGRect(x: controlWidth - 35, y: 2, width: 31, height: 29)
        close.toolTip = "Stop watching"
        close.setAccessibilityLabel("Stop watching board")
        effect.addSubview(close)
        closeButton = close
        control.contentView = effect
        control.orderFrontRegardless()
        controlWindow = control
    }

    @objc private func closePressed() {
        hide()
        onHide()
    }

    @objc private func refreshPressed() {
        hideArrow()
        controlLabel?.stringValue = "Refreshing…"
        controlLabel?.setAccessibilityLabel("Refreshing board")
        onRefresh()
    }

    private func hideArrow() {
        arrowWindow?.orderOut(nil)
        arrowWindow = nil
    }

    func hide() {
        hideArrow()
        controlWindow?.orderOut(nil)
        controlWindow = nil
        controlLabel = nil
        refreshButton = nil
        closeButton = nil
    }
}

final class MoveArrowView: NSView {
    let move: ChessMove
    let whiteAtBottom: Bool

    init(frame: CGRect, move: ChessMove, whiteAtBottom: Bool) {
        self.move = move
        self.whiteAtBottom = whiteAtBottom
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let start = center(of: move.from)
        let end = center(of: move.to)
        let dx = end.x - start.x, dy = end.y - start.y
        let length = max(1, hypot(dx, dy))
        let ux = dx / length, uy = dy / length
        let cell = min(bounds.width, bounds.height) / 8
        let shortenedEnd = CGPoint(x: end.x - ux * cell * 0.14, y: end.y - uy * cell * 0.14)

        let path = NSBezierPath()
        path.move(to: start)
        path.line(to: shortenedEnd)
        path.lineWidth = max(7, cell * 0.16)
        path.lineCapStyle = .round
        NSColor.systemYellow.withAlphaComponent(0.92).setStroke()
        path.stroke()

        let head = max(14, cell * 0.34)
        let perpendicular = CGPoint(x: -uy, y: ux)
        let base = CGPoint(x: end.x - ux * head, y: end.y - uy * head)
        let triangle = NSBezierPath()
        triangle.move(to: end)
        triangle.line(to: CGPoint(x: base.x + perpendicular.x * head * 0.55, y: base.y + perpendicular.y * head * 0.55))
        triangle.line(to: CGPoint(x: base.x - perpendicular.x * head * 0.55, y: base.y - perpendicular.y * head * 0.55))
        triangle.close()
        NSColor.systemYellow.withAlphaComponent(0.96).setFill()
        triangle.fill()

        NSColor.black.withAlphaComponent(0.4).setStroke()
        triangle.lineWidth = 1.5
        triangle.stroke()
    }

    private func center(of square: Int) -> CGPoint {
        let file = square % 8, rank = square / 8
        let visualFile = whiteAtBottom ? file : 7 - file
        let visualRankFromBottom = whiteAtBottom ? rank : 7 - rank
        return CGPoint(
            x: (CGFloat(visualFile) + 0.5) * bounds.width / 8,
            y: (CGFloat(visualRankFromBottom) + 0.5) * bounds.height / 8
        )
    }
}
