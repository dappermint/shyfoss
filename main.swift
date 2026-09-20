import AppKit
import CoreMotion
import simd
import Carbon.HIToolbox
import ServiceManagement

let defaults = UserDefaults.standard
var comfortDeg: Double { defaults.double(forKey: "comfort") }
var transitionDeg: Double { defaults.double(forKey: "transition") }
var strength: Double { defaults.double(forKey: "strength") }
// extra monitors as offsets from the main center, degrees. ponytail: flat 2d distance, fine below ~60°
var screens: [SIMD2<Double>] {
    get { (defaults.array(forKey: "screens") as? [[Double]] ?? []).map { SIMD2($0[0], $0[1]) } }
    set { defaults.set(newValue.map { [$0.x, $0.y] }, forKey: "screens") }
}

// nearest center: 0 = main, 1... = screens. returns index and offset from that center
func nearest(_ off: SIMD2<Double>) -> (Int, SIMD2<Double>) {
    ([SIMD2<Double>.zero] + screens).enumerated().map { ($0, off - $1) }.min { simd_length($0.1) < simd_length($1.1) }!
}

// ponytail: alpha ramp only, no directional gradient. add CAGradientLayer angled by yaw/pitch if wanted
func coverage(_ dev: Double, comfort: Double, transition: Double) -> Double {
    min(1, max(0, (dev - comfort) / transition))
}

func quat(_ q: CMQuaternion) -> simd_quatd { simd_quatd(ix: q.x, iy: q.y, iz: q.z, r: q.w) }

// where the face points relative to calibration, as a 2d offset in degrees (x right, y up); roll is ignored
func offset(_ ref: simd_quatd, _ cur: simd_quatd) -> SIMD2<Double> {
    let fwd = (ref.inverse * cur).act(SIMD3(0, 1, 0))
    let ang = acos(min(1, max(-1, fwd.y))) * 180 / .pi
    let dir = SIMD2(fwd.x, fwd.z)
    return simd_length(dir) < 1e-9 ? .zero : simd_normalize(dir) * ang
}

func deviation(_ ref: simd_quatd, _ cur: simd_quatd) -> Double { simd_length(offset(ref, cur)) }

final class Overlay: NSWindow {
    var onEscape: (() -> Void)?
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue - 1)
        isOpaque = false
        backgroundColor = .clear
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let blur = NSVisualEffectView(frame: screen.frame)
        blur.material = .fullScreenUI
        blur.blendingMode = .behindWindow
        blur.state = .active
        contentView = blur
        alphaValue = 0
    }
    override var canBecomeKey: Bool { true }
    override func keyDown(with e: NSEvent) { if e.keyCode == 53 { onEscape?() } else { super.keyDown(with: e) } }
}

// top-down view of the zones: clear disc = comfort, ring = fade, outside = shielded. dot = where you look now
final class ZoneView: NSView {
    var head = SIMD2<Double>.zero { didSet { needsDisplay = true } }
    let maxDeg = 75.0
    override var intrinsicContentSize: NSSize { NSSize(width: 200, height: 200) }
    override func draw(_ r: NSRect) {
        let c = NSPoint(x: bounds.midX, y: bounds.midY)
        let scale = (bounds.width / 2 - 4) / maxDeg
        let ring = { (deg: Double, at: SIMD2<Double>) in NSBezierPath(ovalIn: NSRect(x: c.x + at.x * scale - deg * scale, y: c.y + at.y * scale - deg * scale, width: 2 * deg * scale, height: 2 * deg * scale)) }
        NSBezierPath(ovalIn: bounds.insetBy(dx: 4, dy: 4)).addClip()
        NSColor.controlAccentColor.withAlphaComponent(0.25).setFill(); ring(maxDeg, .zero).fill()
        let centers = [SIMD2<Double>.zero] + screens
        NSColor.controlAccentColor.withAlphaComponent(0.12).setFill(); centers.forEach { ring(comfortDeg + transitionDeg, $0).fill() }
        NSColor.windowBackgroundColor.setFill(); centers.forEach { ring(comfortDeg, $0).fill() }
        NSColor.controlAccentColor.setStroke(); centers.forEach { ring(comfortDeg, $0).stroke() }
        NSColor.controlAccentColor.withAlphaComponent(0.4).setStroke(); centers.forEach { ring(comfortDeg + transitionDeg, $0).stroke() }
        let h = simd_length(head) > maxDeg ? simd_normalize(head) * maxDeg : head
        let p = NSPoint(x: c.x + h.x * scale, y: c.y + h.y * scale)
        NSColor.labelColor.setFill(); NSBezierPath(ovalIn: NSRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)).fill()
    }
}

