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

func getProcessArgs(_ pid: pid_t) -> [String]? {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size: Int = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buf = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size >= 4 else { return nil }

    let argc = Int(UInt32(buf[0]) | (UInt32(buf[1]) << 8) | (UInt32(buf[2]) << 16) | (UInt32(buf[3]) << 24))

    // Skip past the saved exe path
    var i = 4
    while i < size && buf[i] != 0 { i += 1 }
    while i < size && buf[i] == 0 { i += 1 }

    // Parse argc null-terminated argument strings
    var args: [String] = []
    var start = i
    while i < size && args.count < argc {
        if buf[i] == 0 {
            if let s = String(bytes: buf[start..<i], encoding: .utf8) { args.append(s) }
            start = i + 1
        }
        i += 1
    }
    return args.isEmpty ? nil : args
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

    // Fast path: check main Firefox process args directly (1 sysctl per instance).
    for pid in firefoxPids {
        guard let args = getProcessArgs(pid) else { continue }
        let pairs = zip(args, args.dropFirst())
        if pairs.contains(where: { ($0 == "-profile" && $1 == fullPath) || ($0 == "-P" && $1 == profileName) }) {
            return pid
        }
    }

    // Slow path: scan child processes for -profile/-parentPid args.
    // Needed when the main process args don't expose the profile directly.
    for kp in allPids() {
        let ppid = kp.kp_eproc.e_ppid
        guard firefoxPids.contains(ppid) else { continue }

        let childPid = kp.kp_proc.p_pid
        guard let args = getProcessArgs(childPid) else { continue }

        let hasProfile = zip(args, args.dropFirst()).contains { $0 == "-profile" && $1 == fullPath }
        guard hasProfile else { continue }

        guard let idx = args.firstIndex(of: "-parentPid"),
              idx + 1 < args.count,
              let pid = pid_t(args[idx + 1]), pid > 0 else { continue }
        return pid
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
        PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"
        exec ffprofile launch "\(profile.name)"
        """
        let runPath = macosDir.appendingPathComponent("run")
        try script.write(to: runPath, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runPath.path)

        print("installed \(appName)")
    }
}

// MARK: - Services

func xmlEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;")
     .replacingOccurrences(of: "<", with: "&lt;")
     .replacingOccurrences(of: ">", with: "&gt;")
}

func installServices() throws {
    let profiles = try parseProfiles()
    let fm = FileManager.default
    let servicesDir = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Services")
    try fm.createDirectory(at: servicesDir, withIntermediateDirectories: true)

    for profile in profiles {
        let workflowName = "\(profile.name) - Firefox.workflow"
        let contentsDir = servicesDir.appendingPathComponent(workflowName).appendingPathComponent("Contents")
        let resourcesDir = contentsDir.appendingPathComponent("Resources")
        try fm.createDirectory(at: resourcesDir, withIntermediateDirectories: true)

        let menuName = "Open in \(profile.name) - Firefox"
        let bundleId = "com.ffprofile.service.\(profile.name.lowercased().replacingOccurrences(of: " ", with: "-"))"

        let infoPlist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleDevelopmentRegion</key>
            <string>en_US</string>
            <key>CFBundleIdentifier</key>
            <string>\(bundleId)</string>
            <key>CFBundleName</key>
            <string>\(xmlEscape(menuName))</string>
            <key>CFBundleShortVersionString</key>
            <string>1.0</string>
            <key>NSServices</key>
            <array>
                <dict>
                    <key>NSMenuItem</key>
                    <dict>
                        <key>default</key>
                        <string>\(xmlEscape(menuName))</string>
                    </dict>
                    <key>NSMessage</key>
                    <string>runWorkflowAsService</string>
                    <key>NSSendTypes</key>
                    <array>
                        <string>public.utf8-plain-text</string>
                    </array>
                </dict>
            </array>
        </dict>
        </plist>
        """

        let shellName = xmlEscape(profile.name.replacingOccurrences(of: "\"", with: "\\\""))
        let inputUUID = UUID().uuidString
        let outputUUID = UUID().uuidString
        let actionUUID = UUID().uuidString

        let documentWflow = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>AMApplicationBuild</key>
            <string>521.1</string>
            <key>AMApplicationVersion</key>
            <string>2.10</string>
            <key>AMDocumentVersion</key>
            <string>2</string>
            <key>actions</key>
            <array>
                <dict>
                    <key>action</key>
                    <dict>
                        <key>AMAccepts</key>
                        <dict>
                            <key>Container</key>
                            <string>List</string>
                            <key>Optional</key>
                            <true/>
                            <key>Types</key>
                            <array>
                                <string>com.apple.cocoa.string</string>
                            </array>
                        </dict>
                        <key>AMActionVersion</key>
                        <string>2.0.3</string>
                        <key>AMApplication</key>
                        <array>
                            <string>Automator</string>
                        </array>
                        <key>AMParameterProperties</key>
                        <dict>
                            <key>COMMAND_STRING</key>
                            <dict/>
                            <key>CheckedForUserDefaultShell</key>
                            <dict/>
                            <key>inputMethod</key>
                            <dict/>
                            <key>shell</key>
                            <dict/>
                            <key>source</key>
                            <dict/>
                        </dict>
                        <key>AMProvides</key>
                        <dict>
                            <key>Container</key>
                            <string>List</string>
                            <key>Types</key>
                            <array>
                                <string>com.apple.cocoa.string</string>
                            </array>
                        </dict>
                        <key>ActionBundlePath</key>
                        <string>/System/Library/Automator/Run Shell Script.action</string>
                        <key>ActionName</key>
                        <string>Run Shell Script</string>
                        <key>ActionParameters</key>
                        <dict>
                            <key>COMMAND_STRING</key>
                            <string>PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"
        ffprofile launch "\(shellName)"</string>
                            <key>CheckedForUserDefaultShell</key>
                            <true/>
                            <key>inputMethod</key>
                            <integer>0</integer>
                            <key>shell</key>
                            <string>/bin/sh</string>
                            <key>source</key>
                            <string></string>
                        </dict>
                        <key>BundleIdentifier</key>
                        <string>com.apple.RunShellScript</string>
                        <key>CFBundleVersion</key>
                        <string>2.0.3</string>
                        <key>CanShowSelectedItemsWhenRun</key>
                        <false/>
                        <key>CanShowWhenRun</key>
                        <true/>
                        <key>Category</key>
                        <array>
                            <string>AMCategoryUtilities</string>
                        </array>
                        <key>Class Name</key>
                        <string>RunShellScriptAction</string>
                        <key>InputUUID</key>
                        <string>\(inputUUID)</string>
                        <key>Keywords</key>
                        <array>
                            <string>Shell</string>
                            <string>Script</string>
                            <string>Command</string>
                            <string>Run</string>
                            <string>Unix</string>
                        </array>
                        <key>OutputUUID</key>
                        <string>\(outputUUID)</string>
                        <key>UUID</key>
                        <string>\(actionUUID)</string>
                        <key>UnlocalizedApplications</key>
                        <array>
                            <string>Automator</string>
                        </array>
                        <key>arguments</key>
                        <dict>
                            <key>0</key>
                            <dict>
                                <key>default value</key>
                                <integer>0</integer>
                                <key>name</key>
                                <string>inputMethod</string>
                                <key>required</key>
                                <string>0</string>
                                <key>type</key>
                                <string>0</string>
                                <key>uuid</key>
                                <string>0</string>
                            </dict>
                            <key>1</key>
                            <dict>
                                <key>default value</key>
                                <string></string>
                                <key>name</key>
                                <string>source</string>
                                <key>required</key>
                                <string>0</string>
                                <key>type</key>
                                <string>0</string>
                                <key>uuid</key>
                                <string>1</string>
                            </dict>
                            <key>2</key>
                            <dict>
                                <key>default value</key>
                                <false/>
                                <key>name</key>
                                <string>CheckedForUserDefaultShell</string>
                                <key>required</key>
                                <string>0</string>
                                <key>type</key>
                                <string>0</string>
                                <key>uuid</key>
                                <string>2</string>
                            </dict>
                            <key>3</key>
                            <dict>
                                <key>default value</key>
                                <string></string>
                                <key>name</key>
                                <string>COMMAND_STRING</string>
                                <key>required</key>
                                <string>0</string>
                                <key>type</key>
                                <string>0</string>
                                <key>uuid</key>
                                <string>3</string>
                            </dict>
                            <key>4</key>
                            <dict>
                                <key>default value</key>
                                <string>/bin/sh</string>
                                <key>name</key>
                                <string>shell</string>
                                <key>required</key>
                                <string>0</string>
                                <key>type</key>
                                <string>0</string>
                                <key>uuid</key>
                                <string>4</string>
                            </dict>
                        </dict>
                        <key>isViewVisible</key>
                        <true/>
                        <key>location</key>
                        <string>309.500000:253.000000</string>
                        <key>nibPath</key>
                        <string>/System/Library/Automator/Run Shell Script.action/Contents/Resources/en.lproj/main.nib</string>
                    </dict>
                    <key>isViewVisible</key>
                    <true/>
                </dict>
            </array>
            <key>connectors</key>
            <dict/>
            <key>workflowMetaData</key>
            <dict>
                <key>serviceApplicationBundleID</key>
                <string></string>
                <key>serviceApplicationPath</key>
                <string></string>
                <key>serviceInputTypeIdentifier</key>
                <string>com.apple.Automator.text</string>
                <key>serviceOutputTypeIdentifier</key>
                <string>com.apple.Automator.nothing</string>
                <key>serviceProcessesInput</key>
                <integer>0</integer>
                <key>workflowTypeIdentifier</key>
                <string>com.apple.Automator.servicesMenu</string>
            </dict>
        </dict>
        </plist>
        """

        try infoPlist.write(to: contentsDir.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)
        try documentWflow.write(to: resourcesDir.appendingPathComponent("document.wflow"), atomically: true, encoding: .utf8)
        print("installed service \"\(menuName)\"")
    }

    let pbs = Process()
    pbs.executableURL = URL(fileURLWithPath: "/System/Library/CoreServices/pbs")
    pbs.arguments = ["-update"]
    try? pbs.run()
    pbs.waitUntilExit()
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

func uninstallServices() throws {
    let profiles = try parseProfiles()
    let fm = FileManager.default
    let servicesDir = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Services")

    for profile in profiles {
        let workflowName = "\(profile.name) - Firefox.workflow"
        let workflowPath = servicesDir.appendingPathComponent(workflowName)
        if fm.fileExists(atPath: workflowPath.path) {
            try fm.removeItem(at: workflowPath)
            print("removed service \"\(profile.name) - Firefox\"")
        }
    }
}

// MARK: - Main

func usage() {
    fputs("Usage:\n", stderr)
    fputs("  ffprofile list              List available profiles\n", stderr)
    fputs("  ffprofile launch <profile>  Launch a profile (pipe a URL to open it)\n", stderr)
    fputs("  ffprofile install           Install Spotlight apps and Services\n", stderr)
    fputs("  ffprofile uninstall         Remove Spotlight apps and Services\n", stderr)
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
        try installServices()
    } catch {
        fputs("error: \(error)\n", stderr)
        exit(1)
    }

case "uninstall":
    do {
        try uninstallApps()
        try uninstallServices()
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
