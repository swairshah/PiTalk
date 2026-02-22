import Foundation
import AppKit
import CoreGraphics
import os.log
import ApplicationServices

/// Handles jumping to terminal windows for a given PID
/// Ported from pi-statusbar's daemon logic with all fixes
final class JumpHandler {
    
    private static let logger = Logger(subsystem: "com.pitalk", category: "JumpHandler")
    
    /// Check if we have accessibility permissions (no prompt)
    static func hasAccessibilityPermissions() -> Bool {
        return AXIsProcessTrusted()
    }
    
    /// Check if we have accessibility permissions, prompt if not
    /// Returns true if we have permissions, false if not (and user was prompted)
    static func checkAccessibilityPermissions() -> Bool {
        let trusted = AXIsProcessTrusted()
        if !trusted {
            // Prompt user to grant accessibility permissions
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
            return false
        }
        return true
    }
    
    /// Open System Settings to Accessibility pane
    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
    
    struct JumpResult {
        let ok: Bool
        let focused: Bool
        let focusedApp: String?
        let openedShell: Bool
        let message: String?
    }
    
    struct ProcessInfo {
        let pid: Int32
        let ppid: Int32
        let comm: String
        let tty: String
        let args: String
    }
    
    struct GhosttyTab {
        let name: String
        let windowNumber: Int
        let pid: Int
        let isOnScreen: Bool
    }
    
    struct MuxInfo {
        let type: String  // "tmux" or "zellij"
        let session: String?
    }
    
    // MARK: - Public API
    
    /// Async jump - doesn't block the main thread
    static func jumpAsync(to pid: Int, completion: @escaping (JumpResult) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = jump(to: pid)
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }
    
    static func jump(to pid: Int) -> JumpResult {
        // Check accessibility permissions first
        if !checkAccessibilityPermissions() {
            return JumpResult(ok: false, focused: false, focusedApp: nil, openedShell: false,
                            message: "Accessibility permissions required. Please grant access in System Settings.")
        }
        let handler = JumpHandler()
        return handler.performJump(pid: pid)
    }
    
    // MARK: - Jump Implementation
    
