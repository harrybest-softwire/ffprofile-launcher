import Cocoa
import ApplicationServices
import Darwin

struct Profile {
    let name: String
    let path: String
    let isDefault: Bool
}

// MARK: - Profile parsing

func parseProfiles() throws -> [Profile] {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let iniPath = home.appendingPathComponent("Library/Application Support/Firefox/profiles.ini").path

    let contents = try String(contentsOfFile: iniPath, encoding: .utf8)
    var profiles: [Profile] = []
    var name: String?
    var path: String?
    var isDefault = false
    var inProfileSection = false

    for line in contents.components(separatedBy: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        if trimmed.hasPrefix("[") {
            if inProfileSection, let n = name, let p = path {
                profiles.append(Profile(name: n, path: p, isDefault: isDefault))
            }
            name = nil; path = nil; isDefault = false
            inProfileSection = trimmed.hasPrefix("[Profile")
            continue
        }

        guard inProfileSection else { continue }
        guard let eqIdx = trimmed.firstIndex(of: "=") else { continue }
        let key = String(trimmed[trimmed.startIndex..<eqIdx])
        let val = String(trimmed[trimmed.index(after: eqIdx)...])

        switch key {
        case "Name": name = val
        case "Path": path = val
        case "Default": isDefault = val == "1"
        default: break
        }
    }

    if inProfileSection, let n = name, let p = path {
        profiles.append(Profile(name: n, path: p, isDefault: isDefault))
    }

    return profiles
}

// MARK: - Listing

func listProfiles(_ profiles: [Profile]) {
    for p in profiles {
        let marker = p.isDefault ? "* " : "  "
        print("\(marker)\(p.name)")
    }
}

// MARK: - Matching

func fuzzyMatch(_ input: String, _ candidate: String) -> Bool {
    let input = input.lowercased()
    let candidate = candidate.lowercased()
    var i = input.startIndex
    for ch in candidate {
        guard i < input.endIndex else { break }
        if ch == input[i] {
            i = input.index(after: i)
        }
    }
    return i == input.endIndex
}

func matchProfile(_ profiles: [Profile], _ input: String) -> (matches: [Profile], method: String) {
    let lower = input.lowercased()

    // Exact
    let exact = profiles.filter { $0.name.lowercased() == lower }
    if !exact.isEmpty { return (exact, "exact") }

    // Prefix
    let prefix = profiles.filter { $0.name.lowercased().hasPrefix(lower) }
    if !prefix.isEmpty { return (prefix, "prefix") }

    // Substring
    let substring = profiles.filter { $0.name.lowercased().contains(lower) }
    if !substring.isEmpty { return (substring, "substring") }

    // Fuzzy
    let fuzzy = profiles.filter { fuzzyMatch(input, $0.name) }
    return (fuzzy, "fuzzy")
}

// MARK: - Find running profile

func getProcessArgs(_ pid: pid_t) -> String? {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size: Int = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buf = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return nil }
    return String(buf.prefix(size).map { Character(UnicodeScalar($0 == 0 ? UInt8(0x20) : $0)) })
}

func allPids() -> [kinfo_proc] {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
    var size: Int = 0
    sysctl(&mib, 4, nil, &size, nil, 0)
    var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.size)
    sysctl(&mib, 4, &procs, &size, nil, 0)
    return procs
}

func findRunningProfile(_ profilePath: String, name profileName: String) -> pid_t? {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let fullPath = "\(home)/Library/Application Support/Firefox/\(profilePath)"

    let firefoxPids = Set(
        NSWorkspace.shared.runningApplications
            .filter { $0.localizedName == "Firefox" }
            .map { $0.processIdentifier }
    )
    guard !firefoxPids.isEmpty else { return nil }

    let target = "-profile \(fullPath)"

    // Fast path: check main Firefox process args directly (1 sysctl per instance).
    for pid in firefoxPids {
        guard let args = getProcessArgs(pid) else { continue }
        if args.contains(target) || args.contains("-P \(profileName)") {
            return pid
        }
    }

    // Slow path: scan child processes for -profile/-parentPid args.
    // Needed when the main process args don't expose the profile directly.
    for kp in allPids() {
        let ppid = kp.kp_eproc.e_ppid
        guard firefoxPids.contains(ppid) else { continue }

        let childPid = kp.kp_proc.p_pid
        guard let args = getProcessArgs(childPid),
              args.contains(target),
              let parentRange = args.range(of: "-parentPid ") else { continue }

        let rest = args[parentRange.upperBound...]
        let pidStr = rest.prefix(while: { $0.isNumber })
        if let pid = pid_t(pidStr), pid > 0 {
            return pid
        }
    }

    return nil
}

