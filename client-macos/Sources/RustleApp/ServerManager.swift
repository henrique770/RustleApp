import Foundation

/// Makes sure rustle-server is running: uses one that is already up, otherwise launches
/// scripts/run-server.sh next to the app bundle and waits for /health.
final class ServerManager {
    private let baseURL: URL
    private var process: Process?
    static let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/RustleApp-server.log")

    private let settingsPath: String

    init(baseURL: URL, settingsPath: String) {
        self.baseURL = baseURL
        self.settingsPath = settingsPath
    }

    static let requiredAPIVersion = 5

    private func health() async -> [String: Any]? {
        var req = URLRequest(url: baseURL.appendingPathComponent("health"))
        req.timeoutInterval = 1.5
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    func isHealthy() async -> Bool {
        await health()?["ok"] as? Bool == true
    }

    /// True when a server answers but predates the current app (e.g. left over from an older build).
    func isOutdated() async -> Bool {
        guard let h = await health() else { return false }
        return (h["api_version"] as? Int ?? 1) < Self.requiredAPIVersion
    }

    /// Returns nil on success, or a user-facing error message.
    func ensureRunning(timeout: TimeInterval = 600) async -> String? {
        if await isHealthy() { return nil }
        if process == nil || process?.isRunning == false {
            if let err = launch() { return err }
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await isHealthy() { return nil }
            if process?.isRunning == false {
                return "Servidor encerrou. Veja ~/Library/Logs/RustleApp-server.log"
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return "Servidor não respondeu a tempo"
    }

    func stop() { process?.terminate() }

    /// Stops whichever server is running (ours, or one started from a terminal) and starts a fresh one,
    /// so model, language and API-key changes take effect.
    func restart() async -> String? {
        if let p = process, p.isRunning {
            p.terminate()
            p.waitUntilExit()
        } else if await isHealthy() {
            var req = URLRequest(url: baseURL.appendingPathComponent("v1/shutdown"))
            req.httpMethod = "POST"
            req.timeoutInterval = 2
            _ = try? await URLSession.shared.data(for: req)
        }
        // Wait (up to ~5 s) for the old server to release the port.
        var tries = 0
        while tries < 20, await isHealthy() {
            try? await Task.sleep(nanoseconds: 250_000_000)
            tries += 1
        }
        process = nil
        return await ensureRunning()
    }

    private func launch() -> String? {
        let script = Self.scriptURL()
        guard FileManager.default.isExecutableFile(atPath: script.path) else {
            Log.info("server script not found at \(script.path)")
            return "run-server.sh não encontrado"
        }
        FileManager.default.createFile(atPath: Self.logURL.path, contents: nil)
        let out = try? FileHandle(forWritingTo: Self.logURL)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script.path]
        var env = ProcessInfo.processInfo.environment
        // A multilingual model by default (Portuguese and English); override with RUSTLE_WHISPER_MODEL.
        env["RUSTLE_WHISPER_MODEL"] = env["RUSTLE_WHISPER_MODEL"]
            ?? UserDefaults.standard.string(forKey: "whisperModel") ?? "small"
        env["RUSTLE_SETTINGS"] = settingsPath
        if let key = Keychain.readAPIKey(), env["ANTHROPIC_API_KEY"] == nil {
            env["ANTHROPIC_API_KEY"] = key
        }
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        p.environment = env
        p.standardOutput = out
        p.standardError = out
        do {
            try p.run()
            process = p
            Log.info("launched server: \(script.path) pid=\(p.processIdentifier)")
            return nil
        } catch {
            Log.info("failed to launch server: \(error)")
            return "Falha ao iniciar servidor: \(error.localizedDescription)"
        }
    }

    private static func scriptURL() -> URL {
        if let custom = UserDefaults.standard.string(forKey: "serverScript") {
            return URL(fileURLWithPath: custom)
        }
        // build/RustleApp.app -> ../../scripts/run-server.sh
        return Bundle.main.bundleURL
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/run-server.sh")
    }
}