    private func performJump(pid: Int) -> JumpResult {
        NSLog("JumpHandler: performJump starting for PID %d", pid)
        let processes = scanProcesses()
        NSLog("JumpHandler: found %d processes", processes.count)
        let byPid = Dictionary(uniqueKeysWithValues: processes.map { (Int($0.pid), $0) })
        
        // Find the target process
        guard let targetProcess = byPid[pid] else {
            NSLog("JumpHandler: %@", "process not found: \(pid)")
            
            // Fallback for short-lived worker processes (eg. FloatingChat subprocesses):
            // use telemetry metadata to focus the owning app instead of failing hard.
            if let fallbackResult = focusOwningAppFromTelemetry(forMissingPid: pid) {
                return fallbackResult
            }
            
            return JumpResult(ok: false, focused: false, focusedApp: nil, openedShell: false,
                            message: "Process not found: \(pid)")
        }
        
        let tty = targetProcess.tty
        NSLog("JumpHandler: %@", "tty = \(tty)")
        let cwd = getCwd(for: pid)
        NSLog("JumpHandler: %@", "cwd = \(cwd ?? "nil")")
        
        // Detect mux (tmux/zellij)
        let muxInfo = detectMux(pid: Int32(pid), byPid: byPid)
        NSLog("JumpHandler: %@", "mux = \(muxInfo?.type ?? "nil"), session = \(muxInfo?.session ?? "nil")")
        
        // Detect terminal app from process ancestry
        var (terminalApp, _) = detectTerminalApp(pid: Int32(pid), byPid: byPid)
        NSLog("JumpHandler: %@", "terminalApp = \(terminalApp ?? "nil")")
        
        // Build focus hints
        var hints: [String] = []
        
        // For tmux, query the actual session/window info directly
        var tmuxWindowName: String? = nil
        if muxInfo?.type == "tmux" && tty != "??" {
            if let tmuxInfo = getTmuxInfoForTTY(tty) {
                NSLog("JumpHandler: tmux info for TTY %@: session=%@, window=%@", tty, tmuxInfo.session, tmuxInfo.windowName)
                hints.append(tmuxInfo.session)
                hints.append(tmuxInfo.windowName)
                tmuxWindowName = tmuxInfo.windowName
            }
        }
        
        if let session = muxInfo?.session {
            hints.append(session)
            if session.hasPrefix("agent-") {
                hints.append(String(session.dropFirst(6)))
            }
        }
        if let cwd = cwd {
            hints.append(URL(fileURLWithPath: cwd).lastPathComponent)
        }
        if tty != "??" {
            hints.append(tty)
        }
        
        NSLog("JumpHandler: focus hints = %@", hints as NSArray)
        
        // Find mux client PID (the tmux/zellij client attached to the session)
        let clientPid = findMuxClientPid(mux: muxInfo, tty: tty, processes: processes)
        
        // If we have a client PID, detect terminal from that
        if let clientPid = clientPid {
            let (clientTerminal, _) = detectTerminalApp(pid: clientPid, byPid: byPid)
            if let t = clientTerminal {
                terminalApp = t
            }
        }
        
        var focused = false
        var focusedApp: String? = terminalApp
        
        // Step 1: Try to focus terminal app from process ancestry
        if let app = terminalApp, app != "Ghostty" {
            // For non-Ghostty, try direct activation
            focused = focusTerminalApp(app, hints: hints)
            if focused {
                focusedApp = app
            }
        }
        
        // Step 2: TTY-based focus for iTerm2/Terminal (skip if Ghostty)
        if !focused && tty != "??" && terminalApp != "Ghostty" {
            focused = focusTerminalByTTY(tty)
        }
        
        // Step 3: Title hint focus for iTerm2/Terminal (skip if Ghostty)
        if !focused && terminalApp != "Ghostty" {
            if let session = muxInfo?.session {
                focused = focusTerminalByTitleHint(session)
                if !focused && session.hasPrefix("agent-") {
                    focused = focusTerminalByTitleHint(String(session.dropFirst(6)))
                }
            }
        }
        
        // Step 4: Ghostty CGWindowList-based tab switching
        // This is the main path for Ghostty - handles tab switching properly
        NSLog("JumpHandler: %@", "Step 4 check: focused=\(focused), terminalApp=\(terminalApp ?? "nil"), muxInfo=\(muxInfo != nil)")
        if !focused && (terminalApp == "Ghostty" || muxInfo != nil) {
            // IMPORTANT: zellij sessions often share one Ghostty tab (eg. "dev1").
            // Prioritize per-session hints (cwd/tty) over mux session name to avoid always matching "dev1".
            var searchHints: [String] = []
            let muxType = muxInfo?.type
            
            if muxType == "zellij" {
                if let cwd = cwd {
                    searchHints.append(URL(fileURLWithPath: cwd).lastPathComponent)
                }
                if tty != "??" {
                    searchHints.append(tty)
                }
                if let muxSession = muxInfo?.session {
                    searchHints.append(muxSession)
                }
                // Keep any additional hints (deduped, original order)
                for h in hints where !searchHints.contains(h) {
                    searchHints.append(h)
                }
            } else {
                searchHints = hints
                // For tmux, session name is usually the most precise top-level hint.
                if let muxSession = muxInfo?.session, !searchHints.contains(muxSession) {
                    searchHints.insert(muxSession, at: 0)
                }
            }
            
            if let muxType {
                searchHints.append(muxType)
            }
            
            let isTmux = muxType == "tmux"
            NSLog("JumpHandler: %@", "Step 4 - calling focusGhosttyViaCGWindowList with hints=\(searchHints), isTmux=\(isTmux)")
            let (success, msg) = focusGhosttyViaCGWindowList(hints: searchHints, cwd: cwd, isTmux: isTmux)
            NSLog("JumpHandler: %@", "Step 4 result: success=\(success), msg=\(msg ?? "nil")")
            focused = success
            if focused {
                focusedApp = "Ghostty"
            }
        }
        
        // Step 5: If tmux, switch to the correct pane
        if focused && muxInfo?.type == "tmux" && tty != "??" {
            selectTmuxPaneByTTY(tty)
        }
        
        // Step 5b: If zellij, deterministically switch to tab containing the pi pane for this cwd
        if focused && muxInfo?.type == "zellij", let zellijSession = muxInfo?.session {
            selectZellijTabForSession(session: zellijSession, cwd: cwd, tty: tty)
        }
        
        // Step 6: Non-terminal fallback (eg. app-hosted pi via RPC/subprocess)
        // IMPORTANT: Do NOT use this for terminal/mux sessions, or we'll report false positives.
        let looksLikeTerminalSession = (tty != "??") || (muxInfo != nil) || (terminalApp != nil)
        if !focused && !looksLikeTerminalSession {
            if let appName = focusOwningAppForLivePid(Int32(pid), byPid: byPid, cwdHint: cwd) {
                focused = true
                focusedApp = appName
            }
        }
        
        return JumpResult(
            ok: true,
            focused: focused,
            focusedApp: focusedApp,
            openedShell: false,
            message: focused ? "Focused \(focusedApp ?? "app")" : "Could not focus terminal or app"
        )
    }
    
    // MARK: - Process Scanning
    
    private func scanProcesses() -> [ProcessInfo] {
        NSLog("JumpHandler: %@", "scanProcesses starting...")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-axo", "pid=,ppid=,comm=,tty=,args="]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        
        do {
            NSLog("JumpHandler: %@", "scanProcesses running ps...")
            try task.run()
        } catch {
            NSLog("JumpHandler: %@", "scanProcesses error: \(error)")
            return []
        }
        
        // IMPORTANT: Read output BEFORE waitUntilExit to avoid deadlock
        // (pipe buffer can fill up and block the process)
        NSLog("JumpHandler: %@", "scanProcesses reading output...")
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        NSLog("JumpHandler: %@", "scanProcesses waiting for ps to exit...")
        task.waitUntilExit()
        NSLog("JumpHandler: %@", "scanProcesses ps exited with code \(task.terminationStatus)")
        
        guard let output = String(data: data, encoding: .utf8) else { return [] }
        
        var processes: [ProcessInfo] = []
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            
            let parts = trimmed.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
            guard parts.count >= 4 else { continue }
            
            guard let pid = Int32(parts[0]),
                  let ppid = Int32(parts[1]) else { continue }
            
            let comm = String(parts[2])
            let tty = String(parts[3])
            let args = parts.count > 4 ? String(parts[4]) : ""
            
            processes.append(ProcessInfo(pid: pid, ppid: ppid, comm: comm, tty: tty, args: args))
        }
        
