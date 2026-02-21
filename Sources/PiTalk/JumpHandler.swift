import Foundation
import AppKit
import CoreGraphics
import os.log

/// Handles jumping to terminal windows for a given PID
/// Ported from pi-statusbar's daemon logic with all fixes
final class JumpHandler {
    
    private static let logger = Logger(subsystem: "com.pitalk", category: "JumpHandler")
    
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
            if let muxType = muxInfo?.type {
                searchHints.append(muxType)
            }
            NSLog("JumpHandler: %@", "Step 4 - calling focusGhosttyViaCGWindowList with hints=\(searchHints)")
            let (success, msg) = focusGhosttyViaCGWindowList(hints: searchHints, cwd: cwd)
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
        let script = """
        if application "\(escapeForAppleScript(appName))" is running then
            return "yes"
        end if
        return "no"
        """
        return runAppleScript(script) == "yes"
    }
    
    private func focusTerminalByTTY(_ tty: String) -> Bool {
        let t = escapeForAppleScript(tty)
        
        // Try iTerm2 first (if running)
        let itermScript = """
        try
            if application "iTerm2" is running then
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
            end if
        end try
        return "no"
        """
        if runAppleScript(itermScript) == "ok" {
            return true
        }
        
        // Try Terminal (if running)
        let terminalScript = """
        try
            if application "Terminal" is running then
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
            end if
        end try
        return "no"
        """
        return runAppleScript(terminalScript) == "ok"
    }
    
    private func focusTerminalByTitleHint(_ hint: String) -> Bool {
        let h = escapeForAppleScript(hint)
        
        let script = """
        set needle to "\(h)"
        try
            if application "iTerm2" is running then
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
            end if
        end try
        try
            if application "Terminal" is running then
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
            end if
        end try
        return "no"
        """
        return runAppleScript(script) == "ok"
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
    
    private func focusGhosttyViaCGWindowList(hints: [String], cwd: String?) -> (Bool, String?) {
        NSLog("JumpHandler: %@", "focusGhosttyViaCGWindowList starting...")
        let tabs = getGhosttyTabsViaCGWindowList()
        NSLog("JumpHandler: %@", "found \(tabs.count) Ghostty tabs")
        
        guard !tabs.isEmpty else {
            return (false, "no Ghostty tabs found")
        }
        
        // Build search terms from hints and cwd
        var searchTerms = hints.map { $0.lowercased() }
        if let cwd = cwd {
            searchTerms.append(URL(fileURLWithPath: cwd).lastPathComponent.lowercased())
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
        let script = """
        try
            tell application "\(escapeForAppleScript(appName))" to activate
            delay 0.05
            tell application "System Events"
                if exists process "\(escapeForAppleScript(appName))" then
                    tell process "\(escapeForAppleScript(appName))"
                        set frontmost to true
                        try
                            if (count of windows) > 0 then
                                perform action "AXRaise" of window 1
                            end if
                        end try
                    end tell
                end if
            end tell
            return "ok"
        end try
        return "no"
        """
        return runAppleScript(script) == "ok"
    }
    
    private func escapeForAppleScript(_ s: String) -> String {
        return s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
    }
    
    private func runAppleScript(_ script: String, timeout: TimeInterval = 5.0) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        
        do {
            try task.run()
            
            // Wait with timeout
            let deadline = Date().addingTimeInterval(timeout)
            while task.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            
            if task.isRunning {
                task.terminate()
                return "timeout"
            }
        } catch {
            return "error"
        }
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "no"
    }
}
