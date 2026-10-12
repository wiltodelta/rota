// Drives Rota's UI through the Accessibility API, for scripts/ui-check.sh.
// Synthetic clicks and keystrokes did not reach the app's windows from scripts,
// but AXPress and AXValue do. Usage: swift scripts/ui-driver.swift <command> ...
//
//   tree [depth]                 print roles, titles and identifiers of the windows
//   press <id-or-title>          press the first button with that identifier or title
//   set <id> <text>              set a text field's value
//   value <id>                   print an element's value
//   exists <id-or-title>         exit 0 if an element with that identifier or title exists
//   select <text> [n]            select the nth row (default first) containing that text
//   choose <popup-id> <item>     pick an item from a pop-up button's menu
//   window <title> <w> <h>       move a window to (100, 100) and resize it
//   wid <title>                  print the window number of the window with that title
//   focus <id>                   activate Rota and focus that element
//   key return|option-return     post the key to Rota's process
//   confirm-iterm <text>         answer iTerm2's "OK to run" for a script path containing text
//   gate                         list offscreen windows and clipped or overflowing elements
import AppKit
import ApplicationServices

// The development build by default; ROTA_BUNDLE_ID=com.wiltodelta.rota drives an installed release.
let bundleID = ProcessInfo.processInfo.environment["ROTA_BUNDLE_ID"] ?? "com.wiltodelta.rota.dev"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

// The newest live instance: right after a relaunch the list can still hold the one that just quit.
guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    .filter({ !$0.isTerminated })
    .max(by: { ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast) }) else {
    fail("Rota is not running")
}
let root = AXUIElementCreateApplication(app.processIdentifier)

func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value as? T
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    attribute(element, kAXChildrenAttribute) ?? []
}

func label(_ element: AXUIElement) -> String {
    let parts = [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXIdentifierAttribute]
        .compactMap { (attribute(element, $0) as String?)?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    return parts.joined(separator: " | ")
}

func windows() -> [AXUIElement] {
    attribute(root, kAXWindowsAttribute) ?? []
}

/// Depth-first search over every window, sheets included.
func find(_ match: (AXUIElement) -> Bool) -> AXUIElement? {
    var stack = windows()
    var seen = 0
    while let element = stack.popLast(), seen < 20_000 {
        seen += 1
        if match(element) { return element }
        stack.append(contentsOf: children(element).reversed())
    }
    return nil
}

func matches(_ element: AXUIElement, _ key: String) -> Bool {
    let names = [kAXIdentifierAttribute, kAXTitleAttribute, kAXDescriptionAttribute]
        .compactMap { attribute(element, $0) as String? }
    return names.contains(key)
}

func dump(_ element: AXUIElement, depth: Int, max: Int) {
    guard depth <= max else { return }
    let role: String = attribute(element, kAXRoleAttribute) ?? "?"
    print(String(repeating: "  ", count: depth) + role + "  " + label(element))
    children(element).forEach { dump($0, depth: depth + 1, max: max) }
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "tree":
    let max = arguments.count > 1 ? Int(arguments[1]) ?? 12 : 12
    windows().forEach { dump($0, depth: 0, max: max) }
case "press":
    guard arguments.count == 2 else { fail("press <id-or-title>") }
    guard let button = find({ matches($0, arguments[1]) && (attribute($0, kAXRoleAttribute) as String?) != "AXWindow" })
    else { fail("no element \(arguments[1])") }
    let result = AXUIElementPerformAction(button, kAXPressAction as CFString)
    guard result == .success else { fail("press failed: \(result.rawValue)") }
case "set":
    guard arguments.count == 3 else { fail("set <id> <text>") }
    guard let field = find({ matches($0, arguments[1]) }) else { fail("no element \(arguments[1])") }
    AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    let result = AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, arguments[2] as CFString)
    guard result == .success else { fail("set failed: \(result.rawValue)") }
case "value":
    guard arguments.count == 2, let element = find({ matches($0, arguments[1]) }) else { fail("no element") }
    // A switch or checkbox reports a number, a field a string.
    let value: Any? = attribute(element, kAXValueAttribute)
    print((value as? String) ?? (value as? NSNumber)?.stringValue ?? "")
case "exists":
    guard arguments.count == 2 else { fail("exists <id-or-title>") }
    exit(find({ matches($0, arguments[1]) }) == nil ? 1 : 0)
case "select":
    guard arguments.count >= 2 else { fail("select <text> [nth match, from 1]") }
    let text = arguments[1]
    let nth = arguments.count > 2 ? Int(arguments[2]) ?? 1 : 1
    var rows: [AXUIElement] = []
    _ = find({ element in
        if (attribute(element, kAXRoleAttribute) as String?) == "AXRow",
           find(in: element, first: { label($0).contains(text) }) != nil {
            rows.append(element)
        }
        return false
    })
    guard rows.count >= nth else { fail("\(rows.count) rows contain \(text)") }
    let result = AXUIElementSetAttributeValue(rows[nth - 1], kAXSelectedAttribute as CFString, kCFBooleanTrue)
    guard result == .success else { fail("select failed: \(result.rawValue)") }
case "choose":
    // SwiftUI can redraw the form while its menu is open and drop the pick, so
    // read the value back and try again.
    guard arguments.count == 3 else { fail("choose <popup-id> <item>") }
    for _ in 0..<3 {
        guard let popup = find({ matches($0, arguments[1]) }) else { fail("no element \(arguments[1])") }
        if (attribute(popup, kAXValueAttribute) as String?) == arguments[2] { exit(0) }
        AXUIElementPerformAction(popup, kAXPressAction as CFString)
        Thread.sleep(forTimeInterval: 0.6)
        if let item = find(in: popup, first: { element in
            (attribute(element, kAXRoleAttribute) as String?) == "AXMenuItem"
                && (attribute(element, kAXTitleAttribute) as String?) == arguments[2]
        }) {
            AXUIElementPerformAction(item, kAXPressAction as CFString)
        }
        Thread.sleep(forTimeInterval: 0.6)
    }
    guard let popup = find({ matches($0, arguments[1]) }),
          (attribute(popup, kAXValueAttribute) as String?) == arguments[2] else { fail("could not choose \(arguments[2])") }
case "window":
    guard arguments.count == 4, let width = Double(arguments[2]), let height = Double(arguments[3]),
          let window = windows().first(where: { (attribute($0, kAXTitleAttribute) as String?) == arguments[1] })
    else { fail("window <title> <w> <h>") }
    var origin = CGPoint(x: 100, y: 100)
    var size = CGSize(width: width, height: height)
    AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &origin)!)
    AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &size)!)
