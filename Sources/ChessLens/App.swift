import AppKit
import Carbon.HIToolbox

@main
enum ChessLensMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

private struct BoardSettleResult {
    let capture: BoardCapture
    let observation: BoardObservation
    let isStable: Bool
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let selection = SelectionController()
    private let screenshotService = ScreenshotService()
    private let scanner = BoardScanner()
    private let vision = BoardVision()
    private var overlay: MoveOverlayController!
    private var editor: BoardEditorController?
    private var statusItem: NSStatusItem?
    private var hotKey: GlobalHotKey?
    private var latestCapture: BoardCapture?
    private var captureTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?
    private var automaticWatchActive = false
    private var sessionPosition: Position?
    private var sessionRect: CGRect?
    private var sessionWhiteAtBottom = true
    private var sessionAssistedColor: PieceColor?
    private var sessionObservation: BoardObservation?
    private var sessionAppearanceModel: SessionBoardModel?
    private var monitoringMessage = "Watching board"
    private var suppressedSuggestionFEN: String?

    private let positionDefaultsKey = "ChessLens.lastPosition.v2"
    private let orientationDefaultsKey = "ChessLens.whiteAtBottom"
    private let playerColorDefaultsKey = "ChessLens.playerColor"
    private let boardQuietSeconds: TimeInterval = 2.0
    private let boardSettleTimeoutSeconds: TimeInterval = 20.0
    private let stableFrameDistanceThreshold = 0.002

