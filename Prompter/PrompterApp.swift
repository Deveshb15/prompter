import ApplicationServices
import KeyboardShortcuts
import ServiceManagement
import SwiftUI

extension KeyboardShortcuts.Name {
    // No default bindings: the user picks keys that don't clash with their apps.
    static let polish = Self("polish")
    static let expand = Self("expand")
}

@main
struct PrompterApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra("Prompter", systemImage: "wand.and.stars") {
            MenuContent().environmentObject(state)
        }
        Settings {
            SettingsView().environmentObject(state)
        }
    }
}

private struct MenuContent: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if !state.isTrusted { Text("⚠︎ Needs Accessibility permission") }
        Button("Polish focused text") { state.coordinator.trigger(.polish) }
        Button("Expand focused text") { state.coordinator.trigger(.expand) }
        Divider()
        Button("Welcome Guide…") { state.showOnboarding() }
        Button("Settings…") {
            NSApp.activate(ignoringOtherApps: true) // menu-bar apps open Settings behind other windows otherwise
            openSettings()
        }
        Button("Quit Prompter") { NSApp.terminate(nil) }
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var isTrusted = AXIsProcessTrusted()
    private(set) var coordinator: Coordinator!
    private var overlay: OverlayController?
    private let onboarding = OnboardingController()
    private var cached: (key: String, provider: Provider)?

    init() {
        coordinator = Coordinator(
            capture: { try await TextAccess.capture() },
            replace: { try await TextAccess.replace($0, with: $1) },
            rewrite: { [weak self] message, mode, onDelta in
                guard let self else { throw ProviderError.cancelled }
                return try await self.provider().rewrite(message, mode: mode, onDelta: onDelta)
            },
            cancelRewrite: { [weak self] in await self?.cached?.provider.cancel() })
        guard NSClassFromString("XCTestCase") == nil else { return } // unit tests host the app; skip side effects

        overlay = OverlayController(coordinator: coordinator)
        KeyboardShortcuts.onKeyDown(for: .polish) { [weak self] in Task { @MainActor in self?.coordinator.trigger(.polish) } }
        KeyboardShortcuts.onKeyDown(for: .expand) { [weak self] in Task { @MainActor in self?.coordinator.trigger(.expand) } }
        if !UserDefaults.standard.bool(forKey: OnboardingController.seenKey) {
            showOnboarding() // its setup step asks for Accessibility
        } else if !isTrusted {
            requestAccessibility(openSettings: false)
        }
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                let trusted = AXIsProcessTrusted()
                if self?.isTrusted != trusted { self?.isTrusted = trusted }
            }
        }
        Task { _ = try? await provider() } // pre-warm so the first hotkey press is fast
    }

    func showOnboarding() { onboarding.show(state: self) }

    /// Shows macOS's prompt, which adds Prompter to the Accessibility list, and opens that list when the user asked.
    func requestAccessibility(openSettings: Bool = true) {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        guard openSettings else { return }
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    var selectedKind: ProviderKind {
        ProviderKind(rawValue: UserDefaults.standard.string(forKey: "provider") ?? "") ?? .claude
    }

    /// Returns the provider for the current settings, creating and pre-warming it if the settings changed.
    func provider() async throws -> Provider {
        let kind = selectedKind
        let override = UserDefaults.standard.string(forKey: kind.pathDefaultsKey) ?? ""
        let key = kind.rawValue + "|" + override
        if let cached, cached.key == key { return cached.provider }

        let binary = try await Task.detached { try CLILocator.check(kind, override: override).get() }.value
        let path = CLILocator.cachedPATH
        let provider: Provider = kind == .claude ? ClaudeCLIProvider(binary: binary, path: path)
                                                 : CodexAppServerProvider(binary: binary, path: path)
        await cached?.provider.cancel()
        cached = (key, provider)
        await provider.prewarm()
        return provider
    }

    /// Human-readable setup status for the Settings window.
    func checkSetup() async -> String {
        let kind = selectedKind
        let override = UserDefaults.standard.string(forKey: kind.pathDefaultsKey) ?? ""
        return await Task.detached {
            switch CLILocator.check(kind, override: override) {
            case .success(let binary):
                let version = CLILocator.version(of: binary) ?? "unknown version"
                return "✓ \(kind.displayName) \(version) is installed and logged in."
            case .failure(let error):
                return "✗ " + (error.errorDescription ?? "Not ready.")
            }
        }.value
    }
}

private struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @AppStorage("provider") private var provider = ProviderKind.claude.rawValue
    @AppStorage("claudePath") private var claudePath = ""
    @AppStorage("codexPath") private var codexPath = ""
    @State private var status = ""
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section("Shortcuts") {
                KeyboardShortcuts.Recorder("Polish (clean up, add nothing):", name: .polish)
                KeyboardShortcuts.Recorder("Expand (add structure and [blanks]):", name: .expand)
            }
            Section("Model") {
                Picker("Rewrite with", selection: $provider) {
                    Text("Claude Code: Haiku 5.5 (about 3 s)").tag(ProviderKind.claude.rawValue)
                    Text("Codex: GPT-5.6 Luna (about 4.5 s)").tag(ProviderKind.codex.rawValue)
                }
                TextField("claude path (blank = auto-detect)", text: $claudePath)
                TextField("codex path (blank = auto-detect)", text: $codexPath)
                HStack {
                    Button("Check setup") { Task { status = "Checking…"; status = await state.checkSetup() } }
                    Text(status).font(.callout).textSelection(.enabled)
                }
                Text("Prompter runs your own logged-in CLI. Each rewrite counts toward your Claude or ChatGPT plan's usage limits.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Permissions") {
                HStack {
                    Text(state.isTrusted ? "✓ Accessibility allowed" : "✗ Accessibility not allowed yet")
                    Spacer()
                    if !state.isTrusted {
                        Button("Open Accessibility Settings") { state.requestAccessibility() }
                    }
                }
            }
            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .onChange(of: provider) { Task { _ = try? await state.provider() } }
        .task { status = await state.checkSetup() }
    }
}
