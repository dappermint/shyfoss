import AppKit
import CoreMotion
import simd
import Carbon.HIToolbox
import ServiceManagement

let defaults = UserDefaults.standard
let prefs = NSUserDefaultsController.shared
var comfortDeg: Double { defaults.double(forKey: "comfort") }
var transitionDeg: Double { defaults.double(forKey: "transition") }
var strength: Double { defaults.double(forKey: "strength") }

// ponytail: alpha ramp only, no directional gradient. add CAGradientLayer angled by yaw/pitch if wanted
func coverage(_ dev: Double, comfort: Double, transition: Double) -> Double {
    min(1, max(0, (dev - comfort) / transition))
}

func quat(_ q: CMQuaternion) -> simd_quatd { simd_quatd(ix: q.x, iy: q.y, iz: q.z, r: q.w) }

// angle between where the face points now and at calibration; y is forward so head roll is ignored
func deviation(_ ref: simd_quatd, _ cur: simd_quatd) -> Double {
    let fwd = (ref.inverse * cur).act(SIMD3(0, 1, 0))
    return acos(min(1, max(-1, fwd.y))) * 180 / .pi
}

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

final class SettingsWindow: NSWindow {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 360, height: 140), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        title = "ShyFoss"
        isReleasedWhenClosed = false
        let grid = NSGridView(views: [
            row("comfort zone", key: "comfort", min: 2, max: 30, digits: 0, unit: "°"),
            row("fade distance", key: "transition", min: 5, max: 30, digits: 0, unit: "°"),
            row("blur strength", key: "strength", min: 0.3, max: 1, digits: 2, unit: ""),
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 12
        grid.translatesAutoresizingMaskIntoConstraints = false
        contentView!.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.centerXAnchor.constraint(equalTo: contentView!.centerXAnchor),
            grid.centerYAnchor.constraint(equalTo: contentView!.centerYAnchor),
        ])
        center()
    }

    func row(_ title: String, key: String, min: Double, max: Double, digits: Int, unit: String) -> [NSView] {
        let slider = NSSlider(value: 0, minValue: min, maxValue: max, target: nil, action: nil)
        slider.widthAnchor.constraint(equalToConstant: 160).isActive = true
        slider.isContinuous = true
        slider.bind(.value, to: prefs, withKeyPath: "values.\(key)")
        let value = NSTextField(labelWithString: "")
        value.widthAnchor.constraint(equalToConstant: 44).isActive = true
        let f = NumberFormatter()
        f.maximumFractionDigits = digits
        f.positiveSuffix = unit
        value.formatter = f
        value.bind(.value, to: prefs, withKeyPath: "values.\(key)")
        return [NSTextField(labelWithString: title), slider, value]
    }
}

final class App: NSObject, NSApplicationDelegate, CMHeadphoneMotionManagerDelegate {
    let motion = CMHeadphoneMotionManager()
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var overlays: [Overlay] = []
    var refs: [simd_quatd] = []
    var lastStamp = 0.0
    var lastSeen = Date.distantPast
    var escaped = false
    var stolenFrom: NSRunningApplication?
    let status = NSMenuItem(title: "no airpods", action: nil, keyEquivalent: "")
    let enabledItem = NSMenuItem(title: "enabled", action: #selector(toggle), keyEquivalent: "")
    lazy var settings = SettingsWindow()
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
        m.addItem(withTitle: "add another screen here", action: #selector(addCenter), keyEquivalent: "")
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
        guard !refs.isEmpty else { refs = [att]; return }
        let (i, dev) = refs.enumerated().map { ($0, deviation($1, att)) }.min { $0.1 < $1.1 }!
        status.title = String(format: "off center %.0f°", dev)
        if dev < comfortDeg {
            escaped = false
            // yaw drifts without a magnetometer; follow it at 0.5°/s but only while looking at the screen
            if dev > 0.01, dt > 0, dt < 1 { refs[i] = simd_slerp(refs[i], att, min(1, 0.5 * dt / dev)) }
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

    @objc func recenter() { refs = []; escaped = false; setAlpha(0) }
    @objc func addCenter() { if let cur = motion.deviceMotion { refs.append(quat(cur.attitude.quaternion)) } }
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
    @objc func showSettings() { NSApp.activate(); settings.makeKeyAndOrderFront(nil) }

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
    print("ok"); exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = App()
app.delegate = delegate
app.run()