case "gate":
    var violations = 0
    for window in windows() {
        guard let windowFrame = frame(window) else { continue }
        let subrole: String = attribute(window, kAXSubroleAttribute) ?? ""
        if subrole == kAXStandardWindowSubrole {
            // AX uses top-left coordinates, AppKit uses bottom-left on the primary screen.
            let desktopTop = NSScreen.screens.first?.frame.maxY ?? 0
            let visibleFrames = NSScreen.screens.map { screen in
                let visible = screen.visibleFrame
                return CGRect(x: visible.minX, y: desktopTop - visible.maxY,
                              width: visible.width, height: visible.height)
            }
            if !visibleFrames.contains(where: { $0.insetBy(dx: -1, dy: -1).contains(windowFrame) }) {
                violations += 1
                print("outside screen  \(label(window))  \(windowFrame)")
            }
        }
        // `clip` is the visible part of the nearest scroll area: content scrolled
        // out of it is not on screen, so it is neither outside the window nor clipped.
        func walk(_ element: AXUIElement, parent: CGRect, clip: CGRect) {
            for child in children(element) {
                guard let rect = frame(child) else { walk(child, parent: parent, clip: clip); continue }
                let role: String = attribute(child, kAXRoleAttribute) ?? "?"
                let visible = rect.width > 0 && rect.height > 0 && rect.intersects(clip)
                let scrolls = role == "AXScrollArea" || role == "AXOutline" || role == "AXTable"
                // An open menu floats over the window by design.
                if role == "AXMenu" { continue }
                if visible && !windowFrame.insetBy(dx: -1, dy: -1).contains(rect.intersection(clip)) {
                    violations += 1
                    print("outside window  \(role)  \(label(child))  \(rect)")
                } else if visible && !scrolls && role != "AXRow" && role != "AXCell"
                            && !parent.insetBy(dx: -1, dy: -1).contains(rect) && parent.width > 0 {
                    violations += 1
                    print("outside parent  \(role)  \(label(child))  \(rect) in \(parent)")
                }
                // A list cell's content sits on the row's inset, a few points past the
                // cell's own frame, so it may pass the cell sideways by that much and no
                // more. Up and down only the list bounds it: a pinned section header
                // floats over the rows while its own row scrolls away.
                let inList = role == "AXCell" || role == "AXRow"
                let next = scrolls ? CGRect.infinite
                    : inList ? CGRect(x: rect.minX - 8, y: -1e6, width: rect.width + 16, height: 2e6) : rect
                walk(child, parent: next, clip: role == "AXScrollArea" ? clip.intersection(rect) : clip)
            }
        }
        // Outside any scroll area nothing is clipped: a control past the window's edge is a defect.
        walk(window, parent: windowFrame, clip: .infinite)
    }
    print("\(violations) violations")
