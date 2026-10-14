import ApplicationServices
import CoreGraphics
import Foundation

/// The actual desktop-input mechanism. Injected so every command's event
/// sequence is testable without touching the real desktop.
public protocol NativeInputDriver {
    /// Perform an AX action (e.g. "AXPress", "AXShowMenu") on a validated element.
    func performAXAction(_ action: String, on element: LiveAXElement, context: CommandContext) throws
    /// Post a key/modifier chord to a pid (e.g. "cmd+s").
    func postKey(_ chord: String, to pid: Int, context: CommandContext) throws
    /// Post a key/modifier chord globally via the HID event tap — it lands on
    /// whatever holds keyboard focus, like real hardware input.
    func postGlobalKey(_ chord: String, context: CommandContext) throws
    /// Post a key/modifier chord to whatever currently holds keyboard focus,
    /// via the HID event tap. Used by targeted key/type so input reaches
    /// panel- and helper-hosted UI that does not share the app's event queue.
    func postFocusedKey(_ chord: String, context: CommandContext) throws
    /// Post Unicode text to a pid's focused element.
    func postText(_ text: String, to pid: Int, context: CommandContext) throws
    /// Post Unicode text to whatever currently holds keyboard focus, via the
    /// HID event tap — the text counterpart of `postFocusedKey`, so targeted
    /// `type` reaches panel- and helper-hosted UI.
    func postFocusedText(_ text: String, context: CommandContext) throws
    /// Scroll — either a direction in the resolved window, or scroll-to-ref.
    /// `at element` selects scroll-to-ref (AXScrollToVisible); `at point` is the
    /// screen location the directional scroll is delivered to.
    func scroll(_ direction: String, amount: Int, at element: LiveAXElement?, point: CGPoint?, context: CommandContext) throws
    /// Click at a screen point with a validated button/count.
    func click(at point: CGPoint, button: String, count: Int, context: CommandContext) throws
    /// Move the pointer to a screen point.
    func move(to point: CGPoint, context: CommandContext) throws
    /// Left-button drag between two screen points.
    func drag(from start: CGPoint, to end: CGPoint, context: CommandContext) throws
    /// Release any inputs this driver pressed (held keys/buttons). Called on
    /// cancellation/failure; never dispatches after context expiry.
    func releaseHeldInputs() throws
}

/// Validated command-level input. `NativeInput` parses allowlisted chords and
/// delegates the real event work to the injected driver; it owns the key-chord
/// allowlist and the semantic (no-coordinate) constraint.
public final class NativeInput {
    private let driver: NativeInputDriver

    public init(driver: NativeInputDriver) {
        self.driver = driver
    }

    public func press(_ element: LiveAXElement, context: CommandContext) throws {
        try driver.performAXAction("AXPress", on: element, context: context)
    }

    public func setValue(_ element: LiveAXElement, text: String, context: CommandContext) throws {
        // AXValue set is performed via the generic action driver path.
        try driver.performAXAction("AXSetValue:\(text)", on: element, context: context)
    }

    public enum KeyDelivery {
        /// Post to the app's own event queue (reaches background apps, not panels).
        case process
        /// Post to the HID tap so the event lands on whatever holds focus (reaches
        /// panels and helper-hosted UI; the target must be focused).
        case focused
    }

    public func key(_ chord: String, to pid: Int, delivery: KeyDelivery, context: CommandContext) throws {
        guard KeyChord.isValid(chord) else {
            throw NativeFailure("INVALID_ARGUMENT", "Unrecognized key/modifier combination")
        }
        switch delivery {
        case .focused: try driver.postFocusedKey(chord, context: context)
        case .process: try driver.postKey(chord, to: pid, context: context)
        }
    }

    public func globalKey(_ chord: String, context: CommandContext) throws {
        guard KeyChord.isValid(chord) else {
            throw NativeFailure("INVALID_ARGUMENT", "Unrecognized key/modifier combination")
        }
        try driver.postGlobalKey(chord, context: context)
    }

