import AppKit
import SwiftUI
import OSLog
import PrayerKit

/// Owns the Focus Mode screen block: a full-screen overlay on every display that
/// covers the desktop at prayer time, holds for a configured duration, then
/// releases. A *discipline aid*, not a true lock — macOS always allows Force Quit
/// — so the design leans on covering, focus capture, and hiding the Dock/menu bar
/// rather than pretending to be a kiosk.
@MainActor
final class FocusModeController {

    private let log = Logger(subsystem: "co.tareq.prayertimes", category: "focus")

    private var windows: [NSWindow] = []
    private var keyMonitor: Any?
    private var releaseTask: Task<Void, Never>?
    private var priorPolicy: NSApplication.ActivationPolicy = .accessory
    private var priorPresentation: NSApplication.PresentationOptions = []

    /// Whether a block is currently up (prevents overlapping prayers stacking).
    private(set) var isActive = false

    // MARK: Entry points

    /// Begin a real block for `prayer`, honoring the safeguards: never engage when
    /// the screen is locked or a fullscreen app (likely a call/presentation) is
    /// frontmost — those would be the worst moments to black out the screen.
    func begin(prayer: Prayer, settings: AppSettings) {
        guard !isActive else { return }
        if sessionIsLocked() {
            log.debug("Focus skipped: session locked")
            return
        }
        if frontmostAppIsFullscreen() {
            log.debug("Focus skipped: a fullscreen app is frontmost")
            return
        }
        start(prayer: prayer,
              duration: TimeInterval(max(1, settings.focusDurationMinutes) * 60),
              emergencyExit: settings.focusEmergencyExitEnabled,
              intensity: settings.focusBlurIntensity)
    }

    /// Short preview for the Settings "Try it" button: always engages (ignores the
    /// fullscreen/lock safeguards) and always allows the emergency exit, so the
    /// user can confirm the look and that Cmd+Esc works before relying on it.
    func runDemo(settings: AppSettings) {
        guard !isActive else { return }
        start(prayer: .dhuhr, duration: 10, emergencyExit: true, intensity: settings.focusBlurIntensity)
    }

    /// Release the block immediately (timer expiry, emergency exit, or programmatic).
    func end() {
        guard isActive else { return }
        isActive = false
        releaseTask?.cancel(); releaseTask = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }

        let closing = windows
        windows = []
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.45
            for w in closing { w.animator().alphaValue = 0 }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            for w in closing { w.orderOut(nil); w.close() }
        }

        NSApp.presentationOptions = priorPresentation
        NSApp.setActivationPolicy(priorPolicy)
        NotificationCenter.default.removeObserver(self, name: NSApplication.didChangeScreenParametersNotification, object: nil)
        log.debug("Focus ended")
    }

    // MARK: Block lifecycle

    private func start(prayer: Prayer, duration: TimeInterval, emergencyExit: Bool, intensity: FocusBlurIntensity) {
        log.debug("Focus begin: \(prayer.rawValue, privacy: .public) for \(Int(duration))s")
        isActive = true
        priorPolicy = NSApp.activationPolicy()
        priorPresentation = NSApp.presentationOptions

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Hide the Dock and menu bar and steer the user away from app-switching.
        NSApp.presentationOptions = [.hideDock, .hideMenuBar, .disableProcessSwitching,
                                     .disableAppleMenu, .disableHideApplication]

        let endsAt = Date().addingTimeInterval(duration)
        let scripture = FocusScripture.random()
        buildWindows(prayer: prayer, scripture: scripture, endsAt: endsAt, emergencyExit: emergencyExit, intensity: intensity)
        installKeyMonitor(emergencyExit: emergencyExit)

        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)

        releaseTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self?.end()
        }

        // Remember inputs so a display reconfiguration can rebuild the overlays.
        rebuildContext = (prayer, scripture, endsAt, emergencyExit, intensity)
    }

    private var rebuildContext: (prayer: Prayer, scripture: FocusScripture, endsAt: Date, emergencyExit: Bool, intensity: FocusBlurIntensity)?

    private func buildWindows(prayer: Prayer, scripture: FocusScripture, endsAt: Date, emergencyExit: Bool, intensity: FocusBlurIntensity) {
        for screen in NSScreen.screens {
            let root = FocusOverlayView(prayer: prayer, scripture: scripture, endsAt: endsAt,
                                        emergencyExitEnabled: emergencyExit, intensity: intensity,
                                        onDismiss: { [weak self] in self?.end() })
            let window = OverlayWindow(
                contentRect: screen.frame, styleMask: [.borderless],
                backing: .buffered, defer: false)
            window.onEmergencyExit = emergencyExit ? { [weak self] in self?.end() } : nil
            window.isReleasedWhenClosed = false
            window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            window.alphaValue = 0

            // Desktop blur behind the SwiftUI overlay; intensity is carried mostly
            // by the overlay's own backdrop opacity.
            let blur = NSVisualEffectView()
            blur.material = .fullScreenUI
            blur.blendingMode = .behindWindow
            blur.state = .active
            blur.autoresizingMask = [.width, .height]
            let hosting = NSHostingView(rootView: root)
            hosting.frame = blur.bounds
            hosting.autoresizingMask = [.width, .height]
            blur.addSubview(hosting)
            window.contentView = blur

            window.setFrame(screen.frame, display: true)
            window.orderFrontRegardless()
            window.animator().alphaValue = 1
            windows.append(window)
        }
        windows.first?.makeKey()
    }

    @objc private func screensChanged() {
        guard isActive, let ctx = rebuildContext else { return }
        for w in windows { w.orderOut(nil); w.close() }
        windows = []
        buildWindows(prayer: ctx.prayer, scripture: ctx.scripture, endsAt: ctx.endsAt,
                     emergencyExit: ctx.emergencyExit, intensity: ctx.intensity)
    }

    // MARK: Input capture

    /// Swallow keystrokes while the block is up; Cmd+Esc releases it when the
    /// emergency exit is enabled. (Global system shortcuts like Cmd+Opt+Esc are
    /// handled by the WindowServer and intentionally remain available.)
    private func installKeyMonitor(emergencyExit: Bool) {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            if emergencyExit, event.type == .keyDown,
               Self.isEmergencyExit(keyCode: event.keyCode,
                                    modifiers: event.modifierFlags,
                                    charactersIgnoringModifiers: event.charactersIgnoringModifiers) {
                self?.end()
            }
            return nil   // swallow everything else
        }
    }

    /// Kept separate from AppKit event delivery so the shortcut contract remains
    /// regression-testable even when CI has no interactive WindowServer session.
    ///
    /// Escape is matched by *character* as well as by keycode: a remapped or
    /// non-US layout can deliver Escape on a keycode other than 53, and matching
    /// only the keycode silently disarms the exit for those users.
    ///
    /// Grave (`) counts too. It sits directly below Escape, so it is what a
    /// Command-held reach for Escape lands on when the hand shifts down a row —
    /// and it is what "Grave Escape" keyboards deliberately emit for Escape while
    /// Command is down. The overlay swallows all input anyway, so ⌘` has no
    /// competing meaning here, and being wrong about the exit strands the user.
    static func isEmergencyExit(keyCode: UInt16,
                                modifiers: NSEvent.ModifierFlags,
                                charactersIgnoringModifiers: String? = nil) -> Bool {
        guard modifiers.intersection(.deviceIndependentFlagsMask).contains(.command) else { return false }
        if keyCode == 53 || keyCode == 50 { return true }
        guard let scalar = charactersIgnoringModifiers?.unicodeScalars.first else { return false }
        return scalar == "\u{1b}" || scalar == "`"
    }

    // MARK: Safeguards

    private func sessionIsLocked() -> Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (dict["CGSSessionScreenIsLocked"] as? Int) == 1
    }

    /// Heuristic: the frontmost app owns an on-screen, base-layer window that covers
    /// a whole display ⇒ it's running fullscreen (Keynote, a video call, full-screen
    /// video). We require the window to match the screen's *full* frame, which a
    /// merely maximized window doesn't (it fills only `visibleFrame`, below the menu
    /// bar), so ordinary maximized windows don't trigger a skip. Public APIs only —
    /// reads PID/layer/bounds, not window names, so no Screen Recording prompt.
    private func frontmostAppIsFullscreen() -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication else { return false }
        let pid = front.processIdentifier
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let infos = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return false }
        for info in infos {
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let b = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let w = b["Width"], let h = b["Height"] else { continue }
            for screen in NSScreen.screens where abs(w - screen.frame.width) < 2 && abs(h - screen.frame.height) < 2 {
                return true
            }
        }
        return false
    }
}

/// Borderless windows can't become key by default; the overlay needs key status to
/// receive the emergency-exit keystroke and to keep focus on itself.
private final class OverlayWindow: NSWindow {
    var onEmergencyExit: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        if FocusModeController.isEmergencyExit(keyCode: event.keyCode,
                                               modifiers: event.modifierFlags,
                                               charactersIgnoringModifiers: event.charactersIgnoringModifiers),
           let onEmergencyExit {
            onEmergencyExit()
            return
        }
        super.keyDown(with: event)
    }
}
