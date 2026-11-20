import AppKit
import CoreMotion
import Foundation
import Network

setvbuf(stdout, nil, _IOLBF, 0)

let serverQ = DispatchQueue(label: "kopfkino.server", qos: .userInteractive)

private let logFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f
}()

func log(_ message: String) {
    print("[\(logFormatter.string(from: Date()))] \(message)")
}

func f2(_ v: Double) -> String { String(format: "%.2f", v) }

struct Options {
    var port: UInt16 = 8723
    var webDir: URL
    var configURL: URL
    var openBrowser = true

    var pageURL: URL { URL(string: "http://127.0.0.1:\(port)/")! }

    static func parse() -> Options {
        var webDir = Bundle.main.resourceURL!.appendingPathComponent("web")
        if !FileManager.default.fileExists(atPath: webDir.appendingPathComponent("index.html").path) {
            webDir = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("web")
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kopfkino")
        var configURL = support.appendingPathComponent("config.json")
        var port: UInt16 = 8723
        var openBrowser = true

        var it = CommandLine.arguments.dropFirst().makeIterator()
        while let arg = it.next() {
            switch arg {
            case "--no-browser": openBrowser = false
            case "--port": if let v = it.next(), let p = UInt16(v) { port = p }
            case "--web": if let v = it.next() { webDir = URL(fileURLWithPath: v) }
            case "--config": if let v = it.next() { configURL = URL(fileURLWithPath: v) }
            default: break
            }
        }
        return Options(port: port, webDir: webDir.standardizedFileURL, configURL: configURL, openBrowser: openBrowser)
    }
}

struct AxisMap: Codable {
    var source: String
    var sign: Double
}

struct Config: Codable {
    var yaw = AxisMap(source: "yaw", sign: 1)
    var pitch = AxisMap(source: "pitch", sign: 1)
    var roll = AxisMap(source: "roll", sign: 1)
    var gainYaw: Double = 2.0
    var gainPitch: Double = 1.6
    var gainRoll: Double = 1.0
    var deadzoneDeg: Double = 0.4
    var enableRoll = true
    var calibrated = false
    var opentrackEnabled = true
    var opentrackHost = "127.0.0.1"
    var opentrackPort: Int = 4242

    static let axes = ["yaw", "pitch", "roll"]

    mutating func sanitize() {
        for kp in [\Config.yaw, \Config.pitch, \Config.roll] {
            if !Config.axes.contains(self[keyPath: kp].source) { self[keyPath: kp].source = "yaw" }
            self[keyPath: kp].sign = self[keyPath: kp].sign < 0 ? -1 : 1
        }
        gainYaw = min(8, max(0, gainYaw))
        gainPitch = min(8, max(0, gainPitch))
        gainRoll = min(8, max(0, gainRoll))
        deadzoneDeg = min(15, max(0, deadzoneDeg))
        opentrackPort = min(65535, max(1, opentrackPort))
    }

    func jsonObject() -> [String: Any] {
        let data = try! JSONEncoder().encode(self)
        return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    func merged(with patch: [String: Any]) throws -> Config {
        var base = jsonObject()
        for (k, v) in patch {
            if let sub = v as? [String: Any], var existing = base[k] as? [String: Any] {
                for (sk, sv) in sub { existing[sk] = sv }
                base[k] = existing
            } else {
                base[k] = v
            }
        }
        let data = try JSONSerialization.data(withJSONObject: base)
        var cfg = try JSONDecoder().decode(Config.self, from: data)
        cfg.sanitize()
        return cfg
    }

    static func load(from url: URL) -> Config {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cfg = try? Config().merged(with: obj) else { return Config() }
        return cfg
    }

    func save(to url: URL) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(self).write(to: url, options: .atomic)
        } catch {
            log("Could not save config: \(error.localizedDescription)")
        }
    }
}

