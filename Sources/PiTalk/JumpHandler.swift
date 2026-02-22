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
            var searchHints = hints
            // Add mux session name first (more specific) then mux type
            if let muxSession = muxInfo?.session {
                searchHints.insert(muxSession, at: 0)  // Put session name first for priority matching
            }
            if let muxType = muxInfo?.type {
                searchHints.append(muxType)
            }
            let isTmux = muxInfo?.type == "tmux"
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
        
        // Note: We do NOT open new terminal windows as a fallback
        // If we can't focus, we just report failure
        
        return JumpResult(
            ok: true,
            focused: focused,
            focusedApp: focusedApp,
            openedShell: false,
            message: focused ? "Focused \(focusedApp ?? "terminal")" : "Could not focus terminal"
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
        
        let pid = ghosttyApp.processIdentifier
        let appRef = AXUIElementCreateApplication(pid)
        
        // Get main window
        var mainWindowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appRef, kAXMainWindowAttribute as CFString, &mainWindowRef) == .success,
              let mainWindow = mainWindowRef else {
            return (false, "Could not get main window")
        }
        
        // Find the tab group
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(mainWindow as! AXUIElement, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else {
            return (false, "Could not get window children")
        }
        
        // Look for AXTabGroup
        var tabGroup: AXUIElement?
        for child in children {
            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleRef)
            if (roleRef as? String) == "AXTabGroup" {
                tabGroup = child
                break
            }
        }
        
        guard let tabGroup = tabGroup else {
            return (false, "No tab group found")
        }
        
        // Get tabs (AXRadioButton children)
        var tabsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(tabGroup, kAXChildrenAttribute as CFString, &tabsRef) == .success,
              let tabs = tabsRef as? [AXUIElement] else {
            return (false, "Could not get tabs")
        }
        
        // Build list of tab titles for matching
        let tabsWithTitles: [(tab: AXUIElement, title: String)] = tabs.compactMap { tab in
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(tab, kAXTitleAttribute as CFString, &titleRef)
            guard let title = titleRef as? String else { return nil }
            return (tab, title)
        }
        
        // Find matching tab - iterate search terms first (priority order), then tabs
        // This ensures more specific terms (like zellij session name) match before generic ones
        for term in searchTerms {
            let termLower = term.lowercased()
            
            // First pass: prefer tabs with "π -" prefix (actual pi sessions)
            for (tab, title) in tabsWithTitles {
                if title.lowercased().contains(termLower) && title.hasPrefix("π -") {
                    let result = AXUIElementPerformAction(tab, kAXPressAction as CFString)
                    if result == .success {
                        return (true, "Selected tab '\(title)' via Accessibility API (matched '\(term)')")
                    } else {
                        return (false, "Failed to click tab: \(result.rawValue)")
                    }
                }
            }
            
            // Second pass: any matching tab
            for (tab, title) in tabsWithTitles {
                if title.lowercased().contains(termLower) {
                    let result = AXUIElementPerformAction(tab, kAXPressAction as CFString)
                    if result == .success {
                        return (true, "Selected tab '\(title)' via Accessibility API (matched '\(term)')")
                    } else {
                        return (false, "Failed to click tab: \(result.rawValue)")
                    }
                }
            }
        }
        
        // Fallback for tmux: try "generic" tabs (not pi sessions, not paths, not zellij)
        // This handles cases where the tmux tab was manually renamed
        if isTmux {
            NSLog("JumpHandler: tmux fallback - looking for generic tabs")
            for (tab, title) in tabsWithTitles {
                let isPiSession = title.hasPrefix("π -")
                let isZellij = title.contains("|")
                let isPath = title.hasPrefix("…/") || title.hasPrefix("/")
                let isEmpty = title.isEmpty
                let isGeneric = !isPiSession && !isZellij && !isPath && !isEmpty
                
                if isGeneric {
                    NSLog("JumpHandler: trying generic tab '\(title)'")
                    let result = AXUIElementPerformAction(tab, kAXPressAction as CFString)
                    if result == .success {
                        return (true, "Selected generic tab '\(title)' via tmux fallback")
                    }
                }
            }
        }
        
        let tabTitles = tabsWithTitles.map { $0.title }
        return (false, "No matching tab found, available: \(tabTitles)")
    }
    
    private func focusGhosttyViaCGWindowList(hints: [String], cwd: String?, isTmux: Bool = false) -> (Bool, String?) {
        NSLog("JumpHandler: %@", "focusGhosttyViaCGWindowList starting...")
        
        // Build search terms from hints and cwd
        var searchTerms = hints.map { $0.lowercased() }
        if let cwd = cwd {
            searchTerms.append(URL(fileURLWithPath: cwd).lastPathComponent.lowercased())
        }
        
        // First, activate Ghostty
        if let ghosttyApp = NSWorkspace.shared.runningApplications.first(where: { 
            $0.bundleIdentifier == "com.mitchellh.ghostty" 
        }) {
            ghosttyApp.activate()
            Thread.sleep(forTimeInterval: 0.1)
        }
        
        // Try Accessibility API first (faster, more reliable)
        let (axSuccess, axMsg) = focusGhosttyTabViaAccessibility(searchTerms: searchTerms, isTmux: isTmux)
        if axSuccess {
            NSLog("JumpHandler: %@", "Accessibility API success: \(axMsg ?? "")")
            return (true, axMsg)
        }
        NSLog("JumpHandler: %@", "Accessibility API failed: \(axMsg ?? ""), falling back to keystrokes")
        
        // Fallback to CGWindowList + keystrokes
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
        
        // We activated Ghostty but couldn't find exact tab - still considered success
        // since the user is at least in Ghostty now
        return (true, "activated Ghostty, could not find exact tab '\(targetName)'")
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
    
    // MARK: - Helpers
    
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
