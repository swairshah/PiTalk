import Foundation
import AppKit
import CoreGraphics
import os.log

/// Handles jumping to terminal windows for a given PID
/// Ported from pi-statusbar's daemon logic
final class JumpHandler {
    
    private static let logger = Logger(subsystem: "com.pitalk", category: "JumpHandler")
    
    struct JumpResult {
        let ok: Bool
        let focused: Bool
        let focusedApp: String?
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
    
    // MARK: - Public API
    
    /// Async jump - doesn't block the main thread
    static func jumpAsync(to pid: Int, completion: @escaping (JumpResult) -> Void) {
        print("PiTalk Jump: jumpAsync called for PID \(pid)")
        DispatchQueue.global(qos: .userInitiated).async {
            let result = jump(to: pid)
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }
    
    static func jump(to pid: Int) -> JumpResult {
        print("PiTalk Jump: jump called for PID \(pid)")
        let handler = JumpHandler()
        return handler.performJump(pid: pid)
    }
    
    // MARK: - Jump Implementation
    
    private func performJump(pid: Int) -> JumpResult {
        print("PiTalk Jump: " + "performJump: scanning processes...")
        let processes = scanProcesses()
        let byPid = Dictionary(uniqueKeysWithValues: processes.map { (Int($0.pid), $0) })
        print("PiTalk Jump: " + "performJump: found \(processes.count) processes")
        
        // Find the target process
        guard let targetProcess = byPid[pid] else {
            print("PiTalk Jump WARNING: " + "performJump: process not found: \(pid)")
            return JumpResult(ok: false, focused: false, focusedApp: nil, message: "Process not found: \(pid)")
        }
        
        // Get cwd for hints
        print("PiTalk Jump: " + "performJump: getting cwd for \(pid)...")
        let cwd = getCwd(for: pid)
        print("PiTalk Jump: " + "performJump: cwd = \(cwd ?? "nil")")
        
        // Detect terminal app from process ancestry
        print("PiTalk Jump: " + "performJump: detecting terminal app...")
        let (terminalApp, _) = detectTerminalApp(pid: Int32(pid), byPid: byPid)
        print("PiTalk Jump: " + "performJump: terminalApp = \(terminalApp ?? "nil")")
        
        // Build focus hints from session name, cwd, tty
        var hints: [String] = []
        if let cwd = cwd {
            hints.append(URL(fileURLWithPath: cwd).lastPathComponent)
        }
        if targetProcess.tty != "??" {
            hints.append(targetProcess.tty)
        }
        print("PiTalk Jump: " + "performJump: hints = \(hints)")
        
        // Try to focus the terminal
        var focused = false
        var focusedApp: String? = nil
        var message: String? = nil
        
        // Check if this is a Ghostty candidate
        let isGhosttyCandidate = terminalApp == "Ghostty" || detectTerminalApp(pid: Int32(pid), byPid: byPid).0 == "Ghostty"
        print("PiTalk Jump: " + "performJump: isGhosttyCandidate = \(isGhosttyCandidate)")
        
        // Strategy 1: Try AppleScript-based window focusing first
        if let app = terminalApp {
            print("PiTalk Jump: " + "performJump: Strategy 1 - trying AppleScript for \(app)...")
            focusedApp = app
            if app == "Ghostty" {
                focused = focusGhosttyWindow(hints: hints)
            } else {
                focused = activateApp(app)
            }
            print("PiTalk Jump: " + "performJump: Strategy 1 result: focused = \(focused)")
        }
        
        // Strategy 2: For Ghostty, use CGWindowList-based tab switching
        // This works when System Events can't see Ghostty windows
        if !focused && isGhosttyCandidate {
            print("PiTalk Jump: " + "performJump: Strategy 2 - trying CGWindowList for Ghostty...")
            let (success, msg) = focusGhosttyViaCGWindowList(hints: hints, cwd: cwd)
            focused = success
            focusedApp = "Ghostty"
            message = msg
            print("PiTalk Jump: " + "performJump: Strategy 2 result: focused = \(focused), msg = \(msg ?? "nil")")
        }
        
        // Strategy 3: Try common terminal apps as fallback
        if !focused {
            print("PiTalk Jump: " + "performJump: Strategy 3 - trying common terminal apps...")
            for app in ["Ghostty", "iTerm2", "Terminal"] {
                print("PiTalk Jump: " + "performJump: trying \(app)...")
                if activateApp(app) {
                    focused = true
                    focusedApp = app
                    print("PiTalk Jump: " + "performJump: \(app) activated successfully")
                    break
                }
            }
        }
        
        if focused {
            print("PiTalk Jump: " + "performJump: SUCCESS - focused \(focusedApp ?? "unknown")")
            return JumpResult(ok: true, focused: true, focusedApp: focusedApp, message: message ?? "Focused \(focusedApp ?? "terminal")")
        } else {
            print("PiTalk Jump WARNING: " + "performJump: FAILED - could not focus any terminal")
            return JumpResult(ok: true, focused: false, focusedApp: nil, message: "Could not focus terminal for PID \(pid)")
        }
    }
    
    // MARK: - Process Scanning
    
    private func scanProcesses() -> [ProcessInfo] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-axo", "pid=,ppid=,comm=,tty=,args="]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return []
        }
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
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
            task.waitUntilExit()
        } catch {
            return nil
        }
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return nil }
        
        for line in output.components(separatedBy: "\n") {
            if line.hasPrefix("n") {
                return String(line.dropFirst())
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
    
    // MARK: - CGWindowList-based Ghostty Tab Detection
    
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
        print("PiTalk Jump: " + "focusGhosttyViaCGWindowList: getting tabs...")
        let tabs = getGhosttyTabsViaCGWindowList()
        print("PiTalk Jump: " + "focusGhosttyViaCGWindowList: found \(tabs.count) tabs")
        
        guard !tabs.isEmpty else {
            return (false, "no Ghostty tabs found via CGWindowList")
        }
        
        // Build search terms from hints and cwd
        var searchTerms = hints.map { $0.lowercased() }
        if let cwd = cwd {
            searchTerms.append(URL(fileURLWithPath: cwd).lastPathComponent.lowercased())
        }
        print("PiTalk Jump: " + "focusGhosttyViaCGWindowList: searchTerms = \(searchTerms)")
        
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
            print("PiTalk Jump: " + "focusGhosttyViaCGWindowList: no match found, available: \(tabNames)")
            return (false, "no tab matched, available: \(tabNames)")
        }
        
        print("PiTalk Jump: " + "focusGhosttyViaCGWindowList: matched tab '\(targetName)'")
        
        // Activate Ghostty and wait for it to be frontmost
        print("PiTalk Jump: " + "focusGhosttyViaCGWindowList: activating Ghostty...")
        let activateScript = """
        tell application "Ghostty" to activate
        delay 0.2
        tell application "System Events"
            repeat 10 times
                if frontmost of process "Ghostty" then
                    return "ok"
                end if
                delay 0.1
            end repeat
        end tell
        return "timeout"
        """
        
        let activateResult = runAppleScript(activateScript)
        print("PiTalk Jump: " + "focusGhosttyViaCGWindowList: activate result = \(activateResult)")
        
        guard activateResult == "ok" else {
            return (false, "failed to activate Ghostty: \(activateResult)")
        }
        
        // Try each tab position (Cmd+1-9) and check if we found the right one
        print("PiTalk Jump: " + "focusGhosttyViaCGWindowList: trying tab positions 1-9...")
        for key in "123456789" {
            print("PiTalk Jump: " + "focusGhosttyViaCGWindowList: trying Cmd+\(key)")
            // Send keystroke to Ghostty
            let keystrokeScript = """
            tell application "System Events"
                tell process "Ghostty"
                    keystroke "\(key)" using command down
                end tell
            end tell
            """
            _ = runAppleScript(keystrokeScript)
            
            // Brief pause to let window update
            Thread.sleep(forTimeInterval: 0.1)
            
            // Check if current front tab matches
            let currentTabs = getGhosttyTabsViaCGWindowList()
            for tab in currentTabs where tab.isOnScreen {
                let currentName = tab.name.lowercased()
                let target = targetName.lowercased()
                if currentName.contains(target) || target.contains(currentName) {
                    print("PiTalk Jump: " + "focusGhosttyViaCGWindowList: SUCCESS at Cmd+\(key)")
                    return (true, "found tab '\(tab.name)' at Cmd+\(key)")
                }
                // Found active tab but doesn't match, continue to next position
                break
            }
        }
        
        // If we exhausted all positions, we at least activated Ghostty
        print("PiTalk Jump: " + "focusGhosttyViaCGWindowList: exhausted all positions, Ghostty is active but exact tab not found")
        return (false, "activated Ghostty, could not find exact tab '\(targetName)'")
    }
    
    // MARK: - AppleScript-based Window Focusing
    
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
    
    private func focusGhosttyWindow(hints: [String]) -> Bool {
        guard !hints.isEmpty else { return false }
        
        let hintList = hints.map { "\"\(escapeForAppleScript($0))\"" }.joined(separator: ", ")
        
        let script = """
        set needles to {\(hintList)}
        try
            tell application "System Events"
                if not (exists process "Ghostty") then
                    return "no"
                end if
                tell process "Ghostty"
                    repeat with w in windows
                        try
                            set n to (name of w as text)
                            repeat with needle in needles
                                ignoring case
                                    if n contains (needle as text) then
                                        tell application "Ghostty" to activate
                                        set frontmost to true
                                        perform action "AXRaise" of w
                                        return "ok"
                                    end if
                                end ignoring
                            end repeat
                        end try
                    end repeat
                end tell
            end tell
        end try
        return "no"
        """
        return runAppleScript(script) == "ok"
    }
    
    // MARK: - Helpers
    
    private func escapeForAppleScript(_ s: String) -> String {
        return s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
    }
    
    private func runAppleScript(_ script: String, timeout: TimeInterval = 3.0) -> String {
        let scriptPreview = script.prefix(50).replacingOccurrences(of: "\n", with: " ")
        print("PiTalk Jump: " + "runAppleScript: starting '\(scriptPreview)...'")
        
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        
        let startTime = Date()
        
        do {
            try task.run()
            
            // Wait with timeout
            let deadline = Date().addingTimeInterval(timeout)
            while task.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            
            if task.isRunning {
                print("PiTalk Jump WARNING: " + "runAppleScript: TIMEOUT after \(timeout)s, terminating")
                task.terminate()
                return "timeout"
            }
        } catch {
            print("PiTalk Jump ERROR: " + "runAppleScript: error launching: \(error.localizedDescription)")
            return "error"
        }
        
        let elapsed = Date().timeIntervalSince(startTime)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "no"
        print("PiTalk Jump: " + "runAppleScript: completed in \(String(format: "%.2f", elapsed))s, result = '\(output)'")
        return output
    }
}
