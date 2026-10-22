import ApplicationServices
import KeyboardShortcuts
import ServiceManagement
import SwiftUI

enum Brand {
    static let background = Color(red: 0.067, green: 0.067, blue: 0.075)
    static let lime = Color(red: 0.80, green: 0.96, blue: 0.40)
    static let ink = Color(red: 0.08, green: 0.10, blue: 0.03)
    static let text = Color.white.opacity(0.94)
    static let secondary = Color.white.opacity(0.58)
    static let hairline = Color.white.opacity(0.08)
    static let well = Color.white.opacity(0.04)
}

/// The first-launch window: how Prompter works, setup, and where it lives.
@MainActor
final class OnboardingController {
    static let seenKey = "hasSeenOnboarding"
    private var window: NSWindow?

    func show(state: AppState) {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 540),
                             styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.backgroundColor = NSColor(Brand.background)
            w.appearance = NSAppearance(named: .darkAqua)
            w.title = "Welcome to Prompter"
            w.contentView = NSHostingView(rootView: OnboardingView { [weak self] in
                UserDefaults.standard.set(true, forKey: Self.seenKey)
                self?.window?.close()
            }.environmentObject(state))
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct OnboardingView: View {
    let onFinish: () -> Void
    @State private var page = 0
    private let pages = 3

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch page {
                case 0: HowItWorksPage()
                case 1: SetupPage()
                default: MenuBarPage()
                }
            }
            .id(page)
            .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: 20)), removal: .opacity))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 48)
            .padding(.top, 56)

            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    ForEach(0..<pages, id: \.self) { i in
                        Capsule().fill(i == page ? Brand.lime : Color.white.opacity(0.18))
                            .frame(width: i == page ? 18 : 6, height: 6)
                    }
                }
                .accessibilityLabel("Step \(page + 1) of \(pages)")
                Spacer()
                if page > 0 {
                    Button("Back") { go(page - 1) }.buttonStyle(BrandButtonStyle(primary: false))
                }
                Button(page == pages - 1 ? "Start using Prompter" : "Continue") {
                    page == pages - 1 ? onFinish() : go(page + 1)
                }
                .buttonStyle(BrandButtonStyle(primary: true))
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 48)
            .padding(.vertical, 20)
            .overlay(alignment: .top) { Rectangle().fill(Brand.hairline).frame(height: 1) }
        }
        .frame(width: 760, height: 540)
        .background(Brand.background)
        .foregroundStyle(Brand.text)
        .environment(\.colorScheme, .dark)
    }

    private func go(_ p: Int) {
        withAnimation(.timingCurve(0.215, 0.61, 0.355, 1, duration: 0.35)) { page = p }
    }
}

// MARK: - Pages