final class Engine: NSObject, CMHeadphoneMotionManagerDelegate {
    let opts: Options
    var config: Config
    let motion = CMHeadphoneMotionManager()
    var server: HTTPServer!

    var reference: CMAttitude?
    var recenterPending = true
    var delegateConnected = false
    var lastSampleUptime: TimeInterval = 0
    var sensor = "none"
    var hz: Double = 0
    var windowCount = 0
    var windowStart: TimeInterval = ProcessInfo.processInfo.systemUptime
    var totalSamples = 0
    var udp: NWConnection?
    var statusTimer: DispatchSourceTimer?
    var onStatusText: ((String) -> Void)?

    init(opts: Options) {
        self.opts = opts
        self.config = Config.load(from: opts.configURL)
        super.init()
    }

    func boot() {
        log("Kopfkino starting — web dir: \(opts.webDir.path)")
        log("Config: \(opts.configURL.path)")
        serverQ.sync {
            rebuildUDP()
            do {
                server = try HTTPServer(port: opts.port, engine: self)
                server.start()
            } catch {
                log("FATAL: could not start HTTP server: \(error)")
                exit(1)
            }
            let t = DispatchSource.makeTimerSource(queue: serverQ)
            t.schedule(deadline: .now() + 1, repeating: 1)
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            statusTimer = t
        }
        DispatchQueue.main.async { self.startMotion() }
    }

    func startMotion() {
        log("Motion authorization: \(authString())")
        guard motion.isDeviceMotionAvailable else {
            log("Headphone motion is NOT available on this Mac (needs macOS 14+).")
            return
        }
        motion.delegate = self
        if motion.isDeviceMotionActive { return }
        let q = OperationQueue()
        q.underlyingQueue = serverQ
        q.maxConcurrentOperationCount = 1
        motion.startDeviceMotionUpdates(to: q) { [weak self] m, err in
            guard let self else { return }
            if let err {
                log("Motion error: \(err.localizedDescription)")
                return
            }
            if let m { self.handle(m) }
        }
        log("Headphone motion updates requested — put both AirPods in your ears.")
    }

    func authString() -> String {
        switch CMHeadphoneMotionManager.authorizationStatus() {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "notDetermined"
        @unknown default: return "unknown"
        }
    }

    func headphoneMotionManagerDidConnect(_ manager: CMHeadphoneMotionManager) {
        serverQ.async {
            self.delegateConnected = true
            self.recenterPending = true
            log("AirPods motion connected")
            self.server.broadcastStatus()
        }
        DispatchQueue.main.async { self.startMotion() }
    }

    func headphoneMotionManagerDidDisconnect(_ manager: CMHeadphoneMotionManager) {
        serverQ.async {
            self.delegateConnected = false
            log("AirPods motion disconnected")
            self.server.broadcastStatus()
        }
    }

    func handle(_ m: CMDeviceMotion) {
        let now = ProcessInfo.processInfo.systemUptime
        if totalSamples == 0 { log("First motion sample received ✔") }
        totalSamples += 1
        lastSampleUptime = now
        windowCount += 1

        switch m.sensorLocation {
        case .headphoneLeft: sensor = "left"
        case .headphoneRight: sensor = "right"
        default: sensor = "default"
        }

        if recenterPending || reference == nil {
            reference = m.attitude.copy() as? CMAttitude
            recenterPending = false
            log("Recentered")
        }
        guard let ref = reference, let rel = m.attitude.copy() as? CMAttitude else { return }
        rel.multiply(byInverseOf: ref)

        let k = 180.0 / Double.pi
        let raw = [rel.yaw * k, rel.pitch * k, rel.roll * k]

        func pick(_ a: AxisMap) -> Double {
            raw[Config.axes.firstIndex(of: a.source) ?? 0] * a.sign
        }
        let dz = config.deadzoneDeg
        func shape(_ v: Double, _ gain: Double, _ limit: Double) -> Double {
            let mag = max(0, abs(v) - dz) * gain
            return min(limit, max(-limit, v < 0 ? -mag : mag))
        }
        let yaw = shape(pick(config.yaw), config.gainYaw, 180)
        let pitch = shape(pick(config.pitch), config.gainPitch, 89)
        let roll = config.enableRoll ? shape(pick(config.roll), config.gainRoll, 90) : 0

        sendOpenTrack(yaw: yaw, pitch: pitch, roll: roll)

        let json = "{\"t\":\(String(format: "%.3f", m.timestamp)),\"yaw\":\(f2(yaw)),\"pitch\":\(f2(pitch)),\"roll\":\(f2(roll)),"
            + "\"raw\":[\(f2(raw[0])),\(f2(raw[1])),\(f2(raw[2]))],\"hz\":\(Int(hz.rounded())),\"sensor\":\"\(sensor)\"}"
        server.broadcast(event: nil, data: json)
    }