final class SettingsWindow: NSWindow {
    let zone = ZoneView()
    let screenList = NSStackView()
    var labels: [String: NSTextField] = [:]
    var onAddScreen: (() -> Void)?
    let specs: [(String, String, Double, Double, Int, String)] = [
        ("comfort zone", "comfort", 2, 30, 0, "°"),
        ("fade distance", "transition", 5, 30, 0, "°"),
        ("blur strength", "strength", 0.3, 1, 2, ""),
    ]

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 380, height: 460), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        title = "ShyFoss"
        isReleasedWhenClosed = false
        let grid = NSGridView(views: specs.map(row))
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 12
        screenList.orientation = .vertical
        screenList.alignment = .leading
        reloadScreens()
        let add = NSButton(title: "add a screen where i'm looking now", target: self, action: #selector(addScreen))
        let stack = NSStackView(views: [zone, grid, screenList, add])
        stack.orientation = .vertical
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: contentView!.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: contentView!.centerYAnchor),
        ])
        center()
    }

    func row(_ s: (String, String, Double, Double, Int, String)) -> [NSView] {
        let (title, key, lo, hi, digits, unit) = s
        let slider = NSSlider(value: defaults.double(forKey: key), minValue: lo, maxValue: hi, target: self, action: #selector(changed(_:)))
        slider.identifier = NSUserInterfaceItemIdentifier(key)
        slider.widthAnchor.constraint(equalToConstant: 160).isActive = true
        slider.isContinuous = true
        let f = NumberFormatter()
        f.maximumFractionDigits = digits
        f.positiveSuffix = unit
        let value = NSTextField(labelWithString: f.string(from: defaults.double(forKey: key) as NSNumber)!)
        value.formatter = f
        value.widthAnchor.constraint(equalToConstant: 44).isActive = true
        labels[key] = value
        return [NSTextField(labelWithString: title), slider, value]
    }

    func reloadScreens() {
        screenList.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, s) in screens.enumerated() {
            let dir = abs(s.x) > abs(s.y) ? (s.x > 0 ? "right" : "left") : (s.y > 0 ? "up" : "down")
            let label = NSTextField(labelWithString: String(format: "screen %d: %.0f° %@", i + 1, simd_length(s), dir))
            let rm = NSButton(image: NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: "remove")!, target: self, action: #selector(removeScreen(_:)))
            rm.isBordered = false
            rm.tag = i
            screenList.addArrangedSubview(NSStackView(views: [label, rm]))
        }
        zone.needsDisplay = true
    }

    @objc func addScreen() { onAddScreen?() }
    @objc func removeScreen(_ b: NSButton) { screens.remove(at: b.tag); reloadScreens() }

    @objc func changed(_ s: NSSlider) {
        let key = s.identifier!.rawValue
        defaults.set(s.doubleValue, forKey: key)
        labels[key]!.stringValue = (labels[key]!.formatter as! NumberFormatter).string(from: s.doubleValue as NSNumber)!
        zone.needsDisplay = true
    }
}