    private func waitForBoardToSettle(
        startingWith capture: BoardCapture,
        whiteAtBottom: Bool
    ) async throws -> BoardSettleResult {
        let startedAt = ProcessInfo.processInfo.systemUptime
        var gate = VisualStabilityGate(
            startedAt: startedAt,
            quietSeconds: boardQuietSeconds,
            changeThreshold: stableFrameDistanceThreshold
        )
        guard var previous = vision.observe(image: capture.image, whiteAtBottom: whiteAtBottom) else {
            throw CaptureError.invalidSelection
        }
        var anchor = previous

        while true {
            try await Task.sleep(nanoseconds: 200_000_000)
            let nextCapture = try await screenshotService.capture(
                screenRect: capture.screenRect,
                settleDelayNanoseconds: 0
            )
            try Task.checkCancellation()
            guard let next = vision.observe(
                image: nextCapture.image,
                whiteAtBottom: whiteAtBottom
            ) else { throw CaptureError.invalidSelection }
            let now = ProcessInfo.processInfo.systemUptime
            let frameDistance = max(previous.motionDistance(to: next), anchor.motionDistance(to: next))
            let isStable = gate.observe(frameDistance: frameDistance, at: now)
            if frameDistance >= stableFrameDistanceThreshold { anchor = next }
            let latest = BoardSettleResult(capture: nextCapture, observation: next, isStable: isStable)
            if isStable || now - startedAt >= boardSettleTimeoutSeconds { return latest }
            previous = next
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        overlay = MoveOverlayController(
            onHide: { [weak self] in self?.overlayClosedByUser() },
            onRefresh: { [weak self] in self?.refreshSessionPressed() }
        )
        buildStatusItem()
        hotKey = GlobalHotKey { [weak self] in self?.hotKeyPressed() }

        if !UserDefaults.standard.bool(forKey: "ChessLens.didShowWelcome") {
            UserDefaults.standard.set(true, forKey: "ChessLens.didShowWelcome")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.showInstructions() }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "scope", accessibilityDescription: "ChessLens")
            button.toolTip = "ChessLens — ⌘⇧8"
        }
        statusItem = item
        refreshMenu()
    }

    private func refreshMenu() {
        let menu = NSMenu()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.3"
        let appName = NSMenuItem(title: "ChessLens \(version)", action: nil, keyEquivalent: "")
        appName.isEnabled = false
        menu.addItem(appName)
        menu.addItem(.separator())
        let capture = NSMenuItem(title: "Select chessboard", action: #selector(capturePressed), keyEquivalent: "")
        capture.target = self
        menu.addItem(capture)

        let hide = NSMenuItem(title: suppressedSuggestionFEN == nil ? "Hide suggestion" : "Show suggestion", action: #selector(hideOverlay), keyEquivalent: "")
        hide.target = self
        hide.isEnabled = automaticWatchActive && sessionPosition?.sideToMove == sessionAssistedColor
        menu.addItem(hide)
        let stopWatching = NSMenuItem(title: "Stop automatic watch", action: #selector(stopWatchingPressed), keyEquivalent: "")
        stopWatching.target = self
        stopWatching.isEnabled = automaticWatchActive
        menu.addItem(stopWatching)
        let refresh = NSMenuItem(title: "Refresh capture and next move", action: #selector(refreshSessionPressed), keyEquivalent: "")
        refresh.target = self
        refresh.isEnabled = sessionPosition != nil && sessionRect != nil
        menu.addItem(refresh)
        if automaticWatchActive {
            let state = NSMenuItem(title: monitoringMessage, action: nil, keyEquivalent: "")
            state.isEnabled = false
            menu.addItem(state)
        }
        menu.addItem(.separator())

        let instructions = NSMenuItem(title: "How to use", action: #selector(showInstructions), keyEquivalent: "")
        instructions.target = self
        menu.addItem(instructions)
        let reset = NSMenuItem(title: "Reset visual learning", action: #selector(resetLearning), keyEquivalent: "")
        reset.target = self
        reset.isEnabled = scanner.hasTraining
        menu.addItem(reset)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit ChessLens", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem?.menu = menu
    }

    @objc private func capturePressed() {
        captureTask?.cancel()
        captureTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        analysisTask?.cancel()
        analysisTask = nil
        if automaticWatchActive { stopAutomaticWatch(hideOverlay: false) }
        guard ensureScreenCapturePermission() else { return }
        editor?.close()
        editor = nil
        selection.begin { [weak self] rect in
            guard let self, let rect else { return }
            self.captureTask = Task { @MainActor in
                do {
                    let firstCapture = try await self.screenshotService.capture(screenRect: rect)
                    let whiteAtBottom = UserDefaults.standard.object(forKey: self.orientationDefaultsKey) == nil
                        ? true
                        : UserDefaults.standard.bool(forKey: self.orientationDefaultsKey)
                    let settled = try await self.waitForBoardToSettle(
                        startingWith: firstCapture,
                        whiteAtBottom: whiteAtBottom
                    )
                    if Task.isCancelled { return }
                    self.captureTask = nil
                    guard settled.isStable else {
                        self.showError("The board kept changing. Wait until both players finish moving, then select it again.")
                        return
                    }
                    self.latestCapture = settled.capture
                    self.presentEditor(for: settled.capture)
                } catch is CancellationError {
                    return
                } catch {
                    if Task.isCancelled { return }
                    self.captureTask = nil
                    self.showError(error.localizedDescription)
                }
            }
        }
    }

    private func hotKeyPressed() {
        // Repeated ⌘⇧8 updates the existing board. It never silently ends the
        // automatic session; the menu offers Select chessboard for a new area.
        if sessionPosition != nil, sessionRect != nil {
            refreshSessionPressed()
        } else {
            capturePressed()
        }
    }

    private func ensureScreenCapturePermission() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        if CGRequestScreenCaptureAccess() { return true }

        let alert = NSAlert()
        alert.messageText = "Screen Recording permission is required"
        alert.informativeText = "ChessLens needs permission only to capture the board area you select. Enable ChessLens in System Settings → Privacy & Security → Screen & System Audio Recording, then quit and reopen ChessLens.\n\nيحتاج ChessLens إلى إذن تسجيل الشاشة لالتقاط منطقة الرقعة التي تحددها فقط. فعّل التطبيق من إعدادات الخصوصية، ثم أغلقه وافتحه من جديد."
        alert.addButton(withTitle: "Open Privacy Settings")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn,
           let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(settingsURL)
        }
        return false
    }

    private func presentEditor(
        for capture: BoardCapture,
        reviewReason: String? = nil,
        orientation: Bool? = nil,
        sideToMove: PieceColor? = nil,
        playerColor: PieceColor? = nil,
        additionalReviewSquares: Set<Int> = []
    ) {
        let storedOrientation = UserDefaults.standard.object(forKey: orientationDefaultsKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: orientationDefaultsKey)
        let whiteAtBottom = orientation ?? storedOrientation
        let storedPlayerColor = UserDefaults.standard.string(forKey: playerColorDefaultsKey)
            .flatMap(PieceColor.init(rawValue:)) ?? .white
        let assistedColor = playerColor ?? storedPlayerColor
        // A screenshot cannot reveal whose turn it is. Never import the turn or pieces
        // from a different puzzle; the editor explicitly asks the user to confirm it.
        let assumedSide = sideToMove ?? assistedColor
        let prediction = scanner.predict(image: capture.image, whiteAtBottom: whiteAtBottom, sideToMove: assumedSide)
        let initialPosition = prediction?.position ?? Position(sideToMove: assumedSide)
        let uncertainSquares = Set(prediction?.uncertainSquares ?? Array(0..<64)).union(additionalReviewSquares)
        let scanStatus: String
        if prediction != nil {
            scanStatus = uncertainSquares.isEmpty
                ? "Current image: all 64 squares matched. Verify the badges and side to move."
                : "Current image: \(64 - uncertainSquares.count)/64 squares matched. Correct the orange ? squares, then check whose turn it is."
        } else {
            scanStatus = "No matching shapes yet. Mark the actual pieces, or use Start position only if this is the starting board."
        }

        let controller = BoardEditorController(
            image: capture.image,
            position: initialPosition,
            whiteAtBottom: whiteAtBottom,
            assistedColor: assistedColor,
            scanStatus: [reviewReason, scanStatus].compactMap { $0 }.joined(separator: "\n"),
            requiresReview: true,
            learnedSummary: scanner.learnedSummary,
            uncertainSquares: uncertainSquares
        ) { [weak self] position, orientation, playerColor in
            self?.beginAssistance(position: position, whiteAtBottom: orientation, assistedColor: playerColor, confirmedCapture: capture)
        } onLearn: { [weak self] position, orientation, playerColor in
            self?.saveLearnedShapes(position: position, whiteAtBottom: orientation, assistedColor: playerColor, confirmedCapture: capture)
        }
        editor = controller
        controller.show()
    }

    private func saveLearnedShapes(position: Position, whiteAtBottom: Bool, assistedColor: PieceColor, confirmedCapture: BoardCapture) {
        guard validateConfirmedLabels(position, capture: confirmedCapture, whiteAtBottom: whiteAtBottom, assistedColor: assistedColor) else { return }
        stopAutomaticWatch()
        statusItem?.button?.image = NSImage(
            systemSymbolName: "hourglass",
            accessibilityDescription: "Checking piece shapes after board settles"
        )
        analysisTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let settled = try await self.waitForBoardToSettle(
                    startingWith: confirmedCapture,
                    whiteAtBottom: whiteAtBottom
                )
                if Task.isCancelled { return }
                self.analysisTask = nil
                self.statusItem?.button?.image = NSImage(systemSymbolName: "scope", accessibilityDescription: "ChessLens")
                guard settled.isStable else {
                    self.showError("The board kept changing. No shapes were saved; wait and capture it again.")
                    return
                }
                guard let confirmedObservation = self.vision.observe(
                    image: confirmedCapture.image,
                    whiteAtBottom: whiteAtBottom
                ) else { throw CaptureError.invalidSelection }
                let model = SessionBoardModel(position: position, observation: confirmedObservation)
                guard let verified = model.reconcile(
                    position: position, baseline: confirmedObservation, observed: settled.observation
                ), verified.moves.isEmpty else {
                    self.latestCapture = settled.capture
                    self.editor?.close()
                    self.presentEditor(
                        for: settled.capture,
                        reviewReason: "The board changed before saving. This is a fresh scan; confirm whose turn it is.",
                        orientation: whiteAtBottom, playerColor: assistedColor
                    )
                    return
                }
                self.latestCapture = settled.capture
                let learning = self.scanner.learn(image: settled.capture.image, position: position, whiteAtBottom: whiteAtBottom)
                guard learning.accepted else {
                    self.presentEditor(for: settled.capture,
                                       reviewReason: "Nothing was saved: some labels disagree with the visible pieces.",
                                       orientation: whiteAtBottom, sideToMove: position.sideToMove, playerColor: assistedColor,
                                       additionalReviewSquares: Set(learning.rejectedSquares))
                    return
                }
                self.savePosition(position)
                UserDefaults.standard.set(whiteAtBottom, forKey: self.orientationDefaultsKey)
                UserDefaults.standard.set(assistedColor.rawValue, forKey: self.playerColorDefaultsKey)
                self.refreshMenu()

                let alert = NSAlert()
                alert.messageText = "Piece shapes saved"
                alert.informativeText = "\(self.scanner.learnedSummary). ChessLens will use these separate white and black piece samples in future captures of this board theme."
                alert.alertStyle = .informational
                alert.addButton(withTitle: "OK")
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                self.analysisTask = nil
                self.statusItem?.button?.image = NSImage(systemSymbolName: "scope", accessibilityDescription: "ChessLens")
                self.showError(error.localizedDescription)
            }
        }
    }

    private func beginAssistance(
        position: Position,
        whiteAtBottom: Bool,
        assistedColor: PieceColor,
        confirmedCapture: BoardCapture,
        learnConfirmed: Bool = true
    ) {
        guard validateConfirmedLabels(position, capture: confirmedCapture, whiteAtBottom: whiteAtBottom, assistedColor: assistedColor) else { return }
        stopAutomaticWatch(hideOverlay: true, clearSession: learnConfirmed)
        statusItem?.button?.image = NSImage(
            systemSymbolName: "hourglass",
            accessibilityDescription: "Checking that the board stopped moving"
        )
        analysisTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let settled = try await self.waitForBoardToSettle(
                    startingWith: confirmedCapture,
                    whiteAtBottom: whiteAtBottom
                )
                if Task.isCancelled { return }
                self.analysisTask = nil
                guard settled.isStable else {
                    self.statusItem?.button?.image = NSImage(systemSymbolName: "scope", accessibilityDescription: "ChessLens")
                    self.showError("The board kept changing. Wait until both players finish moving, then capture it again.")
                    return
                }
                guard let confirmedObservation = self.vision.observe(
                    image: confirmedCapture.image,
                    whiteAtBottom: whiteAtBottom
                ) else { throw CaptureError.invalidSelection }
                let model = learnConfirmed
                    ? SessionBoardModel(position: position, observation: confirmedObservation)
                    : self.sessionAppearanceModel ?? SessionBoardModel(position: position, observation: confirmedObservation)
                guard let verified = model.reconcile(
                    position: position, baseline: confirmedObservation, observed: settled.observation
                ) else {
                    self.latestCapture = settled.capture
                    self.statusItem?.button?.image = NSImage(systemSymbolName: "scope", accessibilityDescription: "ChessLens")
                    self.editor?.close()
                    self.presentEditor(
                        for: settled.capture,
                        reviewReason: "The board changed while you were confirming it. This is a fresh scan; confirm whose turn it is.",
                        orientation: whiteAtBottom, playerColor: assistedColor
                    )
                    return
                }
                self.beginVerifiedAssistance(
                    position: verified.position,
                    whiteAtBottom: whiteAtBottom,
                    assistedColor: assistedColor,
                    capture: settled.capture,
                    learnConfirmed: learnConfirmed && verified.moves.isEmpty,
                    appearanceModel: model
                )
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                self.analysisTask = nil
                self.statusItem?.button?.image = NSImage(systemSymbolName: "scope", accessibilityDescription: "ChessLens")
                self.showError(error.localizedDescription)
            }
        }
    }

    private func beginVerifiedAssistance(
        position: Position,
        whiteAtBottom: Bool,
        assistedColor: PieceColor,
        capture: BoardCapture,
        learnConfirmed: Bool,
        appearanceModel: SessionBoardModel
    ) {
        editor?.close()
        editor = nil
        latestCapture = capture
        if learnConfirmed {
            let learning = scanner.learn(image: capture.image, position: position, whiteAtBottom: whiteAtBottom)
            guard learning.accepted else {
                statusItem?.button?.image = NSImage(systemSymbolName: "scope", accessibilityDescription: "Review board")
                presentEditor(for: capture,
                              reviewReason: "Nothing was saved: some labels disagree with the visible pieces.",
                              orientation: whiteAtBottom, sideToMove: position.sideToMove, playerColor: assistedColor,
                              additionalReviewSquares: Set(learning.rejectedSquares))
                return
            }
        }
        savePosition(position)
        UserDefaults.standard.set(whiteAtBottom, forKey: orientationDefaultsKey)
        UserDefaults.standard.set(assistedColor.rawValue, forKey: playerColorDefaultsKey)
        refreshMenu()

        startAutomaticWatch(
            position: position,
            baselineCapture: capture,
            assistedColor: assistedColor,
            whiteAtBottom: whiteAtBottom,
            appearanceModel: appearanceModel
        )
    }

    private func validateConfirmedLabels(_ position: Position, capture: BoardCapture, whiteAtBottom: Bool, assistedColor: PieceColor) -> Bool {
        let issues = scanner.learningIssues(image: capture.image, position: position, whiteAtBottom: whiteAtBottom)
        guard issues.isEmpty else {
            presentEditor(for: capture,
                          reviewReason: "Some badges mark empty squares as pieces, or miss visible pieces. Correct the orange ? squares; nothing has been saved.",
                          orientation: whiteAtBottom, sideToMove: position.sideToMove, playerColor: assistedColor,
                          additionalReviewSquares: Set(issues))
            return false
        }
        return true
    }

    private func showMonitoringStatus(_ message: String, on rect: CGRect) {
        overlay.showStatus(on: rect, detail: message)
        statusItem?.button?.image = NSImage(systemSymbolName: "eye", accessibilityDescription: message)
        if monitoringMessage != message {
            monitoringMessage = message
            refreshMenu()
        }
    }

    private func startAutomaticWatch(
        position: Position,
        baselineCapture: BoardCapture,
        assistedColor: PieceColor,
        whiteAtBottom: Bool,
        appearanceModel: SessionBoardModel
    ) {
        guard let initialObservation = vision.observe(image: baselineCapture.image, whiteAtBottom: whiteAtBottom) else {
            showError("The board image could not be read. Select the complete board again.")
            return
        }
        stopAutomaticWatch(hideOverlay: false, clearSession: false)
        automaticWatchActive = true
        let watchedRect = baselineCapture.screenRect
        sessionPosition = position
        sessionRect = watchedRect
        sessionWhiteAtBottom = whiteAtBottom
        sessionAssistedColor = assistedColor
        sessionObservation = initialObservation
        sessionAppearanceModel = appearanceModel
        latestCapture = baselineCapture
        showMonitoringStatus("Checking board…", on: watchedRect)
        refreshMenu()

        monitorTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var currentPosition = position
            var baseline = initialObservation
            var previous = initialObservation
            var quietAnchor = initialObservation
            var gate = VisualStabilityGate(
                startedAt: ProcessInfo.processInfo.systemUptime - self.boardQuietSeconds,
                quietSeconds: self.boardQuietSeconds,
                changeThreshold: self.stableFrameDistanceThreshold
            )
            var lastReconciliationAt = -Double.infinity
            var analyzedFEN: String?
            var cachedSuggestion: SearchResult?
            var showingArrow = false
            var captureFailures = 0

            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: captureFailures > 0 ? 1_000_000_000 : 220_000_000)
                    let capture = try await self.screenshotService.capture(screenRect: watchedRect, settleDelayNanoseconds: 0)
                    try Task.checkCancellation()
                    guard let observed = self.vision.observe(image: capture.image, whiteAtBottom: whiteAtBottom) else {
                        throw CaptureError.invalidSelection
                    }
                    captureFailures = 0
                    let now = ProcessInfo.processInfo.systemUptime
                    let motion = max(previous.motionDistance(to: observed), quietAnchor.motionDistance(to: observed))
                    let isStable = gate.observe(frameDistance: motion, at: now)
                    previous = observed
                    if motion >= self.stableFrameDistanceThreshold {
                        quietAnchor = observed
                        showingArrow = false
                        self.showMonitoringStatus("Waiting for board to settle…", on: watchedRect)
                    }
                    guard isStable, now - lastReconciliationAt >= 0.65 else { continue }
                    lastReconciliationAt = now

                    // Reconcile the complete stable board, even if BOTH moves happened
                    // between screenshots. A one-move detector must not gate this step.
                    guard let recovered = appearanceModel.reconcile(
                        position: currentPosition, baseline: baseline, observed: observed
                    ) else {
                        analyzedFEN = nil
                        cachedSuggestion = nil
                        showingArrow = false
                        self.showMonitoringStatus("Rechecking board · ↻ to review", on: watchedRect)
                        continue
                    }

                    if !recovered.moves.isEmpty {
                        currentPosition = recovered.position
                        baseline = observed
                        self.sessionPosition = currentPosition
                        self.sessionObservation = observed
                        self.savePosition(currentPosition)
                        self.suppressedSuggestionFEN = nil
                        analyzedFEN = nil
                        cachedSuggestion = nil
                        showingArrow = false
                    }
                    if self.suppressedSuggestionFEN == currentPosition.fen {
                        showingArrow = false
                    }
                    self.latestCapture = capture
                    if currentPosition.sideToMove != assistedColor {
                        showingArrow = false
                        let color = currentPosition.sideToMove == .white ? "White" : "Black"
                        self.showMonitoringStatus("Waiting for \(color)…", on: watchedRect)
                        continue
                    }

                    if analyzedFEN == currentPosition.fen {
                        if let result = cachedSuggestion,
                           !showingArrow,
                           self.suppressedSuggestionFEN != currentPosition.fen {
                            self.overlay.show(
                                move: result.move, on: watchedRect, whiteAtBottom: whiteAtBottom,
                                detail: "\(result.move.uci)  SF d\(result.depth)"
                            )
                            showingArrow = true
                            self.monitoringMessage = "Your turn · \(result.move.uci)"
                            self.statusItem?.button?.image = NSImage(systemSymbolName: "scope", accessibilityDescription: "Your move")
                            self.refreshMenu()
                        } else if cachedSuggestion == nil {
                            self.showMonitoringStatus(
                                currentPosition.isKingInCheck(currentPosition.sideToMove) ? "Checkmate" : "No legal move",
                                on: watchedRect
                            )
                        }
                        continue
                    }

                    self.showMonitoringStatus("Analyzing…", on: watchedRect)
                    showingArrow = false
                    let positionToAnalyze = currentPosition
                    let result = await Task.detached(priority: .userInitiated) {
                        BestMoveService.bestMove(in: positionToAnalyze)
                    }.value
                    try Task.checkCancellation()

                    // A move may occur while Stockfish is thinking. Never publish its
                    // result on a changed board; let the loop recover the new position.
                    let afterCapture = try await self.screenshotService.capture(screenRect: watchedRect, settleDelayNanoseconds: 0)
                    try Task.checkCancellation()
                    guard let after = self.vision.observe(image: afterCapture.image, whiteAtBottom: whiteAtBottom) else {
                        throw CaptureError.invalidSelection
                    }
                    if after.motionDistance(to: observed) >= self.stableFrameDistanceThreshold {
                        previous = after
                        quietAnchor = after
                        gate = VisualStabilityGate(
                            startedAt: ProcessInfo.processInfo.systemUptime,
                            quietSeconds: self.boardQuietSeconds,
                            changeThreshold: self.stableFrameDistanceThreshold
                        )
                        self.showMonitoringStatus("Board changed · waiting…", on: watchedRect)
                        continue
                    }

                    analyzedFEN = currentPosition.fen
                    cachedSuggestion = result
                    self.latestCapture = afterCapture
                    if let result {
                        if self.suppressedSuggestionFEN == currentPosition.fen {
                            self.showMonitoringStatus("Suggestion hidden · watching…", on: watchedRect)
                        } else {
                            self.overlay.show(
                                move: result.move, on: watchedRect, whiteAtBottom: whiteAtBottom,
                                detail: "\(result.move.uci)  SF d\(result.depth)"
                            )
                            showingArrow = true
                            self.monitoringMessage = "Your turn · \(result.move.uci)"
                            self.statusItem?.button?.image = NSImage(systemSymbolName: "scope", accessibilityDescription: "Your move")
                            self.refreshMenu()
                        }
                    } else {
                        self.showMonitoringStatus(
                            currentPosition.isKingInCheck(currentPosition.sideToMove) ? "Checkmate" : "No legal move",
                            on: watchedRect
                        )
                    }
                } catch is CancellationError {
                    return
                } catch {
                    if Task.isCancelled { return }
                    captureFailures += 1
                    showingArrow = false
                    self.showMonitoringStatus("Capture interrupted · retrying…", on: watchedRect)
                }
            }
        }
    }

    private func stopAutomaticWatch(hideOverlay: Bool = true, clearSession: Bool = true) {
        analysisTask?.cancel()
        analysisTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        monitorTask?.cancel()
        monitorTask = nil
        automaticWatchActive = false
        if hideOverlay { overlay?.hide() }
        statusItem?.button?.image = NSImage(systemSymbolName: "scope", accessibilityDescription: "ChessLens")
        if clearSession {
            suppressedSuggestionFEN = nil
            sessionPosition = nil
            sessionRect = nil
            sessionAssistedColor = nil
            sessionObservation = nil
            sessionAppearanceModel = nil
        }
        refreshMenu()
    }

    @objc private func refreshSessionPressed() {
        guard ensureScreenCapturePermission(),
              let position = sessionPosition,
              let rect = sessionRect,
              let assistedColor = sessionAssistedColor,
              let baseline = sessionObservation,
              let appearanceModel = sessionAppearanceModel else { return }
        let whiteAtBottom = sessionWhiteAtBottom
        let recoveryCapture = latestCapture
        suppressedSuggestionFEN = nil
        editor?.close()
        editor = nil
        captureTask?.cancel()
        captureTask = nil
        stopAutomaticWatch(hideOverlay: false, clearSession: false)
        showMonitoringStatus("Refreshing board…", on: rect)

        refreshTask = Task { @MainActor in
            do {
                let firstCapture = try await screenshotService.capture(screenRect: rect, settleDelayNanoseconds: 0)
                let settled = try await waitForBoardToSettle(startingWith: firstCapture, whiteAtBottom: whiteAtBottom)
                try Task.checkCancellation()
                latestCapture = settled.capture
                guard settled.isStable else {
                    refreshTask = nil
                    if let recoveryCapture {
                        startAutomaticWatch(position: position, baselineCapture: recoveryCapture,
                                            assistedColor: assistedColor, whiteAtBottom: whiteAtBottom,
                                            appearanceModel: appearanceModel)
                        showMonitoringStatus("Board still moving · watching…", on: rect)
                    }
                    return
                }
                guard let recovered = appearanceModel.reconcile(
                    position: position, baseline: baseline, observed: settled.observation
                ) else {
                    refreshTask = nil
                    showMonitoringStatus("Board review needed", on: rect)
                    presentEditor(
                        for: settled.capture,
                        reviewReason: "Move history could not be recovered. This is a fresh scan; confirm whose turn it is.",
                        orientation: whiteAtBottom, playerColor: assistedColor
                    )
                    return
                }
                refreshTask = nil
                beginVerifiedAssistance(
                    position: recovered.position,
                    whiteAtBottom: whiteAtBottom,
                    assistedColor: assistedColor,
                    capture: settled.capture,
                    learnConfirmed: false,
                    appearanceModel: appearanceModel
                )
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                refreshTask = nil
                if let recoveryCapture {
                    startAutomaticWatch(position: position, baselineCapture: recoveryCapture,
                                        assistedColor: assistedColor, whiteAtBottom: whiteAtBottom,
                                        appearanceModel: appearanceModel)
                    showMonitoringStatus("Capture interrupted · retrying…", on: rect)
                } else {
                    showMonitoringStatus("Capture unavailable · ↻ to retry", on: rect)
                }
            }
        }
    }

    private func savePosition(_ position: Position) {
        if let data = try? JSONEncoder().encode(position) {
            UserDefaults.standard.set(data, forKey: positionDefaultsKey)
        }
    }

    @objc private func hideOverlay() {
        guard automaticWatchActive, let rect = sessionRect else { return }
        if suppressedSuggestionFEN == sessionPosition?.fen {
            suppressedSuggestionFEN = nil
            showMonitoringStatus("Checking board…", on: rect)
            refreshMenu()
            return
        }
        suppressedSuggestionFEN = sessionPosition?.fen
        showMonitoringStatus("Suggestion hidden · watching…", on: rect)
        refreshMenu()
    }

    @objc private func stopWatchingPressed() { stopAutomaticWatch() }

    private func overlayClosedByUser() {
        stopAutomaticWatch(hideOverlay: false)
    }

    @objc private func resetLearning() {
        let alert = NSAlert()
        alert.messageText = "Reset learned board images?"
        alert.informativeText = "Your saved visual samples will be removed. Built-in shapes remain available. Future captures use only the current screenshot, never badges from a previous position."
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        if alert.runModal() == .alertFirstButtonReturn {
            scanner.reset()
            refreshMenu()
        }
    }

    @objc private func showInstructions() {
        let alert = NSAlert()
        alert.messageText = "ChessLens"
        alert.informativeText = "Press ⌘⇧8, then select the complete square board. Every scan uses the current screenshot, never an old position. Correct orange ? squares, verify the badges, your color and whose turn it is. ChessLens waits for two quiet seconds and recovers up to two consecutive legal moves from the final board. The status bar stays visible while waiting; ↻ retries recovery and × stops watching.\n\nBuilt-in shapes recognize the standard theme; confirmed captures teach other themes locally. Choose Start position only when the screenshot actually shows the starting position. Only confirmed, visually consistent labels are saved. Use ChessLens for study and offline practice."
        alert.addButton(withTitle: "Got it")
        alert.alertStyle = .informational
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "ChessLens"
        alert.informativeText = message
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func quitApp() { NSApp.terminate(nil) }
}

final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return OSStatus(eventNotHandledErr) }
                let manager = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { manager.action() }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
        let hotKeyID = EventHotKeyID(signature: 0x434C454E, id: 1) // CLEN
        RegisterEventHotKey(
            UInt32(kVK_ANSI_8),
            UInt32(cmdKey | shiftKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