    /// Targetless `type`: text goes to the HID tap and lands on whatever
    /// holds keyboard focus — the text counterpart of `globalKey`.
    public func globalText(_ text: String, context: CommandContext) throws {
        try driver.postFocusedText(text, context: context)
    }

    /// `delivery` is required (no default): `.focused` without the caller
    /// having activated the pid types into whatever holds focus, so the mode
    /// must always be chosen explicitly.
    public func type(_ text: String, to pid: Int, delivery: KeyDelivery, context: CommandContext) throws {
        switch delivery {
        case .focused: try driver.postFocusedText(text, context: context)
        case .process: try driver.postText(text, to: pid, context: context)
        }
    }

    public func scroll(direction: String, amount: Int, at element: LiveAXElement?, point: CGPoint?, context: CommandContext) throws {
        try driver.scroll(direction, amount: amount, at: element, point: point, context: context)
    }

    /// Click with a validated button/count — reject unsupported combos before
    /// any input reaches the driver.
    public func click(at point: CGPoint, button: String, count: Int, context: CommandContext) throws {
        let supported: Bool
        switch button {
        case "left": supported = (1...3).contains(count)
        case "right", "middle": supported = count == 1
        default: supported = false
        }
        guard supported else {
            throw NativeFailure("INVALID_ARGUMENT", "Unsupported button/count combination")
        }
        try driver.click(at: point, button: button, count: count, context: context)
    }

    public func move(to point: CGPoint, context: CommandContext) throws {
        try driver.move(to: point, context: context)
    }

    public func drag(from start: CGPoint, to end: CGPoint, context: CommandContext) throws {
        // Held-button cleanup is owned by the driver; on any failure the caller
        // (or the driver's own defer) must still release the button.
        do {
            try driver.drag(from: start, to: end, context: context)
        } catch {
            try? driver.releaseHeldInputs()
            throw error
        }
    }

    public func releaseHeldInputs() throws {
        try driver.releaseHeldInputs()
    }
}

/// Allowlisted key/modifier chord syntax: `mod+mod+key`, modifiers drawn from
/// {cmd,shift,opt/alt,ctrl,fn}, a single non-modifier key from a known set.
public enum KeyChord {
    private static let modifiers: Set<String> = ["cmd", "command", "shift", "opt", "option", "alt", "ctrl", "control", "fn"]
    private static let keys: Set<String> = [
        "a","b","c","d","e","f","g","h","i","j","k","l","m","n","o","p","q","r","s","t","u","v","w","x","y","z",
        "0","1","2","3","4","5","6","7","8","9",
        "return","enter","tab","space","delete","backspace","escape","esc",
        "up","down","left","right","home","end","pageup","pagedown",
        "f1","f2","f3","f4","f5","f6","f7","f8","f9","f10","f11","f12",
        "minus","equal","leftbracket","rightbracket","backslash","semicolon","quote","comma","period","slash","grave",
    ]

    public static func isValid(_ chord: String) -> Bool {
        let parts = chord.lowercased().split(separator: "+").map(String.init)
        guard !parts.isEmpty else { return false }
        var keyCount = 0
        for part in parts {
            if modifiers.contains(part) { continue }
            guard keys.contains(part) else { return false }
            keyCount += 1
        }
        return keyCount == 1
    }
}

// MARK: - Live driver

/// Real AX/CGEvent input. Owns the actual desktop calls; held-input cleanup
/// releases only what this driver pressed.
public final class LiveInputDriver: NativeInputDriver {
    public init() {}

    public func performAXAction(_ action: String, on element: LiveAXElement, context: CommandContext) throws {
        guard let raw = element.rawValue else {
            throw NativeFailure("STALE_SNAPSHOT", "Live accessibility reference is unavailable")
        }
        try prepareLiveAXMessaging(raw, context: context)
        if action.hasPrefix("AXSetValue:") {
            let value = String(action.dropFirst("AXSetValue:".count))
            let status = AXUIElementSetAttributeValue(raw, kAXValueAttribute as CFString, value as CFTypeRef)
            guard status == .success else { throw liveInputFailure(status) }
            return
        }
        let status = AXUIElementPerformAction(raw, action as CFString)
        guard status == .success else { throw liveInputFailure(status) }
    }