case "key":
    // Keystrokes posted to Rota's process reach its key window even when System
    // Events keystrokes do not. Focus the target first with `focus`.
    guard arguments.count == 2 else { fail("key return|option-return|shift-return|control-return") }
    let modifiers: [String: CGEventFlags] = ["option-return": .maskAlternate, "shift-return": .maskShift,
                                             "control-return": .maskControl]
    let flags = modifiers[arguments[1]] ?? []
    for down in [true, false] {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: down) else { fail("no event") }
        event.flags = flags
        event.postToPid(app.processIdentifier)
        Thread.sleep(forTimeInterval: 0.05)
    }
case "focus":
    guard arguments.count == 2, let element = find({ matches($0, arguments[1]) }) else { fail("focus <id>") }
    app.activate()
    let result = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    guard result == .success else { fail("focus failed: \(result.rawValue)") }
case "confirm-iterm":
    // iTerm2 asks "OK to run <script>?" before running an opened script; answer
    // for scripts whose path contains the text, and leave its setting alone.
    guard arguments.count == 2 else { fail("confirm-iterm <text in the script path>") }
    guard let iTerm = NSRunningApplication.runningApplications(withBundleIdentifier: "com.googlecode.iterm2").first
    else { exit(0) }
    let iTermRoot = AXUIElementCreateApplication(iTerm.processIdentifier)
    for window in attribute(iTermRoot, kAXWindowsAttribute) as [AXUIElement]? ?? [] {
        let parts = children(window)
        guard parts.contains(where: { (attribute($0, kAXValueAttribute) as String?)?.contains(arguments[1]) == true }),
              let ok = parts.first(where: { (attribute($0, kAXTitleAttribute) as String?) == "OK" }) else { continue }
        AXUIElementPerformAction(ok, kAXPressAction as CFString)
        print("confirmed")
    }
case "wid":
    guard arguments.count == 2 else { fail("wid <title>") }
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    guard let entry = list.first(where: {
        ($0[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier
            && ($0[kCGWindowName as String] as? String) == arguments[1]
    }) else { fail("no window \(arguments[1])") }
    print(entry[kCGWindowNumber as String] ?? "")
default:
    fail("usage: tree | press | set | value | exists | select | choose | window | wid | gate | focus | key | confirm-iterm")
}

func frame(_ element: AXUIElement) -> CGRect? {
    guard let positionValue: AXValue = attribute(element, kAXPositionAttribute),
          let sizeValue: AXValue = attribute(element, kAXSizeAttribute) else { return nil }
    var origin = CGPoint.zero
    var size = CGSize.zero
    AXValueGetValue(positionValue, .cgPoint, &origin)
    AXValueGetValue(sizeValue, .cgSize, &size)
    return CGRect(origin: origin, size: size)
}

/// The first descendant of `element` that matches.
func find(in element: AXUIElement, first match: (AXUIElement) -> Bool) -> AXUIElement? {
    var stack = children(element)
    while let next = stack.popLast() {
        if match(next) { return next }
        stack.append(contentsOf: children(next))
    }
    return nil
}

/// Whether any descendant of `element` matches.
func find(in element: AXUIElement, _ match: (AXUIElement) -> Bool) -> Bool {
    var stack = children(element)
    while let next = stack.popLast() {
        if match(next) { return true }
        stack.append(contentsOf: children(next))
    }
    return false
}
