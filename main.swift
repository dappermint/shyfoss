import AppKit
import CoreMotion

let defaults = UserDefaults.standard
let prefs = NSUserDefaultsController.shared
var comfortDeg: Double { defaults.double(forKey: "comfort") }
var transitionDeg: Double { defaults.double(forKey: "transition") }
var strength: Double { defaults.double(forKey: "strength") }

// ponytail: alpha ramp only, no directional gradient. add CAGradientLayer angled by yaw/pitch if wanted
func coverage(_ dev: Double, comfort: Double, transition: Double) -> Double {
    min(1, max(0, (dev - comfort) / transition))
}

final class Overlay: NSWindow {
    var onEscape: (() -> Void)?
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        level = .screenSaver
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
    var ref: CMAttitude?
    var escaped = false
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
        motion.delegate = self
        guard motion.isDeviceMotionAvailable else { status.title = "head tracking unavailable"; return }
        motion.startDeviceMotionUpdates(to: .main) { [self] dm, err in
            guard let dm else { status.title = err?.localizedDescription ?? "no data"; return }
            tick(dm.attitude)
        }
        if !defaults.bool(forKey: "calibrated") { calibratePrompt() }
    }

    func buildMenu() {
        let m = NSMenu()
        m.addItem(status)
        m.addItem(withTitle: "recenter", action: #selector(recenter), keyEquivalent: "r")
        m.addItem(withTitle: "calibrate…", action: #selector(calibratePrompt), keyEquivalent: "")
        enabledItem.state = enabled ? .on : .off
        m.addItem(enabledItem)
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

    func tick(_ att: CMAttitude) {
        guard let ref else { self.ref = att; return }
        let rel = att.copy() as! CMAttitude
        rel.multiply(byInverseOf: ref)
        let dev = (rel.yaw * rel.yaw + rel.pitch * rel.pitch).squareRoot() * 180 / .pi
        status.title = String(format: "off center %.0f°", dev)
        if dev < comfortDeg { escaped = false }
        guard enabled, !escaped else { return }
        setAlpha(coverage(dev, comfort: comfortDeg, transition: transitionDeg) * strength)
    }

    func setAlpha(_ a: Double) {
        for o in overlays {
            o.alphaValue = a
            if a > 0 { if !o.isVisible { o.orderFrontRegardless() }; if a >= strength { o.makeKey() } }
            else if o.isVisible { o.orderOut(nil) }
        }
    }

    @objc func recenter() { ref = nil; escaped = false; setAlpha(0) }
    @objc func toggle() { defaults.set(!enabled, forKey: "enabled"); enabledItem.state = enabled ? .on : .off; if !enabled { setAlpha(0) } }
    @objc func showSettings() { NSApp.activate(); settings.makeKeyAndOrderFront(nil) }

    @objc func calibratePrompt() {
        let a = NSAlert()
        a.messageText = "calibrate"
        a.informativeText = "put on your AirPods, sit how you normally do and look at the center of the screen. then press calibrate.\n\nthe screen blurs once you turn away further than the comfort zone and clears when you look back. esc always clears it."
        a.addButton(withTitle: "calibrate")
        NSApp.activate()
        a.runModal()
        defaults.set(true, forKey: "calibrated")
        recenter()
    }

    func headphoneMotionManagerDidConnect(_ m: CMHeadphoneMotionManager) { status.title = "airpods connected"; recenter() }
    func headphoneMotionManagerDidDisconnect(_ m: CMHeadphoneMotionManager) { status.title = "no airpods"; setAlpha(0) }
}

if CommandLine.arguments.contains("--selftest") {
    assert(coverage(0, comfort: 15, transition: 18) == 0)
    assert(coverage(24, comfort: 15, transition: 18) == 0.5)
    assert(coverage(40, comfort: 15, transition: 18) == 1)
    print("ok"); exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = App()
app.delegate = delegate
app.run()