// MARK: - Focus

func windowCount(_ pid: pid_t) -> Int {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return 0 }
    return list.filter {
        ($0[kCGWindowOwnerPID as String] as? Int32) == pid
            && ($0[kCGWindowLayer as String] as? Int) == 0
    }.count
}

func focusProcess(_ pid: pid_t) {
    let axApp = AXUIElementCreateApplication(pid)
    var windowsRef: CFTypeRef?
    let err = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef)
    if err == .success, let windows = windowsRef as? [AXUIElement] {
        for window in windows {
            var minRef: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minRef)
            if let minimized = minRef as? Bool, minimized {
                AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, false as CFTypeRef)
            }
        }
    }

    if let app = NSRunningApplication(processIdentifier: pid) {
        app.activate()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
    }
}

// MARK: - Launch

func openURLViaAppleEvent(_ pid: pid_t, _ url: String) {
    // Send a GURL/GURL (GetURL) Apple Event directly to the target PID.
    // This is exactly what `open -a Firefox url` does internally, but
    // targeting by PID ensures it lands in the right profile instance.
    let target = NSAppleEventDescriptor(processIdentifier: pid)
    let event = NSAppleEventDescriptor(
        eventClass: AEEventClass(0x4755524C), // 'GURL'
        eventID: AEEventID(0x4755524C),       // 'GURL'
        targetDescriptor: target,
        returnID: Int16(kAutoGenerateReturnID),
        transactionID: Int32(kAnyTransactionID)
    )
    event.setParam(NSAppleEventDescriptor(string: url), forKeyword: AEKeyword(keyDirectObject))
    do {
        try event.sendEvent(options: .noReply, timeout: 30)
    } catch {
        fputs("warning: couldn't send URL event: \(error)\n", stderr)
    }
}

func launchProfile(_ profile: Profile, url: String? = nil) {
    if let pid = findRunningProfile(profile.path, name: profile.name) {
        let wc = windowCount(pid)
        fputs("profile \"\(profile.name)\" running (pid \(pid)), \(wc) windows\n", stderr)
        if wc > 0 {
            focusProcess(pid)
            if let url = url {
                openURLViaAppleEvent(pid, url)
            }
            return
        }
    }

    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/Applications/Firefox.app/Contents/MacOS/firefox")
    var arguments = ["-P", profile.name, "-no-remote", "-new-window"]
    if let url { arguments.append(url) }
    proc.arguments = arguments
    do { try proc.run() } catch {
        fputs("error launching Firefox: \(error)\n", stderr)
        exit(1)
    }
}

// MARK: - Icon generation

let iconColors: [(CGFloat, CGFloat, CGFloat)] = [
    (0.91, 0.30, 0.24),  // red
    (0.16, 0.50, 0.73),  // blue
    (0.15, 0.68, 0.38),  // green
    (0.56, 0.27, 0.68),  // purple
    (0.90, 0.49, 0.13),  // orange
    (0.20, 0.60, 0.86),  // light blue
    (0.83, 0.18, 0.42),  // pink
    (0.10, 0.74, 0.61),  // teal
]

func colorForProfile(_ name: String) -> (CGFloat, CGFloat, CGFloat) {
    var hash: UInt = 5381
    for c in name.unicodeScalars { hash = hash &* 33 &+ UInt(c.value) }
    return iconColors[Int(hash % UInt(iconColors.count))]
}

