// Drives Rota's UI through the Accessibility API, for scripts/ui-check.sh.
// Synthetic clicks and keystrokes did not reach the app's windows from scripts,
// but AXPress and AXValue do. Usage: swift scripts/ui-driver.swift <command> ...
//
//   tree [depth]                 print roles, titles and identifiers of the windows
//   menu <title>                invoke an app menu item by its title
//   press <id-or-title>          press the first button with that identifier or title
//   set <id> <value>             set a text field or numeric slider value
//   value <id>                   print an element's value
//   enabled <id>                 print whether a control is enabled
//   visible <id-or-title>       require full visibility inside the window and scroll viewport
//   in-toolbar <id>             require an element to remain inside the title-bar toolbar
//   text-count <value>          count static text elements with that exact value
//   bounds <id-or-title>        print x y width height in screen points
//   exists <id-or-title>         exit 0 if an element with that identifier or title exists
//   select <text> [n]            select the nth row (default first) containing that text
//   choose <popup-id> <item>     pick an item from a pop-up button's menu
//   window <title> <w> <h>       move a window to (100, 100) and resize it
//   wid <title>                  print the window number of the window with that title
//   focus <id>                   activate Rota and focus that element
//   reveal <id-or-title>         scroll the nearest enclosing area to that element
//   aligned <label> <control>    check that their vertical frame centers agree
//   key <key>                   post Return, a zoom shortcut or Command-W to Rota's process
//   scroll-wheel <window-or-content> <delta> <pixel|line>  send real scroll input over that viewport
//   confirm-iterm <text>         answer iTerm2's "OK to run" for a script path containing text
//   gate                         list elements whose frame leaves their window or their parent
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

// Target a scroll area's viewport even when its child is currently scrolled out.
func wheelTarget(_ text: String) -> (AXUIElement, CGRect)? {
    guard let target = windows().first(where: { matches($0, text) }) ?? find({ matches($0, text) }) else { return nil }
    var ancestor: AXUIElement? = target
    var viewport: CGRect?
    while let element = ancestor {
        let role: String = attribute(element, kAXRoleAttribute) ?? ""
        if role == "AXScrollArea", viewport == nil { viewport = frame(element) }
        if role == "AXWindow", let rect = viewport ?? frame(element) { return (element, rect) }
        ancestor = attribute(element, kAXParentAttribute)
    }
    return nil
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "tree":
    let max = arguments.count > 1 ? Int(arguments[1]) ?? 12 : 12
    windows().forEach { dump($0, depth: 0, max: max) }
case "menu":
    guard arguments.count == 2,
          let bar: AXUIElement = attribute(root, kAXMenuBarAttribute),
          let item = find(in: bar, first: { matches($0, arguments[1]) }) else { fail("no menu item") }
    let result = AXUIElementPerformAction(item, kAXPressAction as CFString)
    guard result == .success else { fail("menu action failed: \(result.rawValue)") }
case "press":
    guard arguments.count == 2 else { fail("press <id-or-title>") }
    guard let button = find({ matches($0, arguments[1]) && (attribute($0, kAXRoleAttribute) as String?) != "AXWindow" })
    else { fail("no element \(arguments[1])") }
    let result = AXUIElementPerformAction(button, kAXPressAction as CFString)
    guard result == .success else { fail("press failed: \(result.rawValue)") }
case "set":
    guard arguments.count == 3 else { fail("set <id> <value>") }
    guard let field = find({ matches($0, arguments[1]) }) else { fail("no element \(arguments[1])") }
    AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    let value: CFTypeRef
    if (attribute(field, kAXRoleAttribute) as String?) == "AXSlider" {
        guard let number = Double(arguments[2]) else { fail("slider value must be numeric") }
        value = NSNumber(value: number)
    } else {
        value = arguments[2] as CFString
    }
    let result = AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, value)
    guard result == .success else { fail("set failed: \(result.rawValue)") }
case "value":
    guard arguments.count == 2, let element = find({ matches($0, arguments[1]) }) else { fail("no element") }
    // A switch or checkbox reports a number, a field a string.
    let value: Any? = attribute(element, kAXValueAttribute)
    print((value as? String) ?? (value as? NSNumber)?.stringValue ?? "")
case "enabled":
    guard arguments.count == 2, let element = find({ matches($0, arguments[1]) }) else { fail("no element") }
    print((attribute(element, kAXEnabledAttribute) as Bool?) == true ? "true" : "false")
case "exists":
    guard arguments.count == 2 else { fail("exists <id-or-title>") }
    exit(find({ matches($0, arguments[1]) }) == nil ? 1 : 0)
