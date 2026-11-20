import AppKit
import AVFoundation
import Carbon
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

struct CalibrationData: Codable {
    var date: String
    var left: [Double]
    var right: [Double]
    var up: [Double]
    var down: [Double]
    var tilt: [Double]
}

struct CalibStep {
    let key: String
    let title: String
    let sub: String
    let speech: String
    let hold: Double
}

let calibSteps = [
    CalibStep(key: "center", title: "Look at the center of your screen", sub: "hold still",
              speech: "Look at the center of your screen.", hold: 2.5),
    CalibStep(key: "left", title: "Look at the left edge of your screen", sub: "point your nose at it and hold",
              speech: "Now look at the left edge of your screen.", hold: 3),
    CalibStep(key: "right", title: "Look at the right edge of your screen", sub: "point your nose at it and hold",
              speech: "The right edge.", hold: 3),
    CalibStep(key: "up", title: "Look at the top edge of your screen", sub: "point your nose at it and hold",
              speech: "The top edge.", hold: 3),
    CalibStep(key: "down", title: "Look at the bottom edge of your screen", sub: "point your nose at it and hold",
              speech: "The bottom edge.", hold: 3),
    CalibStep(key: "tilt", title: "Tilt your head to the left", sub: "left ear toward your shoulder, hold",
              speech: "Tilt your head to the left.", hold: 3),
]

struct CalibUI {
    var state: String
    var step = 0
    var total = calibSteps.count
    var title = ""
    var sub = ""
    var progress = 0.0
    var remaining = 0.0
    var message = ""
    var speech: String?

    func json() -> String {
        let obj: [String: Any] = ["state": state, "step": step, "total": total, "title": title, "sub": sub,
                                  "progress": progress, "remaining": remaining, "message": message]
        let data = try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
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
    var mode = "pov"
    var povMouseSpeed: Double = 7
    var cursorReachX: Double = 15
    var cursorReachY: Double = 9
    var cursorCenterX: Double = 0
    var cursorCenterY: Double = 0
    var nodClick = true
    var curve: Double = 0.5
    var calibration: CalibrationData?

    static let axes = ["yaw", "pitch", "roll"]
    static let modes = ["off", "pov", "cursor"]

    mutating func sanitize() {
        if !Config.modes.contains(mode) { mode = "pov" }
        curve = min(1, max(0, curve))
        povMouseSpeed = min(60, max(0.5, povMouseSpeed))
        cursorReachX = min(60, max(3, cursorReachX))
        cursorReachY = min(60, max(3, cursorReachY))
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

enum CursorScale {
    typealias Conn = @convention(c) () -> Int32
    typealias Setter = @convention(c) (Int32, Float) -> Int32
    typealias Getter = @convention(c) (Int32, UnsafeMutablePointer<Float>) -> Int32

    static let lib = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)

    static func sym<T>(_ names: [String], _ type: T.Type) -> T? {
        for n in names { if let p = dlsym(lib, n) { return unsafeBitCast(p, to: type) } }
        return nil
    }

    static let conn = sym(["SLSMainConnectionID", "CGSMainConnectionID"], Conn.self)
    static let setter = sym(["SLSSetCursorScale", "CGSSetCursorScale"], Setter.self)
    static let getter = sym(["SLSGetCursorScale", "CGSGetCursorScale"], Getter.self)

    static func get() -> Float? {
        guard let conn, let getter else { return nil }
        var v: Float = 0
        return getter(conn(), &v) == 0 ? v : nil
    }

    static func set(_ v: Float) {
        guard let conn, let setter else { return }
        _ = setter(conn(), v)
    }
}

struct OneEuro {
    var minCutoff = 0.9
    var beta = 0.012
    var dCutoff = 1.0

    init(minCutoff: Double = 0.9, beta: Double = 0.012) {
        self.minCutoff = minCutoff
        self.beta = beta
    }
    private var x: Double?
    private var dx = 0.0
    private var t = 0.0

    private func alpha(_ cutoff: Double, _ dt: Double) -> Double {
        let tau = 1 / (2 * Double.pi * cutoff)
        return 1 / (1 + tau / dt)
    }

    mutating func reset() { x = nil; dx = 0 }

    mutating func filter(_ v: Double, _ now: Double) -> Double {
        guard let prev = x else { x = v; t = now; return v }
        let dt = max(0.001, now - t)
        t = now
        let d = (v - prev) / dt
        dx += alpha(dCutoff, dt) * (d - dx)
        let cutoff = minCutoff + beta * abs(dx)
        let out = prev + alpha(cutoff, dt) * (v - prev)
        x = out
        return out
    }
}

struct NodResult {
    var click = false
    var holding = false
    var anchorTime = 0.0
}

struct NodDetector {
    private var hist: [(t: Double, pitch: Double, yaw: Double)] = []
    private var cooldownUntil = 0.0

    mutating func reset() { hist.removeAll() }

    mutating func update(pitch: Double, yaw: Double, now: Double) -> NodResult {
        hist.append((now, pitch, yaw))
        while let f = hist.first, now - f.t > 1.4 { hist.removeFirst() }
        if now < cooldownUntil || hist.count < 4 { return NodResult() }

        let recent = hist.filter { now - $0.t <= 1.0 }
        guard let low = recent.min(by: { $0.pitch < $1.pitch }) else { return NodResult() }
        let before = hist.filter { $0.t <= low.t && low.t - $0.t <= 0.6 }
        guard let top = before.max(by: { $0.pitch < $1.pitch }),
              let onset = before.last(where: { $0.pitch >= top.pitch - 0.6 }) else { return NodResult() }

        let depth = top.pitch - low.pitch
        let rise = pitch - low.pitch
        let down = max(0.04, low.t - onset.t)
        let rest = hist.filter { $0.t < onset.t && onset.t - $0.t <= 0.4 }
        let baseline = rest.isEmpty ? onset.pitch : rest.map(\.pitch).reduce(0, +) / Double(rest.count)
        let span = hist.filter { $0.t >= onset.t }
        let yawRange = (span.map(\.yaw).max() ?? yaw) - (span.map(\.yaw).min() ?? yaw)
        let steady = yawRange <= max(4, depth * 0.6)
        let fromRest = onset.pitch - baseline < 2.5
        let dipping = depth >= 1.2 && depth / down >= 10 && depth <= 28 && down <= 0.45 && steady && fromRest

        if dipping && depth >= 3.5 && rise >= depth * 0.6 && now - onset.t <= 1.0 && now - low.t <= 0.5 {
            cooldownUntil = now + 0.6
            hist.removeAll()
            return NodResult(click: true, holding: false, anchorTime: onset.t)
        }

        let reached = span.first(where: { $0.pitch <= low.pitch + 1.0 })?.t ?? low.t
        let stillLow = rise < depth * 0.3 && now - reached > 0.22
        let holding = dipping && !stillLow && rise < depth * 0.6 && now - onset.t <= 0.8
        return NodResult(click: false, holding: holding, anchorTime: onset.t)
    }
}

final class Snapper {
    private let q = DispatchQueue(label: "kopfkino.snap", qos: .userInitiated)
    private let system = AXUIElementCreateSystemWide()
    private var busy = false
    private var lastQuery = 0.0
    private var candidates: [CGRect] = []
    private var locked: CGRect?
    private var outsideSince: Double?
    private var lastGaze: (p: CGPoint, t: Double)?

    static let roles: Set<String> = [
        "AXButton", "AXLink", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton",
        "AXMenuItem", "AXTextField", "AXComboBox", "AXSearchField", "AXDisclosureTriangle",
        "AXSlider", "AXIncrementor", "AXTab", "AXSegment", "AXCell",
    ]

    init() {
        AXUIElementSetMessagingTimeout(system, 0.05)
    }

    func reset() {
        candidates = []
        locked = nil
        outsideSince = nil
        lastGaze = nil
    }

    func probe(_ p: CGPoint, screen: CGRect, now: Double) {
        guard !busy, now - lastQuery > 0.08 else { return }
        busy = true
        lastQuery = now
        q.async {
            var found: [CGRect] = []
            let offsets = [(0.0, 0.0)] + (0..<6).map { i -> (Double, Double) in
                let a = Double(i) * .pi / 3
                return (cos(a) * 28, sin(a) * 28)
            }
            for (dx, dy) in offsets {
                guard let r = self.clickable(at: CGPoint(x: p.x + dx, y: p.y + dy), screen: screen),
                      !found.contains(r) else { continue }
                found.append(r)
            }
            serverQ.async {
                self.candidates = found
                self.busy = false
            }
        }
    }

    static func distance(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        hypot(max(r.minX - p.x, 0, p.x - r.maxX), max(r.minY - p.y, 0, p.y - r.maxY))
    }

    private func score(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        Snapper.distance(p, r) + 0.15 * hypot(r.midX - p.x, r.midY - p.y)
    }

    private func reach(_ r: CGRect) -> CGFloat { min(24, 0.5 * min(r.width, r.height) + 8) }

    func snap(_ gaze: CGPoint, now: Double) -> CGPoint {
        let speed = lastGaze.map { hypot(gaze.x - $0.p.x, gaze.y - $0.p.y) / CGFloat(max(0.005, now - $0.t)) } ?? 0
        lastGaze = (gaze, now)

        let best = candidates.filter { Snapper.distance(gaze, $0) <= reach($0) }.min { score(gaze, $0) < score(gaze, $1) }
        if let l = locked {
            let keep = l.insetBy(dx: -max(16, l.width * 0.25), dy: -max(16, l.height * 0.4)).contains(gaze)
            if let b = best, b != l, b.contains(gaze) {
                locked = b
                outsideSince = nil
            } else if keep {
                outsideSince = nil
            } else {
                if outsideSince == nil { outsideSince = now }
                if now - outsideSince! > 0.12 { locked = nil }
            }
        } else if speed < 1400, let b = best {
            locked = b
            outsideSince = nil
        }

        guard let r = locked else { return gaze }
        let x = r.width > 120 ? min(r.maxX - 10, max(r.minX + 10, gaze.x)) : r.midX
        let y = r.height > 60 ? min(r.maxY - 8, max(r.minY + 8, gaze.y)) : r.midY
        return CGPoint(x: x, y: y)
    }

    private func clickable(at p: CGPoint, screen: CGRect) -> CGRect? {
        var found: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(p.x), Float(p.y), &found) == .success,
              var el = found else { return nil }
        for _ in 0..<4 {
            if let role = attr(el, kAXRoleAttribute) as? String, Snapper.roles.contains(role),
               let r = frame(el), r.width >= 8, r.height >= 8, r.width < 700, r.height < 200 {
                let edge = r.midY < screen.minY + 44 || r.midY > screen.maxY - 44
                    || r.midX < screen.minX + 36 || r.midX > screen.maxX - 36
                return edge ? nil : r
            }
            guard let parent = attr(el, kAXParentAttribute) else { return nil }
            el = parent as! AXUIElement
        }
        return nil
    }

    private func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
    }

