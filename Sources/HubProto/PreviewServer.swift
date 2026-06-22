import Foundation

/// Avvio Preview locale stile UNVRS Code: porte dedicate per progetto, dev server +
/// proxy (toglie X-Frame-Options/CSP per l'embedding), poi si carica localhost:<proxy>.
enum PreviewServer {
    private static let devBase = 5800
    private static let proxyBase = 6800
    private static let mapKey = "preview_ports_map"   // [projectId: [dev, proxy]]

    private static let node = firstExisting(["/opt/homebrew/bin/node", "/usr/local/bin/node"]) ?? "/usr/bin/env"
    private static let npm = firstExisting(["/opt/homebrew/bin/npm", "/usr/local/bin/npm"]) ?? "/usr/bin/env"

    enum PreviewError: LocalizedError {
        case noDevScript, installFailed(String), timeout
        var errorDescription: String? {
            switch self {
            case .noDevScript: return "Il progetto non ha uno script \"dev\" in package.json."
            case .installFailed(let m): return "npm install fallito.\n\(m)"
            case .timeout: return "Il dev server non è partito in tempo. Controlla i log in ~/Library/Logs o avvialo dal terminale CODE."
            }
        }
    }

    static func ports(for projectId: String) -> (dev: Int, proxy: Int) {
        var map = (UserDefaults.standard.dictionary(forKey: mapKey) as? [String: [Int]]) ?? [:]
        if let e = map[projectId], e.count == 2 { return (e[0], e[1]) }
        let usedDev = Set(map.values.compactMap { $0.first })
        var n = 0
        while usedDev.contains(devBase + n) { n += 1 }
        let dev = devBase + n, proxy = proxyBase + n
        map[projectId] = [dev, proxy]
        UserDefaults.standard.set(map, forKey: mapKey)
        return (dev, proxy)
    }

    /// Avvia (se serve) deps + dev server + proxy e ritorna l'URL del proxy pronto.
    static func start(projectId: String, dir: String, onStatus: @escaping (String) -> Void) async throws -> URL {
        guard hasDevScript(dir: dir) else { throw PreviewError.noDevScript }
        let (dev, proxy) = ports(for: projectId)

        // dipendenze: se manca node_modules, npm install (può richiedere 1-2 min)
        if !FileManager.default.fileExists(atPath: dir + "/node_modules") {
            onStatus("Installazione dipendenze (npm install)… può richiedere 1-2 min")
            let (code, out) = try await runWait(npm, ["install"], cwd: dir)
            if code != 0 { throw PreviewError.installFailed(String(out.suffix(400))) }
        }

        if !isListening(dev) {
            onStatus("Avvio dev server…")
            spawn(npm, ["run", "dev", "--", "--port", "\(dev)", "--host", "127.0.0.1"],
                  cwd: dir, env: ["PORT": "\(dev)"], logName: "unvrs-hub-dev-\(dev)")
        }
        if !isListening(proxy) {
            spawn(node, [proxyScriptPath(), "\(proxy)", "\(dev)"], cwd: dir,
                  logName: "unvrs-hub-proxy-\(proxy)")
        }

        onStatus("Attendo il dev server…")
        let devURL = URL(string: "http://localhost:\(dev)")!
        for _ in 0..<120 {   // ~60s di attesa per il primo avvio
            if await responds(devURL) {
                return URL(string: "http://localhost:\(proxy)")!
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        throw PreviewError.timeout
    }

    // ── helper ──

    private static func hasDevScript(dir: String) -> Bool {
        let pkg = dir + "/package.json"
        guard let data = FileManager.default.contents(atPath: pkg),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scripts = json["scripts"] as? [String: Any] else { return false }
        return scripts["dev"] != nil
    }

    static func proxyScriptPath() -> String {
        if let res = Bundle.main.resourcePath {
            let bundled = res + "/preview-proxy.mjs"
            if FileManager.default.fileExists(atPath: bundled) { return bundled }
        }
        return NSHomeDirectory() + "/Developer/unvrs-hub-swift/scripts/preview-proxy.mjs"
    }

    private static func firstExisting(_ paths: [String]) -> String? {
        paths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func isListening(_ port: Int) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        p.arguments = ["-ti", "tcp:\(port)"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        do { try p.run(); p.waitUntilExit() } catch { return false }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func baseEnv() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        return env
    }

    private static func logURL(_ name: String) -> URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")
        return dir.appendingPathComponent("\(name).log")
    }

    /// Spawn detached, output su ~/Library/Logs/<logName>.log
    private static func spawn(_ exe: String, _ args: [String], cwd: String,
                             env extra: [String: String] = [:], logName: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        var env = baseEnv()
        for (k, v) in extra { env[k] = v }
        p.environment = env
        let log = logURL(logName)
        FileManager.default.createFile(atPath: log.path, contents: nil)
        if let fh = try? FileHandle(forWritingTo: log) {
            p.standardOutput = fh; p.standardError = fh
        } else {
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        }
        try? p.run()
    }

    /// Esegue e aspetta la fine (per npm install). Ritorna (exitCode, output).
    private static func runWait(_ exe: String, _ args: [String], cwd: String) async throws -> (Int32, String) {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: exe)
                p.arguments = args
                p.currentDirectoryURL = URL(fileURLWithPath: cwd)
                p.environment = baseEnv()
                let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
                do { try p.run() } catch { cont.resume(throwing: error); return }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                cont.resume(returning: (p.terminationStatus, String(data: data, encoding: .utf8) ?? ""))
            }
        }
    }

    private static func responds(_ url: URL) async -> Bool {
        var req = URLRequest(url: url)
        req.timeoutInterval = 1.2
        req.httpMethod = "HEAD"
        do { _ = try await URLSession.shared.data(for: req); return true }
        catch { return false }
    }
}