    public func postKey(_ chord: String, to pid: Int, context: CommandContext) throws {
        try context.check()
        // Parse chord into a virtual key + modifier mask; post key down + up.
        guard let (key, modifiers) = KeyChord.toCGEvent(chord) else {
            throw NativeFailure("INVALID_ARGUMENT", "Unrecognized key/modifier combination")
        }
        let source = CGEventSource(stateID: .privateState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else {
            throw NativeFailure("NATIVE_FAILURE", "Unable to construct key event")
        }
        down.flags = modifiers
        up.flags = []
        down.postToPid(pid_t(pid))
        up.postToPid(pid_t(pid))
    }

    public func postFocusedKey(_ chord: String, context: CommandContext) throws {
        try postKeyToTap(chord, context: context)
    }

    public func postGlobalKey(_ chord: String, context: CommandContext) throws {
        try postKeyToTap(chord, context: context)
    }

    private func postKeyToTap(_ chord: String, context: CommandContext) throws {
        try context.check()
        // The chord goes to the HID event tap so it reaches whatever
        // currently holds keyboard focus, like real hardware input.
        guard let (key, modifiers) = KeyChord.toCGEvent(chord) else {
            throw NativeFailure("INVALID_ARGUMENT", "Unrecognized key/modifier combination")
        }
        let source = CGEventSource(stateID: .privateState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else {
            throw NativeFailure("NATIVE_FAILURE", "Unable to construct key event")
        }
        down.flags = modifiers
        up.flags = []
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    public func postText(_ text: String, to pid: Int, context: CommandContext) throws {
        try context.check()
        // Post each Unicode scalar as a keyboard event so the clipboard is
        // untouched (no hidden paste). Bounded by the command deadline.
        // Pace each scalar: a burst of back-to-back keyDown/keyUp pairs posted
        // to a pid can be reordered or dropped while the target's field is
        // still activating. ~4ms between events is enough for the receiver to
        // keep up and stays well within any command deadline for sane input.
        let source = CGEventSource(stateID: .privateState)
        for scalar in text.unicodeScalars {
            try context.check()
            var utf16 = Array(String(scalar).utf16)
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) else {
                throw NativeFailure("NATIVE_FAILURE", "Unable to construct text event")
            }
            event.flags = []
            event.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            event.postToPid(pid_t(pid))
            guard let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { continue }
            up.flags = []
            up.postToPid(pid_t(pid))
            usleep(4_000)
        }
    }

    /// Post Unicode text to the HID event tap so it lands on whatever holds
    /// keyboard focus — including panels and helper-hosted UI that does not
    /// share the target's event queue. Same per-scalar pacing as `postText`.
    public func postFocusedText(_ text: String, context: CommandContext) throws {
        try context.check()
        let source = CGEventSource(stateID: .privateState)
        for scalar in text.unicodeScalars {
            try context.check()
            var utf16 = Array(String(scalar).utf16)
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) else {
                throw NativeFailure("NATIVE_FAILURE", "Unable to construct text event")
            }
            event.flags = []
            event.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            event.post(tap: .cghidEventTap)
            guard let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { continue }
            up.flags = []
            up.post(tap: .cghidEventTap)
            usleep(4_000)
        }
    }

    public func scroll(_ direction: String, amount: Int, at element: LiveAXElement?, point: CGPoint?, context: CommandContext) throws {
        try context.check()
        if let element {
            // scroll-to-ref: bring the element into view.
            guard let raw = element.rawValue else {
                throw NativeFailure("STALE_SNAPSHOT", "Live accessibility reference is unavailable")
            }
            try prepareLiveAXMessaging(raw, context: context)
            let status = AXUIElementPerformAction(raw, "AXScrollToVisible" as CFString)
            guard status == .success || status == .actionUnsupported else { throw liveInputFailure(status) }
            return
        }
        // directional: a phased pixel-delta scroll gesture delivered at a point.
        //
        // A single naked `.line` tick posted with `scrollWheelEvent2Source: nil`
        // is under-specified: with no event source and no scroll phase the window
        // server guesses whether it's a legacy wheel or a trackpad gesture, so
        // (a) Chromium drops most of them and (b) under "natural scrolling" the
        // sign is reinterpreted and the direction intermittently inverts.
        //
        // A continuous `.pixel` gesture with an explicit hidSystemState source and
        // a Began→Changed→Ended phase is unambiguous: the delta is applied to the
        // scroll position directly (positive wheel1 = up, positive wheel2 = left)
        // and is NOT subject to natural-scroll sign re-inversion. ~24 px per
        // "line" matches AppKit's standard scroll increment.
        let (v1, v2): (Int32, Int32)
        let delta = Int32(amount) * 24
        switch direction {
        case "up": v1 = delta; v2 = 0
        case "down": v1 = -delta; v2 = 0
        case "left": v1 = 0; v2 = delta
        case "right": v1 = 0; v2 = -delta
        default: throw NativeFailure("INVALID_ARGUMENT", "Invalid scroll direction")
        }
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw NativeFailure("NATIVE_FAILURE", "Unable to construct scroll event source")
        }
        func makeEvent(_ wheel1: Int32, _ wheel2: Int32, _ phase: CGScrollPhase) throws -> CGEvent {
            guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: wheel1, wheel2: wheel2, wheel3: 0) else {
                throw NativeFailure("NATIVE_FAILURE", "Unable to construct scroll event")
            }
            if let point { event.location = point }
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
            return event
        }
        try makeEvent(0, 0, .began).post(tap: .cghidEventTap)
        usleep(12_000)
        try context.check()
        try makeEvent(v1, v2, .changed).post(tap: .cghidEventTap)
        usleep(12_000)
        try makeEvent(0, 0, .ended).post(tap: .cghidEventTap)
    }

    public func click(at point: CGPoint, button: String, count: Int, context: CommandContext) throws {
        try context.check()
        let (cgButton, downType, upType): (CGMouseButton, CGEventType, CGEventType)
        switch button {
        case "left": cgButton = .left; downType = .leftMouseDown; upType = .leftMouseUp
        case "right": cgButton = .right; downType = .rightMouseDown; upType = .rightMouseUp
        case "middle": cgButton = .center; downType = .otherMouseDown; upType = .otherMouseUp
        default: throw NativeFailure("INVALID_ARGUMENT", "Unsupported button")
        }
        // Move the pointer to the point first — controls need the cursor to
        // arrive (and the window to see a hover) before a click registers,
        // especially when the target window isn't key.
        if let arrive = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) {
            arrive.post(tap: .cghidEventTap)
        }
        for click in 1...count {
            try context.check()
            guard let down = CGEvent(mouseEventSource: nil, mouseType: downType, mouseCursorPosition: point, mouseButton: cgButton),
                  let up = CGEvent(mouseEventSource: nil, mouseType: upType, mouseCursorPosition: point, mouseButton: cgButton) else {
                throw NativeFailure("NATIVE_FAILURE", "Unable to construct mouse event")
            }
            down.setIntegerValueField(.mouseEventClickState, value: Int64(click))
            up.setIntegerValueField(.mouseEventClickState, value: Int64(click))
            down.post(tap: .cghidEventTap)
            // A real press has a down→up interval; a 0ms synthetic click is
            // dropped by many AppKit controls. 50ms is within any deadline.
            usleep(50_000)
            up.post(tap: .cghidEventTap)
        }
    }

    public func move(to point: CGPoint, context: CommandContext) throws {
        try context.check()
        guard let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) else {
            throw NativeFailure("NATIVE_FAILURE", "Unable to construct move event")
        }
        event.post(tap: .cghidEventTap)
    }

    public func drag(from start: CGPoint, to end: CGPoint, context: CommandContext) throws {
        try context.check()
        guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: start, mouseButton: .left) else {
            throw NativeFailure("NATIVE_FAILURE", "Unable to construct drag event")
        }
        down.post(tap: .cghidEventTap)
        var didRelease = false
        defer {
            if !didRelease {
                if let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: end, mouseButton: .left) {
                    up.post(tap: .cghidEventTap)
                }
            }
        }
        // Bounded straight-line interpolation, checking the deadline between steps.
        let steps = 20
        for i in 1...steps {
            try context.check()
            let t = CGFloat(i) / CGFloat(steps)
            let point = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
            guard let move = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: point, mouseButton: .left) else { continue }
            move.post(tap: .cghidEventTap)
        }
        guard let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: end, mouseButton: .left) else {
            throw NativeFailure("NATIVE_FAILURE", "Unable to release drag")
        }
        up.post(tap: .cghidEventTap)
        didRelease = true
    }

    public func releaseHeldInputs() throws {
        // If a drag was interrupted the defer in `drag` already released the
        // button; this is the belt-and-suspenders path for held modifiers.
    }
}