        return processes
    }
    
    private func getCwd(for pid: Int) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-a", "-p", "\(pid)", "-d", "cwd", "-Fn"]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        
        do {
            try task.run()
        } catch {
            return nil
        }
        
        // Read output before waiting to avoid deadlock
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        
        guard let output = String(data: data, encoding: .utf8) else { return nil }
        
        for line in output.components(separatedBy: "\n") {
            if line.hasPrefix("n") {
                return String(line.dropFirst())
            }
        }
        
        return nil
    }
    
    // MARK: - Mux Detection
    
    private func detectMux(pid: Int32, byPid: [Int: ProcessInfo]) -> MuxInfo? {
        var seen = Set<Int32>()
        var current: Int32? = pid
        
        while let cur = current, !seen.contains(cur) {
            seen.insert(cur)
            guard let process = byPid[Int(cur)] else { break }
            
            let args = process.args.lowercased()
            
            // Check for zellij
            if process.comm.lowercased().contains("zellij") || args.contains("zellij") {
                let session = extractZellijSession(args: process.args)
                return MuxInfo(type: "zellij", session: session)
            }
            
            // Check for tmux
            if process.comm.lowercased() == "tmux" || args.contains("tmux") {
                let session = extractTmuxSession(args: process.args)
                return MuxInfo(type: "tmux", session: session)
            }
            
            current = process.ppid
        }
        
        return nil
    }
    
    private func extractZellijSession(args: String) -> String? {
        // Look for "attach <session>" pattern
        if let range = args.range(of: "attach\\s+(\\S+)", options: .regularExpression) {
            let match = args[range]
            let parts = match.split(separator: " ")
            if parts.count >= 2 {
                return String(parts[1])
            }
        }
        
        // Look for session name in --server path (e.g., /tmp/zellij-501/0.43.1/session-name)
        if let range = args.range(of: "--server\\s+(\\S+)", options: .regularExpression) {
            let match = args[range]
            let parts = match.split(separator: " ")
            if parts.count >= 2 {
                let serverPath = String(parts[1])
                // Session name is the last component of the path
                if let lastComponent = serverPath.split(separator: "/").last {
                    return String(lastComponent)
                }
            }
        }
        
        return nil
    }
    
    private func extractTmuxSession(args: String) -> String? {
        // Look for "-t <session>" or "attach -t <session>" pattern
        if let range = args.range(of: "-t\\s+(\\S+)", options: .regularExpression) {
            let match = args[range]
            let parts = match.split(separator: " ")
            if parts.count >= 2 {
                return String(parts[1])
            }
        }
        return nil
    }
    
    /// Query tmux directly to find session/window name for a given TTY
    private func getTmuxInfoForTTY(_ tty: String) -> (session: String, windowName: String)? {
        let ttyPath = tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"
        
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = ["tmux", "list-panes", "-a", "-F", "#{pane_tty} #{session_name} #{window_name}"]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        
        do {
            try task.run()
        } catch {
            return nil
        }
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        
        guard let output = String(data: data, encoding: .utf8) else { return nil }
        
        for line in output.components(separatedBy: "\n") {
            let parts = line.split(separator: " ", maxSplits: 2)
            guard parts.count >= 3 else { continue }
            
            let paneTTY = String(parts[0])
            if paneTTY == ttyPath {
                let session = String(parts[1])
                let windowName = String(parts[2])
                return (session, windowName)
            }
        }
        
        return nil
    }
    
    private func findMuxClientPid(mux: MuxInfo?, tty: String, processes: [ProcessInfo]) -> Int32? {
        guard let mux = mux else { return nil }
        
        if mux.type == "tmux" {
            // Find any tmux client process (not necessarily same TTY)
            for p in processes {
                if p.comm.lowercased() == "tmux" && p.args.contains("tmux") && p.tty != "??" && p.tty != tty {
                    return p.pid
                }
            }
        }
        
        return nil
    }
    
    private func detectTerminalApp(pid: Int32, byPid: [Int: ProcessInfo]) -> (String?, Int32?) {
        var seen = Set<Int32>()
        var current: Int32? = pid
        
        while let cur = current, !seen.contains(cur) {
            seen.insert(cur)
            
            guard let process = byPid[Int(cur)] else { break }
            
            let comm = process.comm.lowercased()
            let args = process.args.lowercased()
            
            if comm.contains("ghostty") || args.contains("ghostty") {
                return ("Ghostty", cur)
            }
            if comm.contains("iterm") || args.contains("iterm") {
                return ("iTerm2", cur)
            }
            if comm == "terminal" || args.contains("terminal.app") {
                return ("Terminal", cur)
            }
            
            current = process.ppid
        }
        
        return (nil, nil)
    }
    
    // MARK: - Terminal Focusing
    
    private func focusTerminalApp(_ appName: String, hints: [String]) -> Bool {
        // For Ghostty, we use CGWindowList approach
        if appName == "Ghostty" {
            return false  // Let CGWindowList handle it
        }
        
        // Check if app is running first
        if !isAppRunning(appName) {
            return false
        }
        
        return activateApp(appName)
    }
    
    private func isAppRunning(_ appName: String) -> Bool {
        // Use native NSRunningApplication instead of AppleScript
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId(for: appName))
        if !apps.isEmpty {
            return true
        }
        // Fallback: check by name
        return NSWorkspace.shared.runningApplications.contains { app in
            app.localizedName?.lowercased() == appName.lowercased()
        }
    }
    
    private func bundleId(for appName: String) -> String {
        switch appName.lowercased() {
        case "ghostty": return "com.mitchellh.ghostty"
        case "iterm", "iterm2": return "com.googlecode.iterm2"
        case "terminal": return "com.apple.Terminal"
        default: return ""
        }
    }
    
    private func focusTerminalByTTY(_ tty: String) -> Bool {
        let t = escapeForAppleScript(tty)
        
        // Try iTerm2 first (check if running with native API first to avoid "Where is app?" dialog)
        if isAppRunning("iTerm2") {
            let itermScript = """
            try
                tell application "iTerm2"
                    repeat with w in windows
                        repeat with tb in tabs of w
                            repeat with s in sessions of tb
                                try
                                    if (tty of s as text) ends with "\(t)" then
                                        select s
                                        select tb
                                        activate
                                        return "ok"
                                    end if
                                end try
                            end repeat
                        end repeat
                    end repeat
                end tell
            end try
            return "no"
            """
            if runAppleScript(itermScript) == "ok" {
                return true
            }
        }
        
        // Try Terminal (check if running first)
        if isAppRunning("Terminal") {
            let terminalScript = """
            try
                tell application "Terminal"
                    repeat with w in windows
                        repeat with tb in tabs of w
                            try
                                if (tty of tb as text) ends with "\(t)" then
                                    set selected of tb to true
                                    activate
                                    return "ok"
                                end if
                            end try
                        end repeat
                    end repeat
                end tell
            end try
            return "no"
            """
            if runAppleScript(terminalScript) == "ok" {
                return true
            }
        }
        
        return false
    }
    
    private func focusTerminalByTitleHint(_ hint: String) -> Bool {
        let h = escapeForAppleScript(hint)
        
        // Try iTerm2 first (check if running with native API to avoid "Where is app?" dialog)
        if isAppRunning("iTerm2") {
            let itermScript = """
            set needle to "\(h)"
            try
                tell application "iTerm2"
                    repeat with w in windows
                        repeat with tb in tabs of w
                            try
                                if (name of tb as text) contains needle then
                                    tell w to select tb
                                    activate
                                    return "ok"
                                end if
                            end try
                        end repeat
                    end repeat
                end tell
            end try
            return "no"
            """
            if runAppleScript(itermScript) == "ok" {
                return true
            }
        }
        
        // Try Terminal (check if running first)
        if isAppRunning("Terminal") {
            let terminalScript = """
            set needle to "\(h)"
            try
                tell application "Terminal"
                    repeat with w in windows
                        repeat with tb in tabs of w
                            try
                                if (custom title of tb as text) contains needle then
                                    set selected of tb to true
                                    activate
                                    return "ok"
                                end if
                            end try
                        end repeat
                    end repeat
                end tell
            end try
            return "no"
            """
            if runAppleScript(terminalScript) == "ok" {
                return true
            }
        }
        
        return false
    }
    
    // MARK: - Ghostty CGWindowList-based Tab Switching
    
    private func getGhosttyTabsViaCGWindowList() -> [GhosttyTab] {
        guard let windowList = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        
        var tabs: [GhosttyTab] = []
        
        for window in windowList {
            guard let ownerName = window[kCGWindowOwnerName as String] as? String,
                  ownerName.lowercased().contains("ghostty") else {
                continue
            }
            
            let layer = window[kCGWindowLayer as String] as? Int ?? 0
            let alpha = window[kCGWindowAlpha as String] as? Double ?? 1.0
            let name = window[kCGWindowName as String] as? String ?? ""
            let bounds = window[kCGWindowBounds as String] as? [String: Any] ?? [:]
            let height = bounds["Height"] as? Double ?? 0
            let windowNumber = window[kCGWindowNumber as String] as? Int ?? 0
            let pid = window[kCGWindowOwnerPID as String] as? Int ?? 0
            let isOnScreen = window[kCGWindowIsOnscreen as String] as? Bool ?? false
            
            // Main content windows: layer 0, full alpha, has height > tabbar, has name
            if layer == 0 && alpha >= 1.0 && height > 100 && !name.isEmpty {
                tabs.append(GhosttyTab(name: name, windowNumber: windowNumber, pid: pid, isOnScreen: isOnScreen))
            }
        }
        
        // Sort by window number (roughly creation order = tab order)
        tabs.sort { $0.windowNumber < $1.windowNumber }
        return tabs
    }
    
    // MARK: - Accessibility API Tab Switching
    
    private func focusGhosttyTabViaAccessibility(searchTerms: [String], isTmux: Bool = false) -> (Bool, String?) {
        guard let ghosttyApp = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.mitchellh.ghostty"
        }) else {
            return (false, "Ghostty not running")
        }
        
        let appRef = AXUIElementCreateApplication(ghosttyApp.processIdentifier)
        
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement],
              !windows.isEmpty else {
            return (false, "Could not get Ghostty windows")
        }
        
        let onScreenWindowTitles = Set(getGhosttyTabsViaCGWindowList().filter { $0.isOnScreen }.map { $0.name })
        
        func windowTitle(_ window: AXUIElement) -> String {
            var titleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef) == .success,
               let title = titleRef as? String {
                return title
            }
            return ""
        }
        
        func tabsForWindow(_ window: AXUIElement) -> [(tab: AXUIElement, title: String)] {
            var childrenRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXChildrenAttribute as CFString, &childrenRef) == .success,
                  let children = childrenRef as? [AXUIElement] else {
                return []
            }
            
            var tabGroup: AXUIElement?
            for child in children {
                var roleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleRef)
                if (roleRef as? String) == "AXTabGroup" {
                    tabGroup = child
                    break
                }
            }
            
            guard let tabGroup else { return [] }
            
            var tabsRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(tabGroup, kAXChildrenAttribute as CFString, &tabsRef) == .success,
                  let tabs = tabsRef as? [AXUIElement] else {
                return []
            }
            
            return tabs.compactMap { tab in
                var titleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(tab, kAXTitleAttribute as CFString, &titleRef)
                guard let title = titleRef as? String else { return nil }
                return (tab, title)
            }
        }
        
        let orderedWindows = windows.sorted { lhs, rhs in
            let lTitle = windowTitle(lhs)
            let rTitle = windowTitle(rhs)
            let lOn = onScreenWindowTitles.contains(lTitle)
            let rOn = onScreenWindowTitles.contains(rTitle)
            if lOn != rOn { return lOn && !rOn }
            return false
        }
        
        var allTabTitles: [String] = []
        
        for window in orderedWindows {
            let winTitle = windowTitle(window)
            let tabsWithTitles = tabsForWindow(window)
            allTabTitles.append(contentsOf: tabsWithTitles.map { $0.title })
            guard !tabsWithTitles.isEmpty else { continue }
            
            for term in searchTerms {
                let termLower = term.lowercased()
                
                for (tab, title) in tabsWithTitles where title.lowercased().contains(termLower) && title.hasPrefix("π -") {
                    _ = AXUIElementSetAttributeValue(appRef, kAXMainWindowAttribute as CFString, window)
                    _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                    let result = AXUIElementPerformAction(tab, kAXPressAction as CFString)
                    if result == .success {
                        return (true, "Selected tab '\(title)' in window '\(winTitle)' via Accessibility API (matched '\(term)')")
                    }
                    return (false, "Failed to click tab: \(result.rawValue)")
                }
                
                for (tab, title) in tabsWithTitles where title.lowercased().contains(termLower) {
                    _ = AXUIElementSetAttributeValue(appRef, kAXMainWindowAttribute as CFString, window)
                    _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                    let result = AXUIElementPerformAction(tab, kAXPressAction as CFString)
                    if result == .success {
                        return (true, "Selected tab '\(title)' in window '\(winTitle)' via Accessibility API (matched '\(term)')")
                    }
                    return (false, "Failed to click tab: \(result.rawValue)")
                }
            }
            
            if isTmux {
                NSLog("JumpHandler: tmux fallback - looking for generic tabs in window '\(winTitle)'")
                for (tab, title) in tabsWithTitles {
                    let isPiSession = title.hasPrefix("π -")
                    let isZellij = title.contains("|")
                    let isPath = title.hasPrefix("…/") || title.hasPrefix("/")
                    let isEmpty = title.isEmpty
                    let isGeneric = !isPiSession && !isZellij && !isPath && !isEmpty
                    
                    if isGeneric {
                        _ = AXUIElementSetAttributeValue(appRef, kAXMainWindowAttribute as CFString, window)
                        _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                        let result = AXUIElementPerformAction(tab, kAXPressAction as CFString)
                        if result == .success {
                            return (true, "Selected generic tab '\(title)' via tmux fallback")
                        }
                    }
                }
            }
        }
        
        return (false, "No matching tab found, available: \(allTabTitles)")
    }
    
    private func focusGhosttyViaCGWindowList(hints: [String], cwd: String?, isTmux: Bool = false) -> (Bool, String?) {
        NSLog("JumpHandler: %@", "focusGhosttyViaCGWindowList starting...")
        
        // Build search terms from hints and cwd
        var searchTerms = hints.map { $0.lowercased() }
        if let cwd = cwd {
            searchTerms.append(URL(fileURLWithPath: cwd).lastPathComponent.lowercased())
        }
        
        // Ensure Ghostty is active first (helps AX enumerate windows reliably across Spaces)
        _ = forceActivateGhosttyFrontmost()
        
        // Try Accessibility API first (window-aware, prefers on-screen windows)
        let (axSuccess, axMsg) = focusGhosttyTabViaAccessibility(searchTerms: searchTerms, isTmux: isTmux)
        if axSuccess {
            if forceActivateGhosttyFrontmost() || isGhosttyFrontmost() {
                NSLog("JumpHandler: %@", "Accessibility API success: \(axMsg ?? "")")
                return (true, axMsg)
            }
            NSLog("JumpHandler: %@", "Accessibility selected tab but Ghostty is not frontmost; falling back to keystrokes")
        } else {
            NSLog("JumpHandler: %@", "Accessibility API failed: \(axMsg ?? ""), falling back to keystrokes")
        }
        
        // Fallback to CGWindowList + keystrokes
        _ = forceActivateGhosttyFrontmost()
        let tabs = getGhosttyTabsViaCGWindowList()
        NSLog("JumpHandler: %@", "found \(tabs.count) Ghostty tabs")
        
        guard !tabs.isEmpty else {
            return (false, "no Ghostty tabs found")
        }
        
        // Find matching tab by hints
        var matchedName: String? = nil
        for tab in tabs {
            let tabName = tab.name.lowercased()
            for term in searchTerms {
                if tabName.contains(term) {
                    matchedName = tab.name
                    break
                }
            }
            if matchedName != nil { break }
        }
        
        // tmux-specific fallback in CG path: prefer a generic terminal tab
        // (not zellij pipe-style titles, not explicit pi session titles)
        if matchedName == nil && isTmux {
            if let generic = tabs.first(where: { tab in
                let title = tab.name
                let isPiSession = title.hasPrefix("π -")
                let isZellij = title.contains("|")
                let isPath = title.hasPrefix("…/") || title.hasPrefix("/")
                return !isPiSession && !isZellij && !isPath && !title.isEmpty
            }) {
                matchedName = generic.name
                NSLog("JumpHandler: tmux CG fallback selected generic tab '%@'", generic.name)
            }
        }
        
        guard let targetName = matchedName else {
            let tabNames = tabs.map { $0.name }
            return (false, "no tab matched, available: \(tabNames)")
        }
        
        // KEY FIX: Briefly activate Finder first to reset focus state
        // This ensures Ghostty properly receives keystrokes even if already frontmost
        let activateScript = """
        tell application "System Events"
            set frontmost of process "Finder" to true
            delay 0.1
        end tell
        tell application "Ghostty" to activate
        delay 0.3
        tell application "System Events"
            repeat 15 times
                if frontmost of process "Ghostty" then
                    delay 0.1
                    return "ok"
                end if
                delay 0.1
            end repeat
        end tell
        return "timeout"
        """
        
        let activateResult = runAppleScript(activateScript)
        guard activateResult == "ok" else {
            return (false, "failed to activate Ghostty: \(activateResult)")
        }
        
        // Key codes for 1-9 on US keyboard (more reliable than keystrokes)
        let keyCodes: [Character: Int] = [
            "1": 18, "2": 19, "3": 20, "4": 21, "5": 23,
            "6": 22, "7": 26, "8": 28, "9": 25
        ]
        
        // Try each tab position (Cmd+1-9)
        for key in "123456789" {
            guard let code = keyCodes[key] else { continue }
            
            let keystrokeScript = """
            tell application "System Events"
                tell process "Ghostty"
                    key code \(code) using command down
                end tell
            end tell
            """
            _ = runAppleScript(keystrokeScript)
            
            Thread.sleep(forTimeInterval: 0.15)
            
            // Check if current front tab matches
            let currentTabs = getGhosttyTabsViaCGWindowList()
            for tab in currentTabs where tab.isOnScreen {
                let currentName = tab.name.lowercased()
                let target = targetName.lowercased()
                if currentName.contains(target) || target.contains(currentName) {
                    return (true, "found tab '\(tab.name)' at Cmd+\(key)")
                }
                break
            }
        }
        
        // Do not claim success unless we actually found/switched to the requested tab.
        return (false, "activated Ghostty, but could not find exact tab '\(targetName)'")
    }
    
    // MARK: - tmux Pane Selection
    
    private func selectTmuxPaneByTTY(_ tty: String) {
        let ttyPath = tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"
        
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = ["tmux", "list-panes", "-a", "-F", "#{pane_tty} #{session_name}:#{window_index}.#{pane_index}"]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        
        do {
            try task.run()
        } catch {
            return
        }
        
        // Read output before waiting to avoid deadlock
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        
        guard let output = String(data: data, encoding: .utf8) else { return }
        
        for line in output.components(separatedBy: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }
            
            let paneTTY = String(parts[0])
            let paneTarget = String(parts[1])
            
            if paneTTY == ttyPath {
                // Select the window first
                let windowTarget = paneTarget.components(separatedBy: ".").dropLast().joined(separator: ".")
                
                let selectWindow = Process()
                selectWindow.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                selectWindow.arguments = ["tmux", "select-window", "-t", windowTarget]
                selectWindow.standardOutput = FileHandle.nullDevice
                selectWindow.standardError = FileHandle.nullDevice
                try? selectWindow.run()
                selectWindow.waitUntilExit()
                
                // Then select the pane
                let selectPane = Process()
                selectPane.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                selectPane.arguments = ["tmux", "select-pane", "-t", paneTarget]
                selectPane.standardOutput = FileHandle.nullDevice
                selectPane.standardError = FileHandle.nullDevice
                try? selectPane.run()
                selectPane.waitUntilExit()
                
                return
            }
        }
    }
    
    private func selectZellijTabForSession(session: String, cwd: String?, tty: String) {
        NSLog("JumpHandler: zellij select start: session=%@ cwd=%@ tty=%@", session, cwd ?? "nil", tty)
        
        let dumpTask = Process()
        dumpTask.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        dumpTask.arguments = ["zellij", "-s", session, "action", "dump-layout"]
        
        let pipe = Pipe()
        dumpTask.standardOutput = pipe
        dumpTask.standardError = FileHandle.nullDevice
        
        do {
            try dumpTask.run()
        } catch {
            NSLog("JumpHandler: zellij dump-layout failed: %@", error.localizedDescription)
            return
        }
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        dumpTask.waitUntilExit()
        guard let layout = String(data: data, encoding: .utf8), !layout.isEmpty else {
            NSLog("JumpHandler: zellij dump-layout returned empty output")
            return
        }
        
        struct ZellijPiTab {
            let index: Int
            let name: String
            let paneCwd: String
        }
        
        var currentTabIndex = 0
        var currentTabName = ""
        var piTabs: [ZellijPiTab] = []
        
        for raw in layout.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            
            if line.hasPrefix("tab name=") {
                currentTabIndex += 1
                if let nameStart = line.range(of: "name=\""),
                   let nameEnd = line[nameStart.upperBound...].range(of: "\"") {
                    currentTabName = String(line[nameStart.upperBound..<nameEnd.lowerBound])
                } else {
                    currentTabName = "tab-\(currentTabIndex)"
                }
                continue
            }
            
            // We only care about pi panes.
            if line.contains("pane command=\"pi\"") {
                var paneCwd = ""
                if let cwdStart = line.range(of: "cwd=\""),
                   let cwdEnd = line[cwdStart.upperBound...].range(of: "\"") {
                    paneCwd = String(line[cwdStart.upperBound..<cwdEnd.lowerBound])
                }
                piTabs.append(ZellijPiTab(index: currentTabIndex, name: currentTabName, paneCwd: paneCwd))
            }
        }
        
        guard !piTabs.isEmpty else {
            NSLog("JumpHandler: zellij no pi tabs found in layout")
            return
        }
        
        let project = cwd.map { URL(fileURLWithPath: $0).lastPathComponent.lowercased() }
        
        var target: ZellijPiTab? = nil
        if let project {
            target = piTabs.first(where: { tab in
                let pane = tab.paneCwd.lowercased()
                return pane == project || project.hasSuffix("/\(pane)") || pane.hasSuffix(project)
            })
        }
        
        // Deterministic fallback: if only one pi tab exists, use it.
        if target == nil && piTabs.count == 1 {
            target = piTabs[0]
        }
        
        guard let target else {
            let debugTabs = piTabs.map { "\($0.index):\($0.name):\($0.paneCwd)" }.joined(separator: ", ")
            NSLog("JumpHandler: zellij no unique target tab. project=%@ piTabs=[%@]", project ?? "nil", debugTabs)
            return
        }
        
        NSLog("JumpHandler: zellij switching to tab index=%d name=%@ paneCwd=%@", target.index, target.name, target.paneCwd)
        
        let goTask = Process()
        goTask.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        goTask.arguments = ["zellij", "-s", session, "action", "go-to-tab", "\(target.index)"]
        goTask.standardOutput = FileHandle.nullDevice
        goTask.standardError = FileHandle.nullDevice
        
        do {
            try goTask.run()
            goTask.waitUntilExit()
            NSLog("JumpHandler: zellij go-to-tab finished with status %d", goTask.terminationStatus)
        } catch {
            NSLog("JumpHandler: zellij go-to-tab failed: %@", error.localizedDescription)
        }
    }
    
    private func isGhosttyFrontmost() -> Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.mitchellh.ghostty"
    }
    
    private func forceActivateGhosttyFrontmost() -> Bool {
        if let ghosttyApp = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.mitchellh.ghostty"
        }) {
            _ = ghosttyApp.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
            Thread.sleep(forTimeInterval: 0.12)
            if isGhosttyFrontmost() {
                return true
            }
        }
        
        // Strong fallback for Space/Desktop weirdness
        let script = """
        tell application "System Events"
            set frontmost of process "Finder" to true
            delay 0.08
        end tell
        tell application "Ghostty" to activate
        delay 0.2
        tell application "System Events"
            repeat 12 times
                if frontmost of process "Ghostty" then
                    return "ok"
                end if
                delay 0.08
            end repeat
        end tell
        return "timeout"
        """
        let result = runAppleScript(script)
        return result == "ok" || isGhosttyFrontmost()
    }
    
    // MARK: - Helpers
    
    private func activateAndRaiseApp(_ app: NSRunningApplication) -> Bool {
        // Normal activation first
        _ = app.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
        Thread.sleep(forTimeInterval: 0.12)
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier {
            return true
        }
        
        // Accessibility fallback: raise one of the app windows directly
        let appRef = AXUIElementCreateApplication(app.processIdentifier)
        var windowsRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute as CFString, &windowsRef) == .success,
           let windows = windowsRef as? [AXUIElement],
           !windows.isEmpty {
            for window in windows {
                _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            }
            // Try activation once more after raising
            _ = app.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
            Thread.sleep(forTimeInterval: 0.08)
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier {
                return true
            }
        }
        
        // Last resort via System Events frontmost toggle (helps accessory apps)
        if let name = app.localizedName {
            let escaped = escapeForAppleScript(name)
            let script = """
            tell application "System Events"
                if exists process "\(escaped)" then
                    set frontmost of process "\(escaped)" to true
                    return "ok"
                end if
            end tell
            return "missing"
            """
            let result = runAppleScript(script)
            if result == "ok" {
                Thread.sleep(forTimeInterval: 0.08)
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier {
                    return true
                }
                return true
            }
        }
        
        return false
    }
    
    private struct TelemetryMetadata {
        let ppid: Int?
        let cwd: String?
        let sessionFile: String?
    }
    
    private func focusOwningAppFromTelemetry(forMissingPid pid: Int) -> JumpResult? {
        guard let meta = readTelemetryMetadata(for: pid) else { return nil }
        
        // First choice: parent process from telemetry (common for app-spawned workers)
        if let ppid = meta.ppid,
           let app = NSWorkspace.shared.runningApplications.first(where: { Int($0.processIdentifier) == ppid }) {
            if activateAndRaiseApp(app) {
                let name = app.localizedName ?? app.bundleIdentifier ?? "app"
                NSLog("JumpHandler: focused owning app from telemetry ppid %d (%@)", ppid, name)
                return JumpResult(
                    ok: true,
                    focused: true,
                    focusedApp: name,
                    openedShell: false,
                    message: "Focused \(name) (worker PID \(pid) exited)"
                )
            }
        }
        
        // Fallback: infer app name from cwd/session path metadata
        if let hint = appHint(fromCwd: meta.cwd) ?? appHint(fromSessionFile: meta.sessionFile),
           let app = findRunningApp(matchingHint: hint),
           activateAndRaiseApp(app) {
            let name = app.localizedName ?? app.bundleIdentifier ?? hint
            NSLog("JumpHandler: focused owning app from telemetry hint '%@' -> %@", hint, name)
            return JumpResult(
                ok: true,
                focused: true,
                focusedApp: name,
                openedShell: false,
                message: "Focused \(name) (worker PID \(pid) exited)"
            )
        }
        
        return nil
    }
    
    private func focusOwningAppForLivePid(_ pid: Int32, byPid: [Int: ProcessInfo], cwdHint: String?) -> String? {
        if let app = findOwningRunningAppInAncestry(pid: pid, byPid: byPid),
           activateAndRaiseApp(app) {
            let name = app.localizedName ?? app.bundleIdentifier ?? "app"
            NSLog("JumpHandler: focused owning app from ancestry: %@", name)
            return name
        }
        
        if let hint = appHint(fromCwd: cwdHint),
           let app = findRunningApp(matchingHint: hint),
           activateAndRaiseApp(app) {
            let name = app.localizedName ?? app.bundleIdentifier ?? hint
            NSLog("JumpHandler: focused app from cwd hint '%@' -> %@", hint, name)
            return name
        }
        
        return nil
    }
    
    private func findOwningRunningAppInAncestry(pid: Int32, byPid: [Int: ProcessInfo]) -> NSRunningApplication? {
        var current: Int32? = pid
        var seen = Set<Int32>()
        
        while let cur = current, !seen.contains(cur) {
            seen.insert(cur)
            
            if let app = NSWorkspace.shared.runningApplications.first(where: { Int($0.processIdentifier) == Int(cur) }) {
                return app
            }
            
            guard let process = byPid[Int(cur)] else { break }
            current = process.ppid > 0 ? process.ppid : nil
        }
        
        return nil
    }
    
    private func readTelemetryMetadata(for pid: Int) -> TelemetryMetadata? {
        let telemetryPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi/agent/telemetry/instances/\(pid).json")
        
        guard let data = try? Data(contentsOf: telemetryPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        
        let process = json["process"] as? [String: Any]
        let workspace = json["workspace"] as? [String: Any]
        let session = json["session"] as? [String: Any]
        
        return TelemetryMetadata(
            ppid: process?["ppid"] as? Int,
            cwd: workspace?["cwd"] as? String,
            sessionFile: session?["file"] as? String
        )
    }
    
    private func appHint(fromCwd cwd: String?) -> String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        let components = URL(fileURLWithPath: cwd).pathComponents
        if let idx = components.firstIndex(of: "Application Support"), idx + 1 < components.count {
            return components[idx + 1]
        }
        let leaf = URL(fileURLWithPath: cwd).lastPathComponent
        return leaf.isEmpty ? nil : leaf
    }
    
    private func appHint(fromSessionFile sessionFile: String?) -> String? {
        guard let sessionFile, !sessionFile.isEmpty else { return nil }
        let components = URL(fileURLWithPath: sessionFile).pathComponents
        if let idx = components.firstIndex(of: "Application Support"), idx + 1 < components.count {
            return components[idx + 1]
        }
        return nil
    }
    
    private func findRunningApp(matchingHint hint: String) -> NSRunningApplication? {
        let needle = hint.lowercased()
        
        // Prefer exact localized name
        if let app = NSWorkspace.shared.runningApplications.first(where: {
            ($0.localizedName ?? "").lowercased() == needle
        }) {
            return app
        }
        
        // Then contain match across common fields
        return NSWorkspace.shared.runningApplications.first(where: { app in
            let name = (app.localizedName ?? "").lowercased()
            let bundle = (app.bundleIdentifier ?? "").lowercased()
            let exec = (app.executableURL?.lastPathComponent ?? "").lowercased()
            return name.contains(needle) || bundle.contains(needle) || exec.contains(needle)
        })
    }
    
    private func activateApp(_ appName: String) -> Bool {
        // Use native NSRunningApplication for activation
        let bundleIdentifier = bundleId(for: appName)
        
        // Try by bundle ID first
        if !bundleIdentifier.isEmpty {
            let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            if let app = apps.first {
                return app.activate(options: [.activateIgnoringOtherApps])
            }
        }
        
        // Fallback: find by name
        if let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.localizedName?.lowercased() == appName.lowercased()
        }) {
            return app.activate(options: [.activateIgnoringOtherApps])
        }
        
        return false
    }
    
    private func escapeForAppleScript(_ s: String) -> String {
        return s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
    }
    
    private func runAppleScript(_ script: String, timeout: TimeInterval = 5.0) -> String {
        // Use NSAppleScript for in-process execution (faster than spawning osascript)
        var error: NSDictionary?
        guard let appleScript = NSAppleScript(source: script) else {
            return "error"
        }
        
        // Execute with timeout using DispatchQueue
        var result: String = "timeout"
        let semaphore = DispatchSemaphore(value: 0)
        
        DispatchQueue.global(qos: .userInitiated).async {
            let output = appleScript.executeAndReturnError(&error)
            if error == nil {
                result = output.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "ok"
            } else {
                result = "error"
            }
            semaphore.signal()
        }
        
        let waitResult = semaphore.wait(timeout: .now() + timeout)
        if waitResult == .timedOut {
            return "timeout"
        }
        
        return result
    }
}
