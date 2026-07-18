import Foundation

/// Avvio Preview locale stile UNVRS Code: porte dedicate per progetto, dev server +
/// proxy (toglie X-Frame-Options/CSP per l'embedding), poi si carica localhost:<proxy>.
enum PreviewServer {
    private static let devBase = 5800
    private static let proxyBase = 6800
    private static let mapKey = "preview_ports_map"   // [projectId: [dev, proxy]]

    private static let node = firstExisting(["/opt/homebrew/bin/node", "/usr/local/bin/node"]) ?? "/usr/bin/env"
    private static let npm = firstExisting(["/opt/homebrew/bin/npm", "/usr/local/bin/npm"]) ?? "/usr/bin/env"
    private static let python = firstExisting(["/usr/bin/python3", "/opt/homebrew/bin/python3"]) ?? "/usr/bin/python3"

    enum PreviewError: LocalizedError {
        case noDevScript, installFailed(String), timeout(String)
        var errorDescription: String? {
            switch self {
            case .noDevScript: return "Nessuna anteprima: manca uno script \"dev\" in package.json e non c'è un index.html (sito statico)."
            case .installFailed(let m): return "npm install fallito.\n\(m)"
            case .timeout(let log):
                let base = "Il dev server non è partito in tempo."
                return log.isEmpty ? base + " Controlla i log in ~/Library/Logs o avvialo dal terminale CODE."
                                   : base + "\n\n\(log)"
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
        let hasDev = hasDevScript(dir: dir)
        let isStatic = !hasDev && FileManager.default.fileExists(atPath: dir + "/index.html")
        guard hasDev || isStatic else { throw PreviewError.noDevScript }
        let (dev, proxy) = ports(for: projectId)

        // Un dev server avviato a mano (terminale CODE, `npm run dev`) tiene il lock della
        // cartella: Next si rifiuta di avviarne un secondo e il nostro morirebbe all'istante.
        // In quel caso ci agganciamo a quello che sta già girando.
        let externalDev = runningDevPort(dir: dir)
        let devPort = externalDev ?? dev
        let logName = hasDev ? "unvrs-hub-dev-\(dev)" : "unvrs-hub-static-\(dev)"

        if let externalDev {
            onStatus("Dev server già attivo su :\(externalDev)")
        } else {
            // dipendenze: solo per progetti node con script dev; se manca node_modules, npm install
            if hasDev, !FileManager.default.fileExists(atPath: dir + "/node_modules") {
                onStatus("Installazione dipendenze (npm install)… può richiedere 1-2 min")
                let (code, out) = try await runWait(npm, ["install"], cwd: dir)
                if code != 0 { throw PreviewError.installFailed(String(out.suffix(400))) }
            }

            if !isListening(dev) {
                if hasDev {
                    onStatus("Avvio dev server…")
                    // niente --host: Next usa --hostname, Vite usa --host; entrambi ascoltano su localhost di default
                    spawn(npm, ["run", "dev", "--", "--port", "\(dev)"],
                          cwd: dir, env: ["PORT": "\(dev)", "HOSTNAME": "127.0.0.1"], logName: logName)
                } else {
                    // sito statico (HTML/CSS): server file locale, nessuna dipendenza richiesta
                    onStatus("Avvio server statico…")
                    spawn(python, ["-m", "http.server", "\(dev)", "--bind", "127.0.0.1"],
                          cwd: dir, logName: logName)
                }
                rememberPort(dev)
            }
        }

        // Il proxy va rifatto se punta a una porta diversa da quella effettiva (es. prima
        // puntava al nostro dev server, ora al dev server esterno).
        if !isListening(proxy) || proxyTarget(proxy) != devPort {
            if isListening(proxy) { killPort(proxy) }
            spawn(node, [proxyScriptPath(), "\(proxy)", "\(devPort)"], cwd: dir,
                  logName: "unvrs-hub-proxy-\(proxy)")
            setProxyTarget(proxy, devPort)
            rememberPort(proxy)
        }

        onStatus("Attendo il dev server…")
        let devURL = URL(string: "http://localhost:\(devPort)")!
        for _ in 0..<120 {   // ~60s di attesa per il primo avvio
            if await responds(devURL) {
                return URL(string: "http://localhost:\(proxy)")!
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        throw PreviewError.timeout(logTail(logName))
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
        // fallback: sorgente nel repo
        return NSHomeDirectory() + "/Developer/gz-brain/scripts/preview-proxy.mjs"
    }

    // ── cleanup: i processi spawnati in questa sessione vengono chiusi all'uscita dell'app ──
    private static let stateLock = NSLock()
    private static var startedPorts = Set<Int>()
    /// proxyPort -> devPort a cui l'abbiamo puntato. Un proxy rimasto da una sessione
    /// precedente non è in mappa: target sconosciuto → viene rifatto.
    private static var proxyTargets: [Int: Int] = [:]

    private static func rememberPort(_ port: Int) {
        stateLock.lock(); startedPorts.insert(port); stateLock.unlock()
    }

    private static func proxyTarget(_ proxy: Int) -> Int? {
        stateLock.lock(); defer { stateLock.unlock() }
        return proxyTargets[proxy]
    }

    private static func setProxyTarget(_ proxy: Int, _ dev: Int) {
        stateLock.lock(); proxyTargets[proxy] = dev; stateLock.unlock()
    }

    /// Termina dev server e proxy avviati in questa sessione (via porta: npm spawna figli
    /// che un semplice terminate() sul padre non chiuderebbe).
    static func shutdown() {
        stateLock.lock(); let ports = startedPorts; startedPorts.removeAll(); stateLock.unlock()
        for port in ports {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", "/usr/sbin/lsof -ti tcp:\(port) | xargs kill 2>/dev/null"]
            try? p.run(); p.waitUntilExit()
        }
    }

    private static func firstExisting(_ paths: [String]) -> String? {
        paths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Porta di un dev server già in ascolto per QUESTA cartella, avviato fuori dall'app
    /// (terminale CODE, `npm run dev`). Next ≥15 scrive `.next/dev/lock` con pid e porta;
    /// il lock resta anche dopo un crash, quindi verifichiamo che il processo sia vivo e
    /// che la porta risponda davvero. Il lock è per-progetto: nessun rischio di agganciare
    /// il dev server di un altro progetto.
    private static func runningDevPort(dir: String) -> Int? {
        let lock = dir + "/.next/dev/lock"
        guard let data = FileManager.default.contents(atPath: lock),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let port = json["port"] as? Int,
              let pid = json["pid"] as? Int32,
              kill(pid, 0) == 0,               // processo ancora vivo
              isListening(port)
        else { return nil }
        return port
    }

    /// Ultime righe del log di avvio, per dire *perché* il dev server non è partito
    /// invece del solo "timeout" (es. "Another next dev server is already running").
    private static func logTail(_ name: String, lines: Int = 12) -> String {
        guard let text = try? String(contentsOf: logURL(name), encoding: .utf8) else { return "" }
        let tail = text.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines)
        return tail.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func killPort(_ port: Int) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "/usr/sbin/lsof -ti tcp:\(port) | xargs kill 2>/dev/null"]
        try? p.run(); p.waitUntilExit()
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
