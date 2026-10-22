import AppKit
import ApplicationServices

enum TextAccessError: LocalizedError, Equatable {
    case noPermission, noFocus, secureField, empty, needsSelection, focusChanged, textChanged

    var errorDescription: String? {
        switch self {
        case .noPermission: return "Prompter needs Accessibility permission: System Settings → Privacy & Security → Accessibility."
        case .noFocus: return "Click into a text field first."
        case .secureField: return "That's a password field, so Prompter won't read it."
        case .empty: return "There's no text in this field."
        case .needsSelection: return "Select the text you want to rewrite first."
        case .focusChanged: return "You switched apps, so nothing was replaced."
        case .textChanged: return "The text changed while rewriting, so nothing was replaced."
        }
    }
}

enum CaptureMode: Equatable {
    case selection   // AX selected text; paste replaces the live selection
    case wholeField  // AX value of an editable field; select all of it, then paste
    case copied      // AX exposed nothing; the user's selection was copied with ⌘C
}

enum ReplaceOutcome: Equatable { case replaced, copiedToClipboard }

struct CapturedText {
    let pid: pid_t
    let appName: String
    let isTerminal: Bool
    let element: AXUIElement?
    let mode: CaptureMode
    let text: String
}

enum TextAccess {
    // Terminal "selections" are screen text, not the input line, so pasting there would append, not replace.
    static let terminalBundleIDs: Set<String> = ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty",
                                                 "dev.warp.Warp-Stable", "com.github.wez.wezterm", "org.alacritty",
                                                 "net.kovidgoyal.kitty"]
    private static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]

    enum Decision: Equatable { case selection, wholeField, copySelection, refuse(TextAccessError) }

    /// Never selects-all blindly: whole-field capture only when AX confirms an editable text element.
    static func decide(role: String?, subrole: String?, selected: String?, value: String?, isTerminal: Bool) -> Decision {
        if role == "AXSecureTextField" || subrole == "AXSecureTextField" { return .refuse(.secureField) }
        if let s = selected, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .selection }
        if isTerminal { return .copySelection }
        if let role, textRoles.contains(role) {
            if let v = value, !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .wholeField }
            return .refuse(.empty)
        }
        return .copySelection
    }

    static func shouldRestoreClipboard(currentChangeCount: Int, writtenChangeCount: Int) -> Bool {
        currentChangeCount == writtenChangeCount // the user copied something meanwhile otherwise; keep theirs
    }

    // MARK: Capture

    @MainActor
    static func capture() async throws -> CapturedText {
        guard AXIsProcessTrusted() else { throw TextAccessError.noPermission }
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() else { throw TextAccessError.noFocus }
        let pid = app.processIdentifier
        let isTerminal = terminalBundleIDs.contains(app.bundleIdentifier ?? "")
        let element = focusedElement(pid: pid)
        let role = element.flatMap { string($0, kAXRoleAttribute) }
        let decision = decide(role: role, subrole: element.flatMap { string($0, kAXSubroleAttribute) },
                              selected: element.flatMap { string($0, kAXSelectedTextAttribute) },
                              value: element.flatMap { string($0, kAXValueAttribute) }, isTerminal: isTerminal)
        let name = app.localizedName ?? "an app"

        switch decision {
        case .refuse(let error):
            throw error
        case .selection:
            return CapturedText(pid: pid, appName: name, isTerminal: isTerminal, element: element, mode: .selection,
                                text: string(element!, kAXSelectedTextAttribute)!)
        case .wholeField:
            return CapturedText(pid: pid, appName: name, isTerminal: isTerminal, element: element, mode: .wholeField,
                                text: string(element!, kAXValueAttribute)!)
        case .copySelection:
            guard let text = await copySelection() else { throw TextAccessError.needsSelection }
            return CapturedText(pid: pid, appName: name, isTerminal: isTerminal, element: nil, mode: .copied, text: text)
        }
    }

    // MARK: Replace

    @MainActor
    static func replace(_ target: CapturedText, with newText: String) async throws -> ReplaceOutcome {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid else { throw TextAccessError.focusChanged }
        if target.isTerminal {
            setClipboard(newText)
            return .copiedToClipboard
        }
        if let element = target.element {
            let current = string(element, target.mode == .selection ? kAXSelectedTextAttribute : kAXValueAttribute)
            guard current == target.text else { throw TextAccessError.textChanged }
            if target.mode == .wholeField, !selectAll(element) {
                await waitForModifierRelease()
                postKey(0x00) // ⌘A: AX range selection isn't supported here, and AX confirmed this is an editable field
            }
        }
        await paste(newText)
        return .replaced
    }

    // MARK: Accessibility helpers

    private static func focusedElement(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        // Chromium/Electron apps (Slack, Cursor, VS Code, Chrome) only build their AX tree when asked.
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func selectAll(_ element: AXUIElement) -> Bool {
        guard let value = string(element, kAXValueAttribute) else { return false }
        var range = CFRange(location: 0, length: (value as NSString).length)
        guard let axRange = AXValueCreate(.cfRange, &range) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, axRange) == .success
    }

    // MARK: Clipboard and keystrokes

    private typealias Snapshot = [[(NSPasteboard.PasteboardType, Data)]]

    private static func snapshot(_ pb: NSPasteboard) -> Snapshot {
        (pb.pasteboardItems ?? []).map { item in item.types.compactMap { t in item.data(forType: t).map { (t, $0) } } }
    }

    private static func restore(_ snap: Snapshot, to pb: NSPasteboard) {
        pb.clearContents()
        pb.writeObjects(snap.map { pairs in
            let item = NSPasteboardItem()
            for (type, data) in pairs { item.setData(data, forType: type) }
            return item
        })
    }

    private static func setClipboard(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
    }

    @MainActor
    private static func copySelection() async -> String? {
        await waitForModifierRelease()
        let pb = NSPasteboard.general
        let saved = snapshot(pb), before = pb.changeCount
        postKey(0x08) // ⌘C
        for _ in 0..<15 where pb.changeCount == before { try? await Task.sleep(nanoseconds: 20_000_000) }
        guard pb.changeCount != before else { return nil }
        let text = pb.string(forType: .string)
        restore(saved, to: pb)
        return text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? text : nil
    }

    @MainActor
    private static func paste(_ s: String) async {
        await waitForModifierRelease()
        let pb = NSPasteboard.general
        let saved = snapshot(pb)
        pb.clearContents()
        pb.setString(s, forType: .string)
        pb.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType")) // clipboard managers skip it
        let written = pb.changeCount
        postKey(0x09) // ⌘V
        try? await Task.sleep(nanoseconds: 400_000_000) // let the target app read the pasteboard first
        if shouldRestoreClipboard(currentChangeCount: pb.changeCount, writtenChangeCount: written) { restore(saved, to: pb) }
    }

    /// The hotkey's own modifiers would otherwise combine with the synthetic ⌘C/⌘V.
    private static func waitForModifierRelease() async {
        for _ in 0..<30 where !NSEvent.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private static func postKey(_ keyCode: CGKeyCode) {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down)
            e?.flags = .maskCommand
            e?.post(tap: .cgAnnotatedSessionEventTap)
        }
    }
}