private struct PageHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 30, weight: .semibold)).tracking(-0.6)
            Text(subtitle).font(.system(size: 14)).foregroundStyle(Brand.secondary)
                .lineSpacing(3).frame(maxWidth: 560, alignment: .leading).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct HowItWorksPage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            PageHeader(title: "Write it rough. Send it clear.",
                       subtitle: "Press a shortcut in any text box and Prompter rewrites what you typed into a clear prompt, in place. It runs on the Claude Code or Codex plan you already have.")
            DemoView()
            HStack(alignment: .top, spacing: 0) {
                mode("Polish", shortcut: .polish, "Fixes wording and structure. Adds nothing you didn't say.")
                    .padding(.trailing, 24)
                Rectangle().fill(Brand.hairline).frame(width: 1)
                mode("Expand", shortcut: .expand, "Adds goal, context and output format, with [blanks] for details only you know.")
                    .padding(.leading, 24)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func mode(_ name: String, shortcut: KeyboardShortcuts.Name, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(name).font(.system(size: 14, weight: .semibold))
                Keycap(text: KeyboardShortcuts.getShortcut(for: shortcut)?.description ?? "Set in step 2", lit: false)
            }
            Text(detail).font(.system(size: 13)).foregroundStyle(Brand.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SetupPage: View {
    @EnvironmentObject var state: AppState
    @AppStorage("provider") private var provider = ProviderKind.claude.rawValue
    @State private var status = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            PageHeader(title: "Set up in under a minute.",
                       subtitle: "Prompter needs three things before your first rewrite.")
            VStack(spacing: 0) {
                row(1, "Allow Accessibility",
                    "Lets Prompter read and replace the text you're typing. Only the text you rewrite is sent, to Claude or ChatGPT.") {
                    if state.isTrusted {
                        Label("Allowed", systemImage: "checkmark.circle.fill").font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Brand.lime)
                    } else {
                        Button("Open Settings") { state.requestAccessibility() }.buttonStyle(BrandButtonStyle(primary: false))
                    }
                }
                row(2, "Pick your shortcuts", "Choose keys that don't clash with the apps you use.") {
                    Grid(alignment: .trailing, horizontalSpacing: 10, verticalSpacing: 8) {
                        GridRow {
                            Text("Polish").font(.system(size: 13)).foregroundStyle(Brand.secondary)
                            KeyboardShortcuts.Recorder(for: .polish)
                        }
                        GridRow {
                            Text("Expand").font(.system(size: 13)).foregroundStyle(Brand.secondary)
                            KeyboardShortcuts.Recorder(for: .expand)
                        }
                    }
                }
                row(3, "Choose a model", status.isEmpty ? "Uses the claude or codex command you're already logged in to." : status) {
                    HStack(spacing: 2) {
                        ForEach(ProviderKind.allCases, id: \.self) { kind in
                            Button(kind.displayName) { provider = kind.rawValue }
                                .buttonStyle(SegmentStyle(selected: provider == kind.rawValue))
                        }
                    }
                    .padding(2)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
                }
            }
        }
        .task(id: provider) {
            status = "Checking…"
            status = await state.checkSetup()
            _ = try? await state.provider()
        }
    }

    private func row(_ n: Int, _ title: String, _ detail: String, @ViewBuilder trailing: () -> some View) -> some View {
        HStack(alignment: .center, spacing: 16) {
            Text("\(n)").font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(Brand.lime)
                .frame(width: 26, height: 26).background(Brand.lime.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail).font(.system(size: 13)).foregroundStyle(Brand.secondary).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing()
        }
        .padding(.vertical, 16)
        .overlay(alignment: .top) { Rectangle().fill(Brand.hairline).frame(height: 1) }
    }
}

private struct MenuBarPage: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            PageHeader(title: "Prompter lives in your menu bar.",
                       subtitle: "There's no Dock icon. Use your shortcuts in any app, or click the wand in the menu bar for settings.")
            MenuBarIllustration()
            Toggle("Open Prompter when you log in", isOn: $launchAtLogin)
                .toggleStyle(.switch).tint(Brand.lime).font(.system(size: 13))
                .onChange(of: launchAtLogin) { _, on in
                    try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                    launchAtLogin = SMAppService.mainApp.status == .enabled
                }
        }
    }
}

// MARK: - Demo

