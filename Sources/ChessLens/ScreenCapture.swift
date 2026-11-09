import AppKit
import ScreenCaptureKit

enum CaptureError: LocalizedError {
    case noDisplay
    case invalidSelection

    var errorDescription: String? {
        switch self {
        case .noDisplay: return "The selected display could not be captured. Allow Screen Recording in System Settings and try again."
        case .invalidSelection: return "Select a square area containing the full chessboard."
        }
    }
}

final class SelectionController: NSObject {
    private var window: NSWindow?
    private var completion: ((CGRect?) -> Void)?

    func begin(completion: @escaping (CGRect?) -> Void) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else {
            completion(nil)
            return
        }
        self.completion = completion
        let selectionView = SelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
        selectionView.onFinish = { [weak self, weak selectionView] localRect in
            guard let self else { return }
            let globalRect = localRect.map {
                CGRect(x: $0.minX + screen.frame.minX, y: $0.minY + screen.frame.minY, width: $0.width, height: $0.height)
            }
            selectionView?.onFinish = nil
            self.window?.orderOut(nil)
            self.window = nil
            self.completion?(globalRect)
            self.completion = nil
        }

        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = .clear
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = selectionView
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }
}

final class SelectionView: NSView {
    var onFinish: ((CGRect?) -> Void)?
    private var start: CGPoint?
    private var current: CGPoint?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        NSCursor.crosshair.push()
    }

    override func removeFromSuperview() {
        NSCursor.pop()
        super.removeFromSuperview()
    }

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        current = start
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        let rect = selectionRect
        NSCursor.pop()
        if rect.width >= 120, rect.height >= 120 {
            let side = min(rect.width, rect.height)
            let square = CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
            onFinish?(square)
        } else {
            onFinish?(nil)
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            NSCursor.pop()
            onFinish?(nil)
        } else {
            super.keyDown(with: event)
        }
    }

    private var selectionRect: CGRect {
        guard let start, let current else { return .zero }
        return CGRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(start.x - current.x),
            height: abs(start.y - current.y)
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.42).setFill()
        bounds.fill()

        let rect = selectionRect
        guard !rect.isEmpty else {
            drawHint("Drag around the chessboard • Esc to cancel", at: CGPoint(x: bounds.midX, y: bounds.midY))
            return
        }
        NSGraphicsContext.current?.cgContext.clear(rect)
        NSColor.systemYellow.setStroke()
        let path = NSBezierPath(rect: rect)
        path.lineWidth = 3
        path.stroke()
        drawHint("Release to capture", at: CGPoint(x: rect.midX, y: max(28, rect.minY - 24)))
    }

    private func drawHint(_ text: String, at point: CGPoint) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 16, weight: .semibold),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.black.withAlphaComponent(0.72)
        ]
        let string = NSAttributedString(string: "  \(text)  ", attributes: attributes)
        string.draw(at: CGPoint(x: point.x - string.size().width / 2, y: point.y - string.size().height / 2))
    }
}

struct BoardCapture {
    let image: CGImage
    let screenRect: CGRect
}

@MainActor
final class ScreenshotService {
    private struct CachedFilter {
        let displayID: CGDirectDisplayID
        let screenFrame: CGRect
        let scale: CGFloat
        let createdAt: TimeInterval
        let filter: SCContentFilter
    }
    private var cachedFilter: CachedFilter?

    private func captureFilter(for screen: NSScreen, displayID: CGDirectDisplayID) async throws -> SCContentFilter {
        let now = ProcessInfo.processInfo.systemUptime
        if let cachedFilter,
           cachedFilter.displayID == displayID,
           cachedFilter.screenFrame == screen.frame,
           cachedFilter.scale == screen.backingScaleFactor,
           now - cachedFilter.createdAt < 5 {
            return cachedFilter.filter
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        try Task.checkCancellation()
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.noDisplay
        }
        let ownPID = pid_t(ProcessInfo.processInfo.processIdentifier)
        let ownApplications = content.applications.filter { $0.processID == ownPID }
        // Excluding the whole app also excludes overlay/editor windows created AFTER
        // this filter. A cached list of individual windows would capture our own arrow.
        let filter: SCContentFilter
        if !ownApplications.isEmpty {
            filter = SCContentFilter(display: display, excludingApplications: ownApplications, exceptingWindows: [])
            cachedFilter = CachedFilter(displayID: displayID, screenFrame: screen.frame,
                                        scale: screen.backingScaleFactor, createdAt: now, filter: filter)
        } else {
            // Never cache a window-only filter; a new overlay may appear next frame.
            cachedFilter = nil
            let ownWindows = content.windows.filter { $0.owningApplication?.processID == ownPID }
            filter = SCContentFilter(display: display, excludingWindows: ownWindows)
        }
        return filter
    }

    func capture(screenRect: CGRect, settleDelayNanoseconds: UInt64 = 180_000_000) async throws -> BoardCapture {
        if settleDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: settleDelayNanoseconds)
        }
        guard let nsScreen = NSScreen.screens.first(where: { $0.frame.intersects(screenRect) }),
              let displayID = nsScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            throw CaptureError.noDisplay
        }
        let filter = try await captureFilter(for: nsScreen, displayID: displayID)

        let relative = CGRect(
            x: screenRect.minX - nsScreen.frame.minX,
            y: nsScreen.frame.maxY - screenRect.maxY,
            width: screenRect.width,
            height: screenRect.height
        )
        guard relative.width > 0, relative.height > 0 else { throw CaptureError.invalidSelection }

        let configuration = SCStreamConfiguration()
        configuration.sourceRect = relative
        configuration.width = Int(relative.width * nsScreen.backingScaleFactor)
        configuration.height = Int(relative.height * nsScreen.backingScaleFactor)
        configuration.showsCursor = false
        configuration.captureResolution = .best
        do {
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            try Task.checkCancellation()
            return BoardCapture(image: image, screenRect: screenRect)
        } catch {
            cachedFilter = nil
            throw error
        }
    }
}