func generateIcon(_ name: String) -> Data? {
    let size = 512
    let scale = 2
    let px = size * scale
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }

    ctx.clear(CGRect(x: 0, y: 0, width: px, height: px))

    let s = CGFloat(px)
    let (r, g, b) = colorForProfile(name)

    // Profile initial squircle (top-left, ~82% of canvas)
    let mainSize = s * 0.82
    let mainRadius = mainSize * 0.22
    let mainRect = CGRect(x: 0, y: s - mainSize, width: mainSize, height: mainSize)
    let mainPath = CGPath(roundedRect: mainRect, cornerWidth: mainRadius, cornerHeight: mainRadius, transform: nil)
    ctx.setFillColor(CGColor(red: r, green: g, blue: b, alpha: 1))
    ctx.addPath(mainPath)
    ctx.fillPath()

    // Subtle globe
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.15))
    let globeSize = mainSize * 0.55
    let globeRect = CGRect(x: (mainSize - globeSize) / 2, y: s - mainSize + mainSize * 0.32, width: globeSize, height: globeSize)
    ctx.fillEllipse(in: globeRect)

    // Initial letter
    let initial = String(name.prefix(1)).uppercased()
    let font = CTFontCreateWithName("Helvetica Neue Bold" as CFString, mainSize * 0.45, nil)
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: CGColor(red: 1, green: 1, blue: 1, alpha: 1),
    ]
    let str = NSAttributedString(string: initial, attributes: attrs)
    let line = CTLineCreateWithAttributedString(str)
    let bounds = CTLineGetBoundsWithOptions(line, [])
    let x = (mainSize - bounds.width) / 2 - bounds.origin.x
    let y = s - mainSize + (mainSize - bounds.height) / 2 - bounds.origin.y
    ctx.textPosition = CGPoint(x: x, y: y)
    CTLineDraw(line, ctx)

    // Firefox icon (bottom-right, overlapping the main squircle)
    let firefoxIconPath = "/Applications/Firefox.app/Contents/Resources/firefox.icns"
    if let iconData = NSData(contentsOfFile: firefoxIconPath),
       let iconImage = NSImage(data: iconData as Data) {
        let badgeSize = s * 0.62
        let badgeRect = CGRect(x: s - badgeSize, y: 0, width: badgeSize, height: badgeSize)

        if let cgIcon = iconImage.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            ctx.draw(cgIcon, in: badgeRect)
        }
    }

    guard let image = ctx.makeImage() else { return nil }
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: size, height: size)
    return rep.representation(using: .png, properties: [:])
}

func createIcns(_ name: String, at path: URL) throws {
    guard let pngData = generateIcon(name) else { return }
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let iconsetDir = tmpDir.appendingPathComponent("icon.iconset")
    try FileManager.default.createDirectory(at: iconsetDir, withIntermediateDirectories: true)
    try pngData.write(to: iconsetDir.appendingPathComponent("icon_512x512@2x.png"))
    try pngData.write(to: iconsetDir.appendingPathComponent("icon_512x512.png"))
    try pngData.write(to: iconsetDir.appendingPathComponent("icon_256x256@2x.png"))
    try pngData.write(to: iconsetDir.appendingPathComponent("icon_256x256.png"))
    try pngData.write(to: iconsetDir.appendingPathComponent("icon_128x128@2x.png"))
    try pngData.write(to: iconsetDir.appendingPathComponent("icon_128x128.png"))

    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    proc.arguments = ["-c", "icns", "-o", path.path, iconsetDir.path]
    try proc.run()
    proc.waitUntilExit()
    try? FileManager.default.removeItem(at: tmpDir)
}

// MARK: - Install

