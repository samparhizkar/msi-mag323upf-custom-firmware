// whitematch: match the MSI's white point to the MacBook screen by eye.
// Shows the same grey patch on both screens and adjusts the MSI's RGB gains over DDC.
//   R / G / B   select channel      Up / Down   adjust gain by 1
//   1-9         patch level 10-90%  0           100% white
//   U           undo all changes    Esc / Q / Cmd-Q / close window   quit (keeps the current gains)
import AppKit

let svc: IOAVServiceRef = {
    guard let s = externalAVService() else { print("MSI not reachable over DDC"); exit(1) }
    return s
}()
let gainCodes: [UInt8] = [0x16, 0x18, 0x1A]   // red, green, blue video gain
var gains: [UInt16] = []
var maxGain: UInt16 = 100
// Read each gain until two consecutive reads agree, so a garbled DDC reply can't become the baseline.
for code in gainCodes {
    var stable: (UInt16, UInt16)? = nil
    var last: (UInt16, UInt16)? = nil
    for _ in 0..<8 {
        let r = getVCP(svc, code)
        if let r = r, let l = last, r == l { stable = r; break }
        last = r
        usleep(100_000)
    }
    guard let (cur, mx) = stable else { print("cannot get a stable reading for gain \(code)"); exit(1) }
    gains.append(cur); maxGain = mx
}
let original = gains
// Keep the white point within a sane window around neutral (50) so a slip can't tint the screen badly.
let minAllowed = 35, maxAllowed = 65
setvbuf(stdout, nil, _IOLBF, 0)   // line-buffered, so every change is logged even if the tool is killed
print("start gains R/G/B = \(gains) (max \(maxGain))")

final class PatchView: NSView {
    var level: CGFloat = 0.8
    let text = NSTextField(labelWithString: "")
    override init(frame: NSRect) {
        super.init(frame: frame)
        text.textColor = .gray
        text.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        text.frame = NSRect(x: 12, y: 8, width: frame.width - 24, height: 20)
        addSubview(text)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var acceptsFirstResponder: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill(); bounds.fill()
        // centre patch, sRGB-tagged grey so both screens get the same value through colour management
        let r = bounds.insetBy(dx: bounds.width * 0.2, dy: bounds.height * 0.2)
        NSColor(srgbRed: level, green: level, blue: level, alpha: 1).setFill(); r.fill()
    }
    override func keyDown(with e: NSEvent) { Controller.shared.key(e) }
}

final class Controller {
    static let shared = Controller()
    var views: [PatchView] = []
    var channel = 0
    var level: CGFloat = 0.8

    func refresh() {
        let names = ["R", "G", "B"]
        let gs = (0..<3).map { i in i == channel ? "[\(names[i]) \(gains[i])]" : "\(names[i]) \(gains[i])" }.joined(separator: "  ")
        let text = "\(gs)   patch \(Int(level * 100))%   R/G/B select, Up/Down adjust, 0-9 level, U undo, Esc quit"
        for v in views { v.level = level; v.text.stringValue = text; v.needsDisplay = true }
    }

    func key(_ e: NSEvent) {
        switch e.keyCode {
        case 126, 125:   // up, down: one step per press, held keys are ignored
            if e.isARepeat { return }
            let step: Int = e.keyCode == 126 ? 1 : -1
            let v = max(minAllowed, min(maxAllowed, Int(gains[channel]) + step))
            gains[channel] = UInt16(v)
            setVCP(svc, gainCodes[channel], gains[channel])
            print("gains R/G/B = \(gains)")
        case 53: quit()
        default:
            switch e.charactersIgnoringModifiers?.lowercased() ?? "" {
            case "r": channel = 0
            case "g": channel = 1
            case "b": channel = 2
            case "q": quit()
            case "u":
                gains = original
                for i in 0..<3 { setVCP(svc, gainCodes[i], gains[i]) }
            case let c where c.count == 1 && "0123456789".contains(c):
                let d = CGFloat(Int(c)!)
                level = d == 0 ? 1.0 : d / 10
            default: break
            }
        }
        refresh()
    }

    var quitting = false
    func quit() {
        if quitting { return }
        quitting = true
        print("final gains R/G/B = \(gains)  (start was \(original))")
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
// A normal, closable window on each screen (Cmd-Q or closing any window quits).
// contentRect is relative to the target screen because the screen is passed explicitly.
final class Delegate: NSObject, NSWindowDelegate, NSApplicationDelegate {
    func windowWillClose(_ notification: Notification) { Controller.shared.quit() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
let delegate = Delegate()
app.delegate = delegate
for screen in NSScreen.screens {
    let vf = screen.visibleFrame
    let size = NSSize(width: vf.width * 0.6, height: vf.height * 0.6)
    let local = NSRect(x: (vf.minX - screen.frame.minX) + (vf.width - size.width) / 2,
                       y: (vf.minY - screen.frame.minY) + (vf.height - size.height) / 2,
                       width: size.width, height: size.height)
    let w = NSWindow(contentRect: local, styleMask: [.titled, .closable], backing: .buffered, defer: false, screen: screen)
    w.title = "whitematch — \(screen.localizedName)"
    w.delegate = delegate
    let v = PatchView(frame: NSRect(origin: .zero, size: size))
    w.contentView = v
    w.makeFirstResponder(v)
    w.makeKeyAndOrderFront(nil)
    Controller.shared.views.append(v)
}
Controller.shared.refresh()
// Finish on our own after 8 minutes, keeping the current gains.
Timer.scheduledTimer(withTimeInterval: 8 * 60, repeats: false) { _ in Controller.shared.quit() }
app.activate(ignoringOtherApps: true)
app.run()