    func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        hz = Double(windowCount) / max(0.001, now - windowStart)
        windowCount = 0
        windowStart = now
        server.broadcastStatus()

        let text: String
        switch authString() {
        case "denied", "restricted": text = "Motion access denied (System Settings)"
        default:
            if lastSampleUptime > 0 && now - lastSampleUptime < 1.5 {
                text = "Tracking · \(Int(hz.rounded())) Hz · \(sensor) bud"
            } else {
                text = "Waiting for AirPods…"
            }
        }
        if let cb = onStatusText { DispatchQueue.main.async { cb(text) } }
    }

    func recenter() {
        recenterPending = true
    }

    func statusJSON() -> String {
        let now = ProcessInfo.processInfo.systemUptime
        let age = lastSampleUptime == 0 ? -1 : Int((now - lastSampleUptime) * 1000)
        let obj: [String: Any] = [
            "available": motion.isDeviceMotionAvailable,
            "active": motion.isDeviceMotionActive,
            "connected": delegateConnected || (age >= 0 && age < 1000),
            "auth": authString(),
            "lastSampleAgeMs": age,
            "hz": Int(hz.rounded()),
            "sensor": sensor,
            "samples": totalSamples,
            "opentrack": ["enabled": config.opentrackEnabled, "host": config.opentrackHost, "port": config.opentrackPort],
        ]
        let data = try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    func configJSON() -> String {
        let data = try! JSONSerialization.data(withJSONObject: config.jsonObject(), options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    func apply(patch: [String: Any]) throws {
        let old = config
        config = try config.merged(with: patch)
        config.save(to: opts.configURL)
        if old.opentrackEnabled != config.opentrackEnabled || old.opentrackHost != config.opentrackHost
            || old.opentrackPort != config.opentrackPort {
            rebuildUDP()
        }
        server.broadcast(event: "config", data: configJSON())
    }

    func resetConfig() {
        config = Config()
        config.save(to: opts.configURL)
        rebuildUDP()
        server.broadcast(event: "config", data: configJSON())
    }

    func rebuildUDP() {
        udp?.cancel()
        udp = nil
        guard config.opentrackEnabled, let port = NWEndpoint.Port(rawValue: UInt16(config.opentrackPort)) else { return }
        let c = NWConnection(host: NWEndpoint.Host(config.opentrackHost), port: port, using: .udp)
        c.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                serverQ.asyncAfter(deadline: .now() + 2) { self?.rebuildUDP() }
            }
        }
        c.start(queue: serverQ)
        udp = c
        log("OpenTrack UDP output → \(config.opentrackHost):\(config.opentrackPort)")
    }

    func sendOpenTrack(yaw: Double, pitch: Double, roll: Double) {
        guard config.opentrackEnabled, let udp, udp.state == .ready else { return }
        let values: [Double] = [0, 0, 0, yaw, pitch, roll]
        let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
        udp.send(content: data, completion: .idempotent)
    }
}

final class HTTPServer {
    let listener: NWListener
    unowned let engine: Engine
    let port: UInt16
    var sseClients: [ObjectIdentifier: NWConnection] = [:]