func installApps() throws {
    let profiles = try parseProfiles()
    let fm = FileManager.default
    let appsDir = fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
    let ffprofilePath = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path

    try fm.createDirectory(at: appsDir, withIntermediateDirectories: true)

    for profile in profiles {
        let appName = "\(profile.name) - Firefox.app"
        let appDir = appsDir.appendingPathComponent(appName)
        let contentsDir = appDir.appendingPathComponent("Contents")
        let macosDir = contentsDir.appendingPathComponent("MacOS")

        try fm.createDirectory(at: macosDir, withIntermediateDirectories: true)

        let resourcesDir = contentsDir.appendingPathComponent("Resources")
        try fm.createDirectory(at: resourcesDir, withIntermediateDirectories: true)
        try createIcns(profile.name, at: resourcesDir.appendingPathComponent("AppIcon.icns"))

        let bundleId = "com.ffprofile.\(profile.name.lowercased().replacingOccurrences(of: " ", with: "-"))"
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleName</key>
            <string>\(profile.name) - Firefox</string>
            <key>CFBundleIdentifier</key>
            <string>\(bundleId)</string>
            <key>CFBundleExecutable</key>
            <string>run</string>
            <key>CFBundleIconFile</key>
            <string>AppIcon</string>
            <key>LSUIElement</key>
            <true/>
            <key>LSHasLocalizedDisplayName</key>
            <false/>
            <key>NSHumanReadableCopyright</key>
            <string>ff firefox \(profile.name) browser profile</string>
        </dict>
        </plist>
        """
        try plist.write(to: contentsDir.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)

        let script = """
        #!/bin/sh
        exec "\(ffprofilePath)" launch "\(profile.name)"
        """
        let runPath = macosDir.appendingPathComponent("run")
        try script.write(to: runPath, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runPath.path)

        print("installed \(appName)")
    }
}

// MARK: - Uninstall

func uninstallApps() throws {
    let profiles = try parseProfiles()
    let fm = FileManager.default
    let appsDir = fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications")

    for profile in profiles {
        let appName = "\(profile.name) - Firefox.app"
        let appPath = appsDir.appendingPathComponent(appName)
        if fm.fileExists(atPath: appPath.path) {
            try fm.removeItem(at: appPath)
            print("removed \(appName)")
        }
    }
}

// MARK: - Main

func usage() {
    fputs("Usage:\n", stderr)
    fputs("  ffprofile list              List available profiles\n", stderr)
    fputs("  ffprofile launch <profile>  Launch a profile (pipe a URL to open it)\n", stderr)
    fputs("  ffprofile install           Install Spotlight apps\n", stderr)
    fputs("  ffprofile uninstall         Remove Spotlight apps\n", stderr)
}

let args = CommandLine.arguments

guard args.count >= 2 else {
    usage()
    exit(1)
}

switch args[1] {
case "list":
    do {
        let profiles = try parseProfiles()
        if profiles.isEmpty {
            print("No profiles found.")
        } else {
            listProfiles(profiles)
        }
    } catch {
        fputs("error: \(error)\n", stderr)
        exit(1)
    }

case "launch":
    let profiles: [Profile]
    do { profiles = try parseProfiles() } catch {
        fputs("error: \(error)\n", stderr)
        exit(1)
    }

    guard args.count >= 3 else {
        fputs("error: profile name required\n\ndiscovered profiles:\n", stderr)
        listProfiles(profiles)
        exit(1)
    }

    let input = args[2...].joined(separator: " ")

    let (matches, method) = matchProfile(profiles, input)

    if matches.isEmpty {
        fputs("error: no profile matching \"\(input)\"\n", stderr)
        fputs("available profiles:\n", stderr)
        listProfiles(profiles)
        exit(1)
    }

    if matches.count > 1 {
        fputs("error: \"\(input)\" matches multiple profiles (\(method)):\n", stderr)
        for m in matches {
            fputs("  \(m.name)\n", stderr)
        }
        exit(1)
    }

    let matched = matches[0]
    if method != "exact" {
        fputs("matched \"\(matched.name)\" (\(method))\n", stderr)
    }

    var url: String? = nil
    if isatty(STDIN_FILENO) == 0 {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        let trimmed = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            url = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        }
    }


    launchProfile(matched, url: url)

case "install":
    do {
        try installApps()
    } catch {
        fputs("error: \(error)\n", stderr)
        exit(1)
    }

case "uninstall":
    do {
        try uninstallApps()
    } catch {
        fputs("error: \(error)\n", stderr)
        exit(1)
    }

case "_complete":
    if let profiles = try? parseProfiles() {
        for p in profiles { print(p.name) }
    }


default:
    fputs("unknown command: \(args[1])\n", stderr)
    usage()
    exit(1)
}