/// A mock chat box that types a rough draft, takes the shortcut, and swaps in the polished prompt.
private struct DemoView: View {
    private enum Step { case typing, pressed, working, done }
    private static let draft = "can u look at why the login page keeps looping back after i sign in, i think its the cookie thing"
    private static let polished = "The login page redirects back to itself after I sign in. I suspect the session cookie. Find the cause, explain it, and suggest a fix."

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var typed = 0
    @State private var step = Step.typing

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 14) {
                Group {
                    if step == .done {
                        Text(Self.polished)
                    } else {
                        Text(Self.draft.prefix(typed)) + Text(step == .typing ? "|" : "").foregroundColor(Brand.lime)
                    }
                }
                .font(.system(size: 15))
                .foregroundStyle(step == .working ? Brand.text.opacity(0.4) : Brand.text)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
                .transition(.opacity)

                HStack {
                    Text("Message ChatGPT").font(.system(size: 12)).foregroundStyle(Color.white.opacity(0.3))
                    Spacer()
                    Keycap(text: KeyboardShortcuts.getShortcut(for: .polish)?.description ?? "⌃⌥P", lit: step == .pressed || step == .working)
                }
            }
            .padding(16)
            .background(Brand.well, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.08)))

            HStack(spacing: 8) {
                switch step {
                case .working:
                    ProgressView().controlSize(.small)
                    Text("Polishing…")
                case .done:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Brand.lime)
                    Text("Replaced · ⌘Z to undo")
                default:
                    Text(" ")
                }
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Brand.secondary)
            .frame(height: 16)
        }
        .task { await loop() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Example: a rough draft becomes: \(Self.polished)")
    }

    private func loop() async {
        if reduceMotion { step = .done; return }
        while !Task.isCancelled {
            step = .typing
            typed = 0
            while typed < Self.draft.count {
                typed += 1
                try? await Task.sleep(for: .milliseconds(28))
            }
            try? await Task.sleep(for: .milliseconds(600))
            withAnimation(.easeOut(duration: 0.15)) { step = .pressed }
            try? await Task.sleep(for: .milliseconds(350))
            withAnimation(.easeOut(duration: 0.2)) { step = .working }
            try? await Task.sleep(for: .milliseconds(1400))
            withAnimation(.easeOut(duration: 0.35)) { step = .done }
            try? await Task.sleep(for: .seconds(4))
        }
    }
}

private struct MenuBarIllustration: View {
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 18) {
                Spacer()
                ZStack {
                    RoundedRectangle(cornerRadius: 5).fill(Brand.lime.opacity(0.22))
                    RoundedRectangle(cornerRadius: 5).stroke(Brand.lime.opacity(pulse ? 0 : 0.8), lineWidth: 1.5)
                        .scaleEffect(pulse ? 1.5 : 1)
                    Image(systemName: "wand.and.stars").font(.system(size: 13, weight: .medium)).foregroundStyle(Brand.lime)
                }
                .frame(width: 30, height: 22)
                Image(systemName: "wifi")
                Image(systemName: "battery.75percent")
                Text("Mon 9:41").font(.system(size: 13, weight: .medium))
            }
            .font(.system(size: 13))
            .foregroundStyle(Color.white.opacity(0.85))
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(Color.white.opacity(0.06))

            VStack(alignment: .leading, spacing: 0) {
                menuItem("Polish focused text", KeyboardShortcuts.getShortcut(for: .polish)?.description)
                menuItem("Expand focused text", KeyboardShortcuts.getShortcut(for: .expand)?.description)
                Rectangle().fill(Brand.hairline).frame(height: 1).padding(.vertical, 4)
                menuItem("Settings…", "⌘,")
                menuItem("Quit Prompter", "⌘Q")
            }
            .padding(6)
            .frame(width: 250)
            .background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.1)))
            .padding(.trailing, 96)
        }
        .padding(.bottom, 18)
        .background(Brand.well, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.08)))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { pulse = true }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("The Prompter wand icon in the menu bar, next to Wi-Fi and the clock.")
    }

    private func menuItem(_ title: String, _ shortcut: String?) -> some View {
        HStack {
            Text(title)
            Spacer()
            if let shortcut { Text(shortcut).foregroundStyle(Color.white.opacity(0.4)) }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}

// MARK: - Controls

private struct Keycap: View {
    let text: String
    let lit: Bool

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(lit ? Brand.ink : Color.white.opacity(0.75))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(lit ? Brand.lime : Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.white.opacity(lit ? 0 : 0.1)))
            .scaleEffect(lit ? 0.96 : 1)
    }
}

private struct SegmentStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(selected ? Brand.ink : Color.white.opacity(0.7))
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(selected ? Brand.lime : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
    }
}

struct BrandButtonStyle: ButtonStyle {
    let primary: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(primary ? Brand.ink : Color.white.opacity(0.85))
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background(primary ? Brand.lime : Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .contentShape(Rectangle())
    }
}