final class App: NSObject, NSApplicationDelegate, CMHeadphoneMotionManagerDelegate {
    let motion = CMHeadphoneMotionManager()
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var overlays: [Overlay] = []
    var ref: simd_quatd?
    var lastStamp = 0.0
    var lastSeen = Date.distantPast
    var escaped = false
    var stolenFrom: NSRunningApplication?
    let status = NSMenuItem(title: "no airpods", action: nil, keyEquivalent: "")
    let enabledItem = NSMenuItem(title: "enabled", action: #selector(toggle), keyEquivalent: "")
    lazy var settings = { let s = SettingsWindow(); s.onAddScreen = { [unowned self] in addCenter() }; return s }()
    var enabled: Bool { defaults.bool(forKey: "enabled") }

    func applicationDidFinishLaunching(_ n: Notification) {
        defaults.register(defaults: ["comfort": 15.0, "transition": 18.0, "strength": 1.0, "enabled": true])
        item.button?.image = NSImage(systemSymbolName: "eyeglasses", accessibilityDescription: "ShyFoss")
        buildMenu()
        rebuildOverlays()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in self.rebuildOverlays() }
        if !defaults.bool(forKey: "hotkeysShown") { defaults.set(true, forKey: "hotkeysShown"); status.title = "⌃⌥⌘R recenter  ⌃⌥⌘S shield" }
        registerHotkeys()
        let watchdog = Timer(timeInterval: 0.5, repeats: true) { [self] _ in
            if Date().timeIntervalSince(lastSeen) > 1, overlays.contains(where: \.isVisible) { status.title = "no data"; setAlpha(0) }
        }
        RunLoop.main.add(watchdog, forMode: .common)
        motion.delegate = self
        guard motion.isDeviceMotionAvailable else { status.title = "head tracking unavailable"; return }
        motion.startDeviceMotionUpdates(to: .main) { [self] dm, err in
            guard let dm else {
                status.title = CMHeadphoneMotionManager.authorizationStatus() == .denied ? "motion access denied, see system settings > privacy" : err?.localizedDescription ?? "no data"
                return
            }
            tick(quat(dm.attitude.quaternion), dm.timestamp)
        }
    }