    private func frame(_ e: AXUIElement) -> CGRect? {
        guard let pv = attr(e, kAXPositionAttribute), let sv = attr(e, kAXSizeAttribute) else { return nil }
        var pt = CGPoint.zero
        var sz = CGSize.zero
        AXValueGetValue(pv as! AXValue, .cgPoint, &pt)
        AXValueGetValue(sv as! AXValue, .cgSize, &sz)
        return CGRect(origin: pt, size: sz)
    }
}

func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
    let t = min(1, max(0, (x - a) / (b - a)))
    return t * t * (3 - 2 * t)
}

let cursorVisibleFn: (@convention(c) () -> Int32)? = {
    guard let p = dlsym(CursorScale.lib, "CGCursorIsVisible") else { return nil }
    return unsafeBitCast(p, to: (@convention(c) () -> Int32).self)
}()

func cursorHidden() -> Bool { (cursorVisibleFn?() ?? 1) == 0 }

final class MouseWatch {
    static let marker: Int64 = 0x4B4F5046
    private let lock = NSLock()
    private var tap: CFMachPort?
    private var last = 0.0
    private var lastLoc: CGPoint?
    private var stuck = 0
    private var moving = 0
    private var pinnedFlag = false
    private var activeFlag = false

    var active: Bool { lock.lock(); defer { lock.unlock() }; return activeFlag }
    var lastPhysical: Double { lock.lock(); defer { lock.unlock() }; return last }
    var pinned: Bool { lock.lock(); defer { lock.unlock() }; return pinnedFlag }

    func clearPinned() {
        lock.lock()
        pinnedFlag = false
        stuck = 0
        moving = 0
        lock.unlock()
    }

    func start() {
        guard tap == nil else { return }
        let types: [CGEventType] = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                                        eventsOfInterest: mask, callback: { _, type, event, info in
            if let info {
                let w = Unmanaged<MouseWatch>.fromOpaque(info).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput { w.reenable() } else { w.saw(event) }
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return }
        tap = t
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, t, 0), .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        lock.lock()
        activeFlag = true
        lock.unlock()
        log("Mouse watch active")
    }

    private func reenable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    private func saw(_ e: CGEvent) {
        if e.getIntegerValueField(.eventSourceUserData) == MouseWatch.marker { return }
        let dx = e.getIntegerValueField(.mouseEventDeltaX), dy = e.getIntegerValueField(.mouseEventDeltaY)
        let loc = e.location
        lock.lock()
        last = ProcessInfo.processInfo.systemUptime
        if dx != 0 || dy != 0, let l = lastLoc {
            if hypot(loc.x - l.x, loc.y - l.y) < 0.5 {
                stuck += 1
                moving = 0
            } else {
                moving += 1
                stuck = 0
            }
            if stuck >= 3 { pinnedFlag = true }
            if moving >= 2 { pinnedFlag = false }
        }
        lastLoc = loc
        lock.unlock()
    }
}

final class Pointer {
    private let source = CGEventSource(stateID: .hidSystemState)
    let watch = MouseWatch()
    private var lastPOV: (yaw: Double, pitch: Double, t: Double)?
    private var povYaw = OneEuro(minCutoff: 1.2, beta: 0.04)
    private var povPitch = OneEuro(minCutoff: 1.2, beta: 0.04)
    private var pending = CGPoint.zero
    private var carry = CGPoint.zero
    private var emitter: DispatchSourceTimer?
    private var lastEmit = 0.0
    private var fx = OneEuro()
    private var fy = OneEuro()
    private var offset = CGPoint.zero
    private var lastPosted: CGPoint?
    private var manualUntil = 0.0
    private var nodder = NodDetector()
    private var nodAnchor: CGPoint?
    private var trail: [(t: Double, p: CGPoint)] = []
    private let snapper = Snapper()
    var allowed = AXIsProcessTrusted() || CGPreflightPostEventAccess()
    var onClick: (() -> Void)?

    func reset() {
        resetPOV()
        fx.reset()
        fy.reset()
        offset = .zero
        lastPosted = nil
        manualUntil = 0
        nodder.reset()
        nodAnchor = nil
        trail.removeAll()
        snapper.reset()
    }

    func resetPOV() {
        lastPOV = nil
        povYaw.reset()
        povPitch.reset()
        pending = .zero
        carry = .zero
    }

    func setEmitter(_ on: Bool) {
        if on, emitter == nil {
            let t = DispatchSource.makeTimerSource(flags: .strict, queue: serverQ)
            t.schedule(deadline: .now(), repeating: .milliseconds(4), leeway: .microseconds(500))
            t.setEventHandler { [weak self] in self?.emit() }
            t.resume()
            emitter = t
        } else if !on, let t = emitter {
            t.cancel()
            emitter = nil
            resetPOV()
        }
    }

    func pov(yaw: Double, pitch: Double, speed: Double, now: Double) {
        let y = povYaw.filter(yaw, now), p = povPitch.filter(pitch, now)
        defer { lastPOV = (y, p, now) }
        guard let last = lastPOV else { return }
        let dYaw = y - last.yaw, dPitch = p - last.pitch
        let v = hypot(dYaw, dPitch) / max(0.001, now - last.t)
        let accel = 0.85 + 0.4 * smoothstep(15, 160, v)
        pending.x -= dYaw * speed * accel
        pending.y -= dPitch * speed * accel
    }

    private func emit() {
        let now = ProcessInfo.processInfo.systemUptime
        let dt = lastEmit == 0 ? 0.004 : min(0.05, now - lastEmit)
        lastEmit = now
        if abs(pending.x) < 0.01 && abs(pending.y) < 0.01 { return }
        let f = 1 - exp(-dt / 0.022)
        let sx = pending.x * f, sy = pending.y * f
        pending.x -= sx
        pending.y -= sy
        carry.x += sx
        carry.y += sy
        let ix = carry.x.rounded(.towardZero), iy = carry.y.rounded(.towardZero)
        if ix == 0 && iy == 0 { return }
        carry.x -= ix
        carry.y -= iy
        guard allowed else { return }
        post(CGEvent(source: nil)?.location ?? .zero, dx: Int64(ix), dy: Int64(iy))
    }

    func cursor(yaw: Double, pitch: Double, reachX: Double, reachY: Double, nodClick: Bool, now: Double) {
        let b = CGDisplayBounds(CGMainDisplayID())
        let here = CGEvent(source: nil)?.location ?? .zero
        let gx = fx.filter(Double(b.midX) - yaw / reachX * Double(b.width) / 2, now)
        let gy = fy.filter(Double(b.midY) - pitch / reachY * Double(b.height) / 2, now)

        if watch.active {
            if now - watch.lastPhysical < 0.25 { manualUntil = now }
        } else if let lp = lastPosted, hypot(here.x - lp.x, here.y - lp.y) > 1.5 {
            manualUntil = now + 0.25
        }
        if now <= manualUntil || (watch.active && now - watch.lastPhysical < 0.25) {
            offset = CGPoint(x: here.x - gx, y: here.y - gy)
            lastPosted = here
            nodAnchor = nil
            trail.removeAll()
            nodder.reset()
            snapper.reset()
            return
        }

        let clamp = { (p: CGPoint) in CGPoint(x: min(b.maxX - 1, max(b.minX, p.x)), y: min(b.maxY - 1, max(b.minY, p.y))) }
        let gaze = clamp(CGPoint(x: gx + offset.x, y: gy + offset.y))
        if allowed { snapper.probe(gaze, screen: b, now: now) }
        let snapped = clamp(snapper.snap(gaze, now: now))

        let nod = nodClick ? nodder.update(pitch: pitch, yaw: yaw, now: now) : NodResult()
        if nod.click {
            if let a = nodAnchor ?? trail.last(where: { $0.t <= nod.anchorTime })?.p ?? lastPosted { click(a) }
            nodAnchor = nil
            return
        }
        if nod.holding {
            if nodAnchor == nil {
                let a = trail.last(where: { $0.t <= nod.anchorTime })?.p ?? lastPosted ?? snapped
                nodAnchor = a
                move(to: a, from: here, now: now)
            }
            return
        }
        nodAnchor = nil

        var p = snapped
        if let lp = lastPosted {
            p = CGPoint(x: lp.x + (snapped.x - lp.x) * 0.6, y: lp.y + (snapped.y - lp.y) * 0.6)
        }
        move(to: p, from: here, now: now)
    }

    private func move(to p: CGPoint, from here: CGPoint, now: Double) {
        if let lp = lastPosted, hypot(p.x - lp.x, p.y - lp.y) < 0.5 { return }
        if allowed {
            post(p, dx: Int64((p.x - here.x).rounded()), dy: Int64((p.y - here.y).rounded()))
        } else {
            CGWarpMouseCursorPosition(p)
            CGAssociateMouseAndMouseCursorPosition(1)
        }
        lastPosted = p
        trail.append((now, p))
        while let f = trail.first, now - f.t > 0.6 { trail.removeFirst() }
    }

