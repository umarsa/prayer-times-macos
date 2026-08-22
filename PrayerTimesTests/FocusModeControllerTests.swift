import AppKit
import Testing
@testable import Prayer_Times

@MainActor
struct FocusModeControllerTests {
    @Test("Command-Escape triggers emergency exit")
    func commandEscapeTriggersExit() {
        #expect(FocusModeController.isEmergencyExit(keyCode: 53, modifiers: .command))
    }

    @Test("Command-Escape tolerates unrelated modifier-state flags")
    func commandEscapeWithCapsLockTriggersExit() {
        #expect(FocusModeController.isEmergencyExit(
            keyCode: 53,
            modifiers: [.command, .capsLock]
        ))
    }

    @Test("Escape without Command does not trigger emergency exit")
    func escapeAloneDoesNotTriggerExit() {
        #expect(!FocusModeController.isEmergencyExit(keyCode: 53, modifiers: []))
    }

    @Test("Command with another key does not trigger emergency exit")
    func commandOtherKeyDoesNotTriggerExit() {
        #expect(!FocusModeController.isEmergencyExit(keyCode: 12, modifiers: .command))
    }
}