    func buildMenu() {
        let m = NSMenu()
        m.addItem(status)
        m.addItem(withTitle: "recenter", action: #selector(recenter), keyEquivalent: "r")
        m.addItem(withTitle: "calibrate…", action: #selector(calibratePrompt), keyEquivalent: "")
        m.addItem(withTitle: "add a screen here", action: #selector(addCenter), keyEquivalent: "")
        enabledItem.state = enabled ? .on : .off
        m.addItem(enabledItem)
        let login = m.addItem(withTitle: "launch at login", action: #selector(toggleLogin), keyEquivalent: "")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        m.addItem(withTitle: "settings…", action: #selector(showSettings), keyEquivalent: ",")
        m.addItem(.separator())
        m.addItem(withTitle: "quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = m
    }

    func rebuildOverlays() {
        overlays.forEach { $0.orderOut(nil) }
        overlays = NSScreen.screens.map { s in
            let o = Overlay(screen: s)
            o.onEscape = { [self] in escaped = true; setAlpha(0) }
            return o
        }
    }

    func tick(_ att: simd_quatd, _ stamp: Double) {
        lastSeen = Date()
        let dt = stamp - lastStamp
        lastStamp = stamp
        if !defaults.bool(forKey: "calibrated") { defaults.set(true, forKey: "calibrated"); calibratePrompt(); return }
        guard let ref else { self.ref = att; return }
        let raw = offset(ref, att)
        let (i, off) = nearest(raw)
        let dev = simd_length(off)
        if settings.isVisible { settings.zone.head = raw }
        status.title = String(format: "off center %.0f°", dev)
        if dev < comfortDeg {
            escaped = false
            // yaw drifts without a magnetometer; follow it at 0.5°/s but only while looking at the screen
            if i == 0, dev > 0.01, dt > 0, dt < 1 { self.ref = simd_slerp(ref, att, min(1, 0.5 * dt / dev)) }
        }
        guard enabled, !escaped else { return }
        setAlpha(coverage(dev, comfort: comfortDeg, transition: transitionDeg) * strength)
    }

    func setAlpha(_ a: Double) {
        item.button?.image = NSImage(systemSymbolName: a > 0 ? "eye.slash" : "eyeglasses", accessibilityDescription: "ShyFoss")
        for o in overlays {
            o.alphaValue = a
            if a > 0 { if !o.isVisible { o.orderFrontRegardless() } }
            else if o.isVisible { o.orderOut(nil) }
        }
        if a >= strength, stolenFrom == nil {
            stolenFrom = NSWorkspace.shared.frontmostApplication
            overlays.first?.makeKey()
        } else if a == 0, let app = stolenFrom {
            stolenFrom = nil
            app.activate()
        }
    }

    @objc func recenter() { ref = nil; escaped = false; setAlpha(0) }
    @objc func addCenter() {
        guard let ref, let cur = motion.deviceMotion else { status.title = "no airpods data yet"; return }
        screens.append(offset(ref, quat(cur.attitude.quaternion)))
        settings.reloadScreens()
    }
    @objc func toggleLogin() {
        let s = SMAppService.mainApp
        do { try s.status == .enabled ? s.unregister() : s.register() } catch { status.title = error.localizedDescription }
        buildMenu()
    }

    // ponytail: fixed ⌃⌥⌘R / ⌃⌥⌘S, add a recorder to settings if anyone asks
    func registerHotkeys() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, ev, _ in
            var id = EventHotKeyID()
            GetEventParameter(ev, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout.size(ofValue: id), nil, &id)
            id.id == 1 ? delegate.recenter() : delegate.toggle()
            return noErr
        }, 1, &spec, nil, nil)
        let mods = UInt32(controlKey | optionKey | cmdKey)
        var ref: EventHotKeyRef?
        RegisterEventHotKey(UInt32(kVK_ANSI_R), mods, EventHotKeyID(signature: 0x53485946, id: 1), GetApplicationEventTarget(), 0, &ref)
        RegisterEventHotKey(UInt32(kVK_ANSI_S), mods, EventHotKeyID(signature: 0x53485946, id: 2), GetApplicationEventTarget(), 0, &ref)
    }
    @objc func toggle() { defaults.set(!enabled, forKey: "enabled"); enabledItem.state = enabled ? .on : .off; if !enabled { setAlpha(0) } }
    @objc func showSettings() { NSApp.activate(); settings.zone.needsDisplay = true; settings.makeKeyAndOrderFront(nil) }

    @objc func calibratePrompt() {
        let a = NSAlert()
        a.messageText = "calibrate"
        a.informativeText = "sit how you normally do and look at the center of the screen. then press calibrate.\n\nthe screen blurs once you turn away further than the comfort zone and clears when you look back. esc always clears it."
        a.addButton(withTitle: "calibrate")
        NSApp.activate()
        a.runModal()
        recenter()
    }

    func headphoneMotionManagerDidConnect(_ m: CMHeadphoneMotionManager) { status.title = "airpods connected"; recenter() }
    func headphoneMotionManagerDidDisconnect(_ m: CMHeadphoneMotionManager) {
        status.title = "no airpods"; setAlpha(0)
        item.button?.image = NSImage(systemSymbolName: "eyeglasses", accessibilityDescription: "ShyFoss")?.withSymbolConfiguration(.init(paletteColors: [.tertiaryLabelColor]))
    }
}

if CommandLine.arguments.contains("--selftest") {
    assert(coverage(0, comfort: 15, transition: 18) == 0)
    assert(coverage(24, comfort: 15, transition: 18) == 0.5)
    assert(coverage(40, comfort: 15, transition: 18) == 1)
    let id = simd_quatd(angle: 0, axis: SIMD3(0, 0, 1))
    let rot = { (deg: Double, axis: SIMD3<Double>) in simd_quatd(angle: deg * .pi / 180, axis: axis) }
    assert(abs(deviation(id, rot(20, SIMD3(0, 0, 1))) - 20) < 0.01)
    assert(abs(deviation(id, rot(20, SIMD3(1, 0, 0))) - 20) < 0.01)
    assert(deviation(id, rot(20, SIMD3(0, 1, 0))) < 0.01)
    assert(abs(deviation(rot(30, SIMD3(0, 0, 1)), rot(50, SIMD3(0, 0, 1))) - 20) < 0.01)
    assert(abs(offset(id, rot(20, SIMD3(0, 0, 1))).x + 20) < 0.01)
    assert(abs(offset(id, rot(20, SIMD3(1, 0, 0))).y - 20) < 0.01)
    screens = [SIMD2(-30, 0)]
    assert(nearest(SIMD2(-25, 0)).0 == 1 && abs(simd_length(nearest(SIMD2(-25, 0)).1) - 5) < 0.01)
    assert(nearest(SIMD2(-5, 0)).0 == 0)
    screens = []
    print("ok"); exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = App()
app.delegate = delegate
app.run()