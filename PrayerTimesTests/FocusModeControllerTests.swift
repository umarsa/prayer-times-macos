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

    /// A remapped or non-US layout can deliver Escape on a keycode other than 53.
    @Test("Command-Escape matches by character when the keycode differs")
    func commandEscapeByCharacterTriggersExit() {
        #expect(FocusModeController.isEmergencyExit(
            keyCode: 200, modifiers: .command, charactersIgnoringModifiers: "\u{1b}"
        ))
    }

    /// Grave sits directly below Escape and is what a Command-held reach for
    /// Escape lands on; observed in the field as keyCode 50 / U+0060.
    @Test("Command-Grave triggers emergency exit")
    func commandGraveTriggersExit() {
        #expect(FocusModeController.isEmergencyExit(
            keyCode: 50, modifiers: .command, charactersIgnoringModifiers: "`"
        ))
    }

    @Test("Grave without Command does not trigger emergency exit")
    func graveAloneDoesNotTriggerExit() {
        #expect(!FocusModeController.isEmergencyExit(
            keyCode: 50, modifiers: [], charactersIgnoringModifiers: "`"
        ))
    }

    @Test("Command with an unrelated character does not trigger emergency exit")
    func commandUnrelatedCharacterDoesNotTriggerExit() {
        #expect(!FocusModeController.isEmergencyExit(
            keyCode: 12, modifiers: .command, charactersIgnoringModifiers: "q"
        ))
    }
}