case "in-toolbar":
    guard arguments.count == 2, let element = find({ matches($0, arguments[1]) }) else { fail("no element") }
    var parent: AXUIElement? = attribute(element, kAXParentAttribute)
    while let current = parent {
        if (attribute(current, kAXRoleAttribute) as String?) == "AXToolbar" { exit(0) }
        parent = attribute(current, kAXParentAttribute)
    }
    fail("element is outside the title-bar toolbar")
case "text-count":
    guard arguments.count == 2 else { fail("text-count <value>") }
    var count = 0
    _ = find({ element in
        if (attribute(element, kAXRoleAttribute) as String?) == "AXStaticText",
           (attribute(element, kAXValueAttribute) as String?) == arguments[1] { count += 1 }
        return false
    })
    print(count)
case "bounds", "visible":
    guard arguments.count == 2, let element = find({
        matches($0, arguments[1]) || (attribute($0, kAXValueAttribute) as String?) == arguments[1]
    }),
          let rect = frame(element) else { fail("no element frame") }
    if arguments.first == "bounds" {
        print("\(rect.minX) \(rect.minY) \(rect.width) \(rect.height)")
    } else {
        var parent: AXUIElement? = attribute(element, kAXParentAttribute)
        while let current = parent {
            let role: String = attribute(current, kAXRoleAttribute) ?? ""
            if role == "AXScrollArea" || role == "AXWindow", let viewport = frame(current),
               !viewport.insetBy(dx: -0.5, dy: -0.5).contains(rect) {
                fail("element is outside its visible viewport: \(arguments[1])")
            }
            parent = attribute(current, kAXParentAttribute)
        }
    }
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
    // A native popup's AXPress can open an inactive menu without selecting its
    // item. Make the development app active before entering menu tracking.
    app.activate()
    AXUIElementSetAttributeValue(root, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    for _ in 0..<20 {
        if (attribute(root, kAXFrontmostAttribute) as Bool?) == true { break }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    guard (attribute(root, kAXFrontmostAttribute) as Bool?) == true else {
        fail("Rota did not become active")
    }
    for _ in 0..<3 {
        guard let popup = find({ matches($0, arguments[1]) }) else { fail("no element \(arguments[1])") }
        if (attribute(popup, kAXValueAttribute) as String?) == arguments[2] { exit(0) }
        AXUIElementSetAttributeValue(popup, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        let opened = AXUIElementPerformAction(popup, kAXPressAction as CFString)
        guard opened == .success else { fail("popup press failed: \(opened.rawValue)") }
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
case "aligned":
    func alignmentFrame(_ key: String, textOnly: Bool = false) -> CGRect? {
        guard let element = find({
            let isText = (attribute($0, kAXRoleAttribute) as String?) == "AXStaticText"
            if textOnly && !isText { return false }
            return matches($0, key) || (isText
                && (attribute($0, kAXValueAttribute) as String?) == key)
        }) else { return nil }
        return frame(element)
    }
    guard arguments.count == 3, let label = alignmentFrame(arguments[1], textOnly: true),
          let control = alignmentFrame(arguments[2]) else { fail("aligned <label> <control>") }
    let difference = abs(label.midY - control.midY)
    guard difference <= 0.75 else { fail("vertical centers differ by \(difference) pt") }
case "scroll-horizontal":
    guard arguments.count == 2, let target = find({ matches($0, arguments[1]) }),
          let bar = children(target).first(where: {
              (attribute($0, kAXRoleAttribute) as String?) == "AXScrollBar"
                  && (attribute($0, kAXOrientationAttribute) as String?) == "AXHorizontalOrientation"
          }) else { fail("no horizontal scrollbar") }
    guard AXUIElementSetAttributeValue(bar, kAXValueAttribute as CFString, 1 as CFNumber) == .success
        else { fail("horizontal scroll failed") }
case "reveal":
    guard arguments.count == 2, let target = find({ matches($0, arguments[1]) }),
          let targetFrame = frame(target) else { fail("reveal <id-or-title>") }
    var element = target
    var foundScrollArea = false
    while let parent: AXUIElement = attribute(element, kAXParentAttribute) {
        element = parent
        guard (attribute(parent, kAXRoleAttribute) as String?) == "AXScrollArea",
              let viewport = frame(parent) else { continue }
        foundScrollArea = true
        // A Form exposes an inner scroll area as tall as its natural content.
        // Its outer viewport may still clip a target that fits this inner area.
        if viewport.contains(targetFrame) { continue }
        let contents = children(parent)
        // SwiftUI can expose a flattened document, with each field as a child.
        // Its extent is their union, not the height of the largest control.
        let document = contents.filter { (attribute($0, kAXRoleAttribute) as String?) != "AXScrollBar" }
            .compactMap { frame($0) }.reduce(CGRect.null) { $0.union($1) }
        guard let bar = contents.first(where: {
            (attribute($0, kAXRoleAttribute) as String?) == "AXScrollBar"
                && (frame($0).map { $0.height > $0.width } ?? false)
        }), !document.isNull, document.height > viewport.height else { fail("no vertical scroll range") }
        let offset = targetFrame.midY - document.minY - viewport.height / 2
        let fraction = min(max(offset / (document.height - viewport.height), 0), 1)
        let result = AXUIElementSetAttributeValue(bar, kAXValueAttribute as CFString, fraction as CFNumber)
        guard result == .success else { fail("scroll failed: \(result.rawValue)") }
        exit(0)
    }
    guard foundScrollArea else { fail("no enclosing scroll area") }
case "gate":
    var violations = 0
    let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
    let visibleScreens = NSScreen.screens.map { screen in
        let visible = screen.visibleFrame
        return CGRect(x: visible.minX, y: primaryTop - visible.maxY,
                      width: visible.width, height: visible.height)
    }
    for window in windows() {
        guard let windowFrame = frame(window) else { continue }
        if !visibleScreens.contains(where: { $0.insetBy(dx: -1, dy: -1).contains(windowFrame) }) {
            violations += 1
            print("outside visible screen  \(label(window))  \(windowFrame)")
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
case "scroll-wheel":
    guard arguments.count == 4, let delta = Int32(arguments[2]), delta != 0,
          ["pixel", "line"].contains(arguments[3]),
          let (window, rect) = wheelTarget(arguments[1]) else {
        fail("scroll-wheel <window-or-scroll-content> <nonzero delta> <pixel|line>")
    }
    let continuous = arguments[3] == "pixel"
    let units: CGScrollEventUnit = continuous ? .pixel : .line
    let point = CGPoint(x: rect.midX, y: rect.midY)
    let step: Int32 = (continuous ? 120 : 8) * (delta > 0 ? 1 : -1)
    var remaining = delta
    var first = true
    app.activate()
    guard AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success else { fail("cannot raise window") }
    Thread.sleep(forTimeInterval: 0.1)
    let previous = CGEvent(source: nil)?.location
    guard let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                             mouseCursorPosition: point, mouseButton: .left) else { fail("no pointer event") }
    move.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.1)
    defer {
        if let previous, let restore = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                               mouseCursorPosition: previous, mouseButton: .left) {
            restore.post(tap: .cghidEventTap)
        }
    }
    while remaining != 0 {
        let amount = abs(remaining) < abs(step) ? remaining : step
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: units, wheelCount: 1,
                                  wheel1: amount, wheel2: 0, wheel3: 0) else { fail("no scroll event") }
        event.location = point
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: continuous ? 1 : 0)
        if continuous {
            let phase: CGScrollPhase = first ? .began : .changed
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
        }
        event.post(tap: .cghidEventTap)
        remaining -= amount
        first = false
        Thread.sleep(forTimeInterval: 0.03)
    }
    if continuous, let end = CGEvent(scrollWheelEvent2Source: nil, units: units, wheelCount: 1,
                                   wheel1: 0, wheel2: 0, wheel3: 0) {
        end.location = point
        end.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        end.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(CGScrollPhase.ended.rawValue))
        end.post(tap: .cghidEventTap)
    }