    private func click(_ p: CGPoint) {
        guard allowed else { return }
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: .left) else { continue }
            e.setIntegerValueField(.mouseEventClickState, value: 1)
            e.setIntegerValueField(.eventSourceUserData, value: MouseWatch.marker)
            e.post(tap: .cghidEventTap)
        }
        if let cb = onClick { DispatchQueue.main.async(execute: cb) }
    }

    private func post(_ p: CGPoint, dx: Int64, dy: Int64) {
        let left = CGEventSource.buttonState(.combinedSessionState, button: .left)
        let right = CGEventSource.buttonState(.combinedSessionState, button: .right)
        let type: CGEventType = left ? .leftMouseDragged : right ? .rightMouseDragged : .mouseMoved
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p,
                              mouseButton: right && !left ? .right : .left) else { return }
        e.setIntegerValueField(.mouseEventDeltaX, value: dx)
        e.setIntegerValueField(.mouseEventDeltaY, value: dy)
        e.setIntegerValueField(.eventSourceUserData, value: MouseWatch.marker)
        e.post(tap: .cghidEventTap)
    }
}

func requestAccessibility() {
    let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
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
    var onModeChange: ((String, Bool) -> Void)?
    let pointer = Pointer()
    var appliedMode = ""
    var lastActiveMode = "pov"
    var savedCursorScale: Float?
    var promptedThisLaunch = false
    var glideFrom = [0.0, 0.0, 0.0]
    var glideStart = -10.0
    var lastPicked = [0.0, 0.0, 0.0]
    var povCaptured = false
    let firstLaunch: Bool
    var rawHistory: [(t: Double, raw: [Double])] = []
    var calibTimer: DispatchSourceTimer?
    var calibIndex = 0
    var calibStepStart = 0.0
    var calibResults: [String: [Double]] = [:]
    var onCalib: ((CalibUI) -> Void)?

    init(opts: Options) {
        self.opts = opts
        self.firstLaunch = !FileManager.default.fileExists(atPath: opts.configURL.path)
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
            if firstLaunch {
                log("First launch: POV mode on, opening the flight test")
                config.mode = "pov"
                config.save(to: opts.configURL)
            }
            modeDidChange(prompt: firstLaunch)
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
        rawHistory.append((now, raw))
        while let f = rawHistory.first, now - f.t > 1.5 { rawHistory.removeFirst() }

        let fade = pow(1 - min(1, (now - glideStart) / 0.6), 3)
        let picked = [config.yaw, config.pitch, config.roll].enumerated().map { i, a in
            raw[Config.axes.firstIndex(of: a.source) ?? 0] * a.sign + glideFrom[i] * fade
        }
        lastPicked = picked
        let dz = config.deadzoneDeg, curve = config.curve
        func shape(_ v: Double, _ gain: Double, _ limit: Double) -> Double {
            let x = max(0, abs(v) - dz)
            let mag = x * gain * (1 - 0.5 * curve * (1 - smoothstep(0, 30, x)))
            return min(limit, max(-limit, v < 0 ? -mag : mag))
        }
        let yaw = shape(picked[0], config.gainYaw, 180)
        let pitch = shape(picked[1], config.gainPitch, 89)
        let roll = config.enableRoll ? shape(picked[2], config.gainRoll, 90) : 0

        switch calibTimer == nil ? config.mode : "off" {
        case "pov":
            sendOpenTrack(yaw: yaw, pitch: pitch, roll: roll)
            let hidden = cursorHidden()
            if !hidden { pointer.watch.clearPinned() }
            let captured = pointer.allowed && hidden && pointer.watch.pinned
            if captured != povCaptured {
                povCaptured = captured
                pointer.resetPOV()
                log(captured ? "POV: mouse captured by game, head look on" : "POV: mouse free, head look paused")
            }
            if captured { pointer.pov(yaw: yaw, pitch: pitch, speed: config.povMouseSpeed, now: now) }
        case "cursor":
            pointer.cursor(yaw: picked[0] - config.cursorCenterX, pitch: picked[1] - config.cursorCenterY, reachX: config.cursorReachX,
                           reachY: config.cursorReachY, nodClick: config.nodClick, now: now)
        default:
            break
        }

        let json = "{\"t\":\(String(format: "%.3f", m.timestamp)),\"yaw\":\(f2(yaw)),\"pitch\":\(f2(pitch)),\"roll\":\(f2(roll)),"
            + "\"raw\":[\(f2(raw[0])),\(f2(raw[1])),\(f2(raw[2]))],\"hz\":\(Int(hz.rounded())),\"sensor\":\"\(sensor)\",\"mode\":\"\(config.mode)\"}"
        server.broadcast(event: nil, data: json)
    }

    func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        hz = Double(windowCount) / max(0.001, now - windowStart)
        windowCount = 0
        windowStart = now

        let allowed = AXIsProcessTrusted() || CGPreflightPostEventAccess()
        if allowed != pointer.allowed {
            pointer.allowed = allowed
            log("Mouse control permission: \(allowed ? "granted" : "not granted")")
            notifyMode()
        }
        if allowed && !pointer.watch.active { DispatchQueue.main.async { self.pointer.watch.start() } }
        server.broadcastStatus()

        let text: String
        switch authString() {
        case "denied", "restricted": text = "Motion access denied (System Settings)"
        default:
            if lastSampleUptime > 0 && now - lastSampleUptime < 1.5 {
                let detail = config.mode == "pov" ? (povCaptured ? " · in game" : " · waiting for game") : ""
                text = "Tracking · \(Int(hz.rounded())) Hz · \(sensor) bud\(detail)"
            } else {
                text = "Waiting for AirPods…"
            }
        }
        if let cb = onStatusText { DispatchQueue.main.async { cb(text) } }
    }

    func recenter() {
        recenterPending = true
        glideFrom = lastPicked
        glideStart = ProcessInfo.processInfo.systemUptime
    }

    func calibrate(_ action: String) {
        switch action {
        case "cancel": if calibTimer != nil { endCalibration(CalibUI(state: "cancelled", speech: "Calibration cancelled.")) }
        case "start": if calibTimer == nil { startCalibration() }
        default: if calibTimer == nil { startCalibration() } else { endCalibration(CalibUI(state: "cancelled", speech: "Calibration cancelled.")) }
        }
    }

    private func publish(_ ui: CalibUI) {
        server.broadcast(event: "calib", data: ui.json())
        if let cb = onCalib { DispatchQueue.main.async { cb(ui) } }
    }

    private func startCalibration() {
        let now = ProcessInfo.processInfo.systemUptime
        guard lastSampleUptime > 0, now - lastSampleUptime < 1.5 else {
            publish(CalibUI(state: "failed", message: "no AirPods data, put both AirPods in first",
                            speech: "I can't hear your AirPods. Put both in and try again."))
            return
        }
        log("Calibration started")
        calibIndex = 0
        calibStepStart = now
        calibResults = [:]
        pointer.reset()
        announceStep(speak: true)
        let t = DispatchSource.makeTimerSource(queue: serverQ)
        t.schedule(deadline: .now() + 0.05, repeating: 0.05)
        t.setEventHandler { [weak self] in self?.calibTick() }
        t.resume()
        calibTimer = t
    }

    private func announceStep(speak: Bool) {
        let step = calibSteps[calibIndex]
        let elapsed = ProcessInfo.processInfo.systemUptime - calibStepStart
        publish(CalibUI(state: "running", step: calibIndex + 1, title: step.title, sub: step.sub,
                        progress: min(1, elapsed / step.hold), remaining: step.hold - elapsed,
                        speech: speak ? step.speech : nil))
    }

    private func calibTick() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastSampleUptime < 1.5 else {
            endCalibration(CalibUI(state: "failed", message: "lost AirPods data", speech: "Lost your AirPods. Calibration stopped."))
            return
        }
        let step = calibSteps[calibIndex]
        if now - calibStepStart < step.hold {
            announceStep(speak: false)
            return
        }
        if step.key == "center" {
            recenterPending = true
            glideStart = -10
            rawHistory.removeAll()
        } else {
            let recent = rawHistory.filter { now - $0.t <= 0.6 }
            guard !recent.isEmpty else {
                endCalibration(CalibUI(state: "failed", message: "no samples", speech: "Calibration failed."))
                return
            }
            calibResults[step.key] = (0..<3).map { i in recent.map { $0.raw[i] }.reduce(0, +) / Double(recent.count) }
        }
        DispatchQueue.main.async { NSSound(named: "Pop")?.play() }
        calibIndex += 1
        calibStepStart = now
        if calibIndex < calibSteps.count {
            announceStep(speak: true)
        } else {
            finishCalibration()
        }
    }

    private func finishCalibration() {
        guard let l = calibResults["left"], let r = calibResults["right"], let u = calibResults["up"],
              let d = calibResults["down"], let tilt = calibResults["tilt"] else { return }
        let lr = (0..<3).map { l[$0] - r[$0] }
        let ud = (0..<3).map { u[$0] - d[$0] }
        let yawAxis = (0..<3).max { abs(lr[$0]) < abs(lr[$1]) }!
        let pitchAxis = (0..<3).filter { $0 != yawAxis }.max { abs(ud[$0]) < abs(ud[$1]) }!
        let rollAxis = 3 - yawAxis - pitchAxis
        let reachX = abs(lr[yawAxis]) / 2, reachY = abs(ud[pitchAxis]) / 2
        var problem: String?
        if reachX < 3 { problem = "barely any left/right movement, turn your head toward the edges" }
        else if reachY < 2 { problem = "barely any up/down movement, point your nose at the top and bottom edges" }
        else if abs(tilt[rollAxis]) < 5 { problem = "the head tilt was too small" }
        if let problem {
            endCalibration(CalibUI(state: "failed", message: problem, speech: "Calibration failed. Your old calibration is still saved."))
            return
        }
        let round1 = { (v: Double) in (v * 10).rounded() / 10 }
        let iso = ISO8601DateFormatter().string(from: Date())
        let patch: [String: Any] = [
            "yaw": ["source": Config.axes[yawAxis], "sign": lr[yawAxis] > 0 ? 1 : -1],
            "pitch": ["source": Config.axes[pitchAxis], "sign": ud[pitchAxis] > 0 ? 1 : -1],
            "roll": ["source": Config.axes[rollAxis], "sign": tilt[rollAxis] > 0 ? 1 : -1],
            "cursorReachX": max(3, round1(reachX)),
            "cursorReachY": max(3, round1(reachY)),
            "cursorCenterX": round1((l[yawAxis] + r[yawAxis]) / 2 * (lr[yawAxis] > 0 ? 1 : -1)),
            "cursorCenterY": round1((u[pitchAxis] + d[pitchAxis]) / 2 * (ud[pitchAxis] > 0 ? 1 : -1)),
            "calibrated": true,
            "calibration": ["date": iso, "left": l.map(round1), "right": r.map(round1), "up": u.map(round1),
                            "down": d.map(round1), "tilt": tilt.map(round1)],
        ]
        do {
            try apply(patch: patch)
        } catch {
            endCalibration(CalibUI(state: "failed", message: "could not save", speech: "Calibration failed."))
            return
        }
        log("Calibration saved: yaw=\(Config.axes[yawAxis]) pitch=\(Config.axes[pitchAxis]) roll=\(Config.axes[rollAxis]) reach=\(round1(reachX))x\(round1(reachY))")
        endCalibration(CalibUI(state: "done", speech: "Calibrated. Look back at the center."))
        serverQ.asyncAfter(deadline: .now() + 1.5) { self.recenter() }
    }

    private func endCalibration(_ ui: CalibUI) {
        calibTimer?.cancel()
        calibTimer = nil
        pointer.reset()
        publish(ui)
    }

    func setMode(_ mode: String) {
        try? apply(patch: ["mode": mode])
    }

    func toggleOnOff() {
        setMode(config.mode == "off" ? lastActiveMode : "off")
    }

    func swapPovCursor() {
        setMode(config.mode == "cursor" ? "pov" : "cursor")
    }

    func notifyMode() {
        let m = config.mode, allowed = pointer.allowed
        if let cb = onModeChange { DispatchQueue.main.async { cb(m, allowed) } }
    }

    func modeDidChange(prompt: Bool) {
        let mode = config.mode
        guard mode != appliedMode else { return }
        let old = appliedMode
        appliedMode = mode
        if mode != "off" { lastActiveMode = mode }
        pointer.reset()
        pointer.setEmitter(mode == "pov")
        povCaptured = false
        log("Mode: \(mode)")
        DispatchQueue.main.async {
            if mode == "cursor" {
                let current = CursorScale.get() ?? 1
                if self.savedCursorScale == nil { self.savedCursorScale = current }
                CursorScale.set(min(4, (self.savedCursorScale ?? 1) * 1.6))
            } else if old == "cursor" {
                self.restoreCursor()
            }
            if prompt && mode != "off" && !AXIsProcessTrusted() && !self.promptedThisLaunch {
                self.promptedThisLaunch = true
                requestAccessibility()
            }
        }
        notifyMode()
    }

    func restoreCursor() {
        if let s = savedCursorScale {
            CursorScale.set(s)
            savedCursorScale = nil
        }
    }

    func shutdown() {
        motion.stopDeviceMotionUpdates()
        restoreCursor()
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
            "mode": config.mode,
            "mouseAccess": pointer.allowed,
            "captured": povCaptured,
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
        modeDidChange(prompt: true)
    }

    func resetConfig() {
        config = Config()
        config.save(to: opts.configURL)
        rebuildUDP()
        server.broadcast(event: "config", data: configJSON())
        modeDidChange(prompt: true)
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
                if !announced && engine.opts.openBrowser && engine.firstLaunch {
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
        case ("POST", "/api/calibrate"):
            let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            engine.calibrate(obj?["action"] as? String ?? "toggle")
            respondJSON(c, "{\"ok\":true}")
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

var hotKeyAction: ((UInt32) -> Void)?

func installHotKeys() {
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
        var id = EventHotKeyID()
        GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                          nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
        hotKeyAction?(id.id)
        return noErr
    }, 1, &spec, nil, nil)
    for (id, key, name) in [(1, kVK_ANSI_K, "K"), (2, kVK_ANSI_M, "M"), (3, kVK_ANSI_R, "R"), (4, kVK_ANSI_C, "C")] {
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(key), UInt32(optionKey | shiftKey),
                                         EventHotKeyID(signature: OSType(0x4B4F5046), id: UInt32(id)),
                                         GetApplicationEventTarget(), 0, &ref)
        log("Hotkey ⌥⇧\(name): \(status == noErr ? "registered" : "failed (\(status))")")
    }
}