    init(port: UInt16, engine: Engine) throws {
        self.port = port
        self.engine = engine
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcp)
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        listener = try NWListener(using: params)
    }

    func start() {
        var announced = false
        listener.stateUpdateHandler = { [port, engine] state in
            switch state {
            case .ready:
                log("Serving http://127.0.0.1:\(port)/")
                if !announced && engine.opts.openBrowser {
                    DispatchQueue.main.async { NSWorkspace.shared.open(engine.opts.pageURL) }
                }
                announced = true
            case .failed(let e):
                log("FATAL: listener failed: \(e) (is port \(port) already in use?)")
                exit(1)
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] c in self?.accept(c) }
        listener.start(queue: serverQ)
    }

    private func accept(_ c: NWConnection) {
        c.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.sseClients.removeValue(forKey: ObjectIdentifier(c))
            default: break
            }
        }
        c.start(queue: serverQ)
        read(c, buffer: Data())
    }

    private func read(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, err in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            let sep = Data("\r\n\r\n".utf8)
            guard let r = buf.range(of: sep) else {
                if done || err != nil || buf.count > 1 << 20 { c.cancel() } else { self.read(c, buffer: buf) }
                return
            }
            let head = String(decoding: buf[buf.startIndex..<r.lowerBound], as: UTF8.self)
            var lines = head.components(separatedBy: "\r\n")
            let requestLine = lines.removeFirst().split(separator: " ")
            guard requestLine.count >= 2 else { c.cancel(); return }
            var headers: [String: String] = [:]
            for l in lines {
                guard let i = l.firstIndex(of: ":") else { continue }
                headers[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces)
            }
            let length = Int(headers["content-length"] ?? "0") ?? 0
            let body = buf[r.upperBound...]
            if body.count < length {
                if done || err != nil { c.cancel() } else { self.read(c, buffer: buf) }
                return
            }
            self.route(c, method: String(requestLine[0]), target: String(requestLine[1]),
                       headers: headers, body: Data(body.prefix(length)))
        }
    }

    private func route(_ c: NWConnection, method: String, target: String, headers: [String: String], body: Data) {
        let path = target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/"

        if method == "POST" {
            if let origin = headers["origin"],
               origin != "http://127.0.0.1:\(port)", origin != "http://localhost:\(port)" {
                return respond(c, 403, "application/json", Data("{\"error\":\"forbidden origin\"}".utf8))
            }
        }

        switch (method, path) {
        case ("GET", "/events"):
            startSSE(c)
        case ("GET", "/api/status"):
            respondJSON(c, engine.statusJSON())
        case ("GET", "/api/config"):
            respondJSON(c, engine.configJSON())
        case ("POST", "/api/config"):
            do {
                guard let patch = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                    throw NSError(domain: "kopfkino", code: 1)
                }
                try engine.apply(patch: patch)
                respondJSON(c, engine.configJSON())
            } catch {
                respond(c, 400, "application/json", Data("{\"error\":\"bad config\"}".utf8))
            }
        case ("POST", "/api/config/reset"):
            engine.resetConfig()
            respondJSON(c, engine.configJSON())
        case ("POST", "/api/recenter"):
            engine.recenter()
            respondJSON(c, "{\"ok\":true}")
        case ("GET", _), ("HEAD", _):
            serveStatic(c, path: path, headOnly: method == "HEAD")
        default:
            respond(c, 405, "text/plain", Data("method not allowed".utf8))
        }
    }

    private func startSSE(_ c: NWConnection) {
        let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-store\r\n"
            + "Connection: keep-alive\r\nX-Accel-Buffering: no\r\n\r\nretry: 1000\n\n"
            + "event: config\ndata: \(engine.configJSON())\n\n"
            + "event: status\ndata: \(engine.statusJSON())\n\n"
        c.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
        sseClients[ObjectIdentifier(c)] = c
        drain(c)
    }

    private func drain(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] _, _, done, err in
            if done || err != nil {
                self?.sseClients.removeValue(forKey: ObjectIdentifier(c))
                c.cancel()
            } else {
                self?.drain(c)
            }
        }
    }

    func broadcast(event: String?, data: String) {
        guard !sseClients.isEmpty else { return }
        var msg = ""
        if let event { msg += "event: \(event)\n" }
        msg += "data: \(data)\n\n"
        let payload = Data(msg.utf8)
        for (id, c) in sseClients {
            c.send(content: payload, completion: .contentProcessed { [weak self] err in
                if err != nil {
                    self?.sseClients.removeValue(forKey: id)
                    c.cancel()
                }
            })
        }
    }

    func broadcastStatus() { broadcast(event: "status", data: engine.statusJSON()) }

    private func serveStatic(_ c: NWConnection, path: String, headOnly: Bool) {
        var rel = path.removingPercentEncoding ?? path
        if rel.hasSuffix("/") { rel += "index.html" }
        let root = engine.opts.webDir
        let file = root.appendingPathComponent(String(rel.drop(while: { $0 == "/" }))).standardizedFileURL
        guard file.path.hasPrefix(root.path + "/"),
              let data = try? Data(contentsOf: file) else {
            return respond(c, 404, "text/plain", Data("not found".utf8))
        }
        let types = ["html": "text/html; charset=utf-8", "js": "text/javascript; charset=utf-8",
                     "mjs": "text/javascript; charset=utf-8", "css": "text/css; charset=utf-8",
                     "json": "application/json", "svg": "image/svg+xml", "png": "image/png",
                     "ico": "image/x-icon"]
        let type = types[file.pathExtension.lowercased()] ?? "application/octet-stream"
        respond(c, 200, type, headOnly ? Data() : data, contentLength: data.count)
    }

    private func respondJSON(_ c: NWConnection, _ json: String) {
        respond(c, 200, "application/json", Data(json.utf8))
    }

    private func respond(_ c: NWConnection, _ status: Int, _ type: String, _ body: Data, contentLength: Int? = nil) {
        let reason = [200: "OK", 400: "Bad Request", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed"][status] ?? "OK"
        let head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(contentLength ?? body.count)\r\n"
            + "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(body)
        c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let engine: Engine
    var statusItem: NSStatusItem!
    let statusLine = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")

    init(engine: Engine) {
        self.engine = engine
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let img = NSImage(systemSymbolName: "airpodspro", accessibilityDescription: "Kopfkino") {
            img.isTemplate = true
            statusItem.button?.image = img
        } else {
            statusItem.button?.title = "KK"
        }

        let menu = NSMenu()
        let title = NSMenuItem(title: "Kopfkino", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())
        menu.addItem(item("Open Flight Test", #selector(openPage), "o"))
        menu.addItem(item("Recenter", #selector(recenter), "r"))
        menu.addItem(.separator())
        menu.addItem(item("Quit Kopfkino", #selector(quit), "q"))
        statusItem.menu = menu

        engine.onStatusText = { [weak self] text in self?.statusLine.title = text }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openPage()
        return false
    }

    private func item(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    @objc func openPage() { NSWorkspace.shared.open(engine.opts.pageURL) }
    @objc func recenter() { serverQ.async { self.engine.recenter() } }
    @objc func quit() {
        engine.motion.stopDeviceMotionUpdates()
        NSApp.terminate(nil)
    }
}

let options = Options.parse()
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let engine = Engine(opts: options)
let delegate = AppDelegate(engine: engine)
app.delegate = delegate

var signalSources: [DispatchSourceSignal] = []
for sig in [SIGINT, SIGTERM] {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler {
        log("Shutting down")
        engine.motion.stopDeviceMotionUpdates()
        exit(0)
    }
    src.resume()
    signalSources.append(src)
}

engine.boot()
app.run()