case "key":
    // Keystrokes posted to Rota's process reach its key window even when System
    // Events keystrokes do not. Focus the target first with `focus`.
    let keys: [String: (CGKeyCode, CGEventFlags)] = [
        "return": (36, []), "option-return": (36, .maskAlternate),
        "shift-return": (36, .maskShift), "control-return": (36, .maskControl),
        "command-zero": (29, .maskCommand), "command-plus": (24, [.maskCommand, .maskShift]),
        "command-minus": (27, .maskCommand), "command-w": (13, .maskCommand),
        "option-command-plus": (24, [.maskCommand, .maskAlternate, .maskShift]),
        "option-command-minus": (27, [.maskCommand, .maskAlternate]),
        "option-command-zero": (29, [.maskCommand, .maskAlternate])
    ]
    guard arguments.count == 2, let (code, flags) = keys[arguments[1]] else { fail("unknown key") }
    app.activate()
    Thread.sleep(forTimeInterval: 0.1)
    for down in [true, false] {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { fail("no event") }
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
        let bounds = $0[kCGWindowBounds as String] as? [String: Double]
        return ($0[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier
            && ($0[kCGWindowName as String] as? String) == arguments[1]
            && (bounds?["Height"] ?? 0) > 40
    }) else { fail("no window \(arguments[1])") }
    print(entry[kCGWindowNumber as String] ?? "")
default:
    fail("usage: tree | menu | press | set | value | exists | visible | bounds | text-count | in-toolbar | select | choose | window | wid | gate | focus | reveal | scroll-horizontal | scroll-wheel | aligned | key | confirm-iterm")
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