private func liveInputFailure(_ status: AXError) -> NativeFailure {
    if status == .apiDisabled {
        return NativeFailure("PERMISSION_DENIED", "Accessibility access is unavailable")
    }
    if status == .actionUnsupported {
        return NativeFailure("UNSUPPORTED_ACTION", "The target does not support that action")
    }
    return NativeFailure("NATIVE_FAILURE", "Native input failed")
}

extension KeyChord {
    /// Map an allowlisted chord to a CGEvent virtual key + modifier flags.
    /// Returns nil for anything outside the allowlist (defense in depth; the
    /// caller also validates).
    static func toCGEvent(_ chord: String) -> (CGKeyCode, CGEventFlags)? {
        let parts = chord.lowercased().split(separator: "+").map(String.init)
        var flags = CGEventFlags()
        var key: String?
        for part in parts {
            switch part {
            case "cmd", "command": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "opt", "option", "alt": flags.insert(.maskAlternate)
            case "ctrl", "control": flags.insert(.maskControl)
            case "fn": flags.insert(.maskSecondaryFn)
            default: key = part
            }
        }
        guard let key else { return nil }
        guard let code = virtualKeyCode(key) else { return nil }
        return (code, flags)
    }

    private static func virtualKeyCode(_ name: String) -> CGKeyCode? {
        // A pragmatic subset covering letters/digits/common keys. Returns nil
        // for names outside the table so unsupported input fails closed.
        let table: [String: CGKeyCode] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
            "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19,
            "3": 20, "4": 21, "6": 22, "5": 23, "equal": 24, "9": 25, "7": 26, "minus": 27,
            "8": 28, "0": 29, "rightbracket": 30, "o": 31, "u": 32, "leftbracket": 33, "i": 34,
            "p": 35, "return": 36, "enter": 36, "l": 37, "j": 38, "quote": 39, "k": 40,
            "semicolon": 41, "backslash": 42, "comma": 43, "slash": 44, "n": 45, "m": 46,
            "period": 47, "tab": 48, "space": 49, "grave": 50, "delete": 51, "backspace": 51,
            "escape": 53, "esc": 53,
            "f5": 96, "f6": 97, "f7": 98, "f3": 99, "f8": 100, "f9": 101, "f11": 103,
            "f10": 109, "f12": 111, "home": 115, "pageup": 116, "delete_forward": 117,
            "f4": 118, "end": 119, "f2": 120, "pagedown": 121, "f1": 122,
            "left": 123, "right": 124, "down": 125, "up": 126,
        ]
        return table[name]
    }
}
