import Foundation

/// Finds the user's installed CLIs and checks their version and login. Blocking calls: run off the main thread.
enum CLILocator {
    static func resolve(_ kind: ProviderKind, override: String) -> URL? {
        let manual = override.trimmingCharacters(in: .whitespaces)
        if !manual.isEmpty {
            let path = (manual as NSString).expandingTildeInPath
            return FileManager.default.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
        // kind.binaryName is a fixed literal, never user text.
        return lastAbsolutePath(in: loginShell("command -v \(kind.binaryName)")).map(URL.init(fileURLWithPath:))
    }

    static func loginPATH() -> String? { lastAbsolutePath(in: loginShell("echo $PATH")) }

    /// Login shells can print MOTD or rc-file noise; the answer is the last line that starts with "/".
    static func lastAbsolutePath(in output: String) -> String? {
        output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.last { $0.hasPrefix("/") }
    }

    static func version(of binary: URL) -> String? {
        let (out, _) = run(binary, ["--version"])
        return out.split(whereSeparator: { $0 == " " || $0 == "\n" }).first(where: { $0.first?.isNumber == true }).map(String.init)
    }

    static func isAtLeast(_ version: String, _ minimum: String) -> Bool {
        let a = version.split(separator: ".").map { Int($0) ?? 0 }, b = minimum.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return true
    }

    static func isLoggedIn(_ kind: ProviderKind, binary: URL) -> Bool {
        run(binary, kind.statusArguments).status == 0
    }

    /// Resolves, version-checks and login-checks a provider. Returns the binary or a typed, user-facing error.
    static func check(_ kind: ProviderKind, override: String) -> Result<URL, ProviderError> {
        guard let binary = resolve(kind, override: override) else { return .failure(.notInstalled(kind)) }
        if let min = kind.minimumVersion, let found = version(of: binary), !isAtLeast(found, min) {
            return .failure(.outdated(kind, found: found, required: min))
        }
        return isLoggedIn(kind, binary: binary) ? .success(binary) : .failure(.notLoggedIn(kind))
    }

    private static func loginShell(_ script: String) -> String {
        run(URL(fileURLWithPath: "/bin/zsh"), ["-lc", script]).out
    }

    private static func run(_ binary: URL, _ args: [String]) -> (out: String, status: Int32) {
        let p = Process()
        p.executableURL = binary
        p.arguments = args
        if binary.path != "/bin/zsh", let path = cachedPATH { p.environment = ProcessInfo.processInfo.environment.merging(["PATH": path]) { $1 } }
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return ("", -1) }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (String(decoding: data, as: UTF8.self), p.terminationStatus)
    }

    static let cachedPATH: String? = loginPATH()
}