final class CalibrationHUD {
    private var panel: NSPanel?
    private let stepLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let subLabel = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()
    private let synth = AVSpeechSynthesizer()
    private var hideWork: DispatchWorkItem?

    private func build() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 118),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .screenSaver
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        let v = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 440, height: 118))
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        v.wantsLayer = true
        v.layer?.cornerRadius = 18
        v.layer?.masksToBounds = true
        for (label, font, color, y) in [(stepLabel, NSFont.systemFont(ofSize: 11, weight: .semibold), NSColor.secondaryLabelColor, 88.0),
                                        (titleLabel, NSFont.systemFont(ofSize: 19, weight: .bold), NSColor.labelColor, 58.0),
                                        (subLabel, NSFont.systemFont(ofSize: 13), NSColor.secondaryLabelColor, 36.0)] {
            label.font = font
            label.textColor = color
            label.alignment = .center
            label.frame = NSRect(x: 16, y: y, width: 408, height: 24)
            v.addSubview(label)
        }
        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.frame = NSRect(x: 40, y: 12, width: 360, height: 14)
        v.addSubview(bar)
        p.contentView = v
        return p
    }

    func update(_ ui: CalibUI) {
        if let s = ui.speech {
            synth.stopSpeaking(at: .immediate)
            synth.speak(AVSpeechUtterance(string: s))
        }
        let p = panel ?? build()
        panel = p
        hideWork?.cancel()
        switch ui.state {
        case "running":
            stepLabel.stringValue = "CALIBRATION \(ui.step) OF \(ui.total)"
            titleLabel.stringValue = ui.title
            subLabel.stringValue = ui.sub
            bar.isHidden = false
            bar.doubleValue = ui.progress
        case "done":
            stepLabel.stringValue = "KOPFKINO"
            titleLabel.stringValue = "Calibrated ✓"
            subLabel.stringValue = "Saved. Run it again any time with ⌥⇧C."
            bar.isHidden = true
        case "failed":
            stepLabel.stringValue = "KOPFKINO"
            titleLabel.stringValue = "Calibration failed"
            subLabel.stringValue = ui.message
            bar.isHidden = true
        default:
            p.orderOut(nil)
            return
        }
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: f.midX - 220, y: f.maxY - 150))
        }
        p.orderFrontRegardless()
        if ui.state != "running" {
            let work = DispatchWorkItem { [weak self] in self?.panel?.orderOut(nil) }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + (ui.state == "done" ? 3 : 6), execute: work)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let engine: Engine
    var statusItem: NSStatusItem!
    let statusLine = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
    var modeItems: [String: NSMenuItem] = [:]
    var accessItem: NSMenuItem!
    var calibItem: NSMenuItem!
    let hud = CalibrationHUD()

    init(engine: Engine) {
        self.engine = engine
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let img = NSImage(systemSymbolName: "gyroscope", accessibilityDescription: "Kopfkino") {
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

        for (mode, name) in [("off", "Off"), ("pov", "POV Mode"), ("cursor", "Cursor Mode")] {
            let i = item(name, #selector(pickMode(_:)), "")
            i.representedObject = mode
            modeItems[mode] = i
            menu.addItem(i)
        }
        accessItem = item("Allow Mouse Control…", #selector(openAccessibility), "")
        accessItem.isHidden = true
        menu.addItem(accessItem)
        menu.addItem(.separator())

        menu.addItem(item("Toggle On/Off", #selector(toggle), "k", [.option, .shift]))
        menu.addItem(item("Switch POV / Cursor", #selector(swap), "m", [.option, .shift]))
        menu.addItem(item("Recenter", #selector(recenter), "r", [.option, .shift]))
        calibItem = item("Calibrate…", #selector(calibrate), "c", [.option, .shift])
        menu.addItem(calibItem)
        menu.addItem(.separator())
        menu.addItem(item("Open Flight Test", #selector(openPage), "", []))
        menu.addItem(item("Quit Kopfkino", #selector(quit), "", []))
        statusItem.menu = menu

        engine.onStatusText = { [weak self] text in self?.statusLine.title = text }
        engine.onModeChange = { [weak self] mode, allowed in self?.show(mode: mode, mouseAllowed: allowed) }
        engine.pointer.onClick = { NSSound(named: "Tink")?.play() }
        engine.onCalib = { [weak self] ui in
            self?.hud.update(ui)
            self?.calibItem.title = ui.state == "running" ? "Cancel Calibration" : "Calibrate…"
        }
        engine.notifyMode()

        hotKeyAction = { [weak self] id in
            DispatchQueue.main.async {
                switch id {
                case 1: self?.toggle()
                case 2: self?.swap()
                case 3: self?.recenter()
                default: self?.calibrate()
                }
            }
        }
        installHotKeys()
    }

    func show(mode: String, mouseAllowed: Bool) {
        for (m, i) in modeItems { i.state = m == mode ? .on : .off }
        accessItem.isHidden = mode == "off" || mouseAllowed
        statusItem.button?.appearsDisabled = mode == "off"
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openPage()
        return false
    }

    private func item(_ title: String, _ action: Selector, _ key: String, _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.keyEquivalentModifierMask = mods
        i.target = self
        return i
    }

    @objc func pickMode(_ sender: NSMenuItem) {
        guard let m = sender.representedObject as? String else { return }
        serverQ.async { self.engine.setMode(m) }
    }

    @objc func toggle() { serverQ.async { self.engine.toggleOnOff() } }
    @objc func swap() { serverQ.async { self.engine.swapPovCursor() } }
    @objc func recenter() { serverQ.async { self.engine.recenter() } }
    @objc func calibrate() { serverQ.async { self.engine.calibrate("toggle") } }
    @objc func openPage() { NSWorkspace.shared.open(engine.opts.pageURL) }

    @objc func openAccessibility() {
        requestAccessibility()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc func quit() {
        engine.shutdown()
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
        engine.shutdown()
        exit(0)
    }
    src.resume()
    signalSources.append(src)
}

engine.boot()
app.run()
