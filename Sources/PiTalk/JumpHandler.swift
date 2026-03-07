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
    
    struct GhosttyTerminalInfo {
        let id: String
        let name: String
        let cwd: String
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
        
        // Fast path: Try Ghostty scripting API first (v1.3.0+).
        // This is the most direct route — queries Ghostty for all terminals,
        // matches by PID screen content, and focuses directly. No process scanning,
        // no cmux, no accessibility tab-clicking needed.
        if isAppRunning("Ghostty") {
            let cwd = getCwd(for: pid)
            if jumpViaGhosttyScripting(pid: pid, cwd: cwd, hints: []) {
                return JumpResult(ok: true, focused: true, focusedApp: "Ghostty", openedShell: false,
                                message: "Focused Ghostty for PID \(pid)")
            }
        }
        
        // Legacy path: fall back to process scanning + cmux + AX for older Ghostty,
        // non-Ghostty terminals, tmux/zellij, and other scenarios.
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
        
        // Step 0: Try cmux (Ghostty multiplexer) first — most reliable when available
        if isCmuxAvailable() {
            NSLog("JumpHandler: cmux socket detected, trying cmux-based jump for PID %d", pid)
            if let result = jumpViaCmux(pid: pid) {
                NSLog("JumpHandler: cmux jump succeeded: %@", result.message ?? "")
                return result
            }
            NSLog("JumpHandler: cmux jump did not find PID %d, falling back to legacy methods", pid)
        }
        
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
        
        // Step 4 (legacy fallback): Ghostty PID-based pane focus (for raw splits, no mux)
        // This is the most reliable method when pi shows PID in status bar
        if !focused && terminalApp == "Ghostty" && muxInfo == nil {
            NSLog("JumpHandler: %@", "Step 4 - trying PID-based Ghostty pane focus for PID \(pid)")
            if focusGhosttyPaneByPID(pid) {
                focused = true
                focusedApp = "Ghostty"
                NSLog("JumpHandler: %@", "Step 4 - PID-based focus succeeded")
            }
        }
        
        // Step 5 (legacy fallback): Ghostty CGWindowList-based tab switching
        // Fallback for when PID search fails or for mux scenarios
        NSLog("JumpHandler: %@", "Step 5 check: focused=\(focused), terminalApp=\(terminalApp ?? "nil"), muxInfo=\(muxInfo != nil)")
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
        
        // Step 6: If tmux, switch to the correct pane
        if focused && muxInfo?.type == "tmux" && tty != "??" {
            selectTmuxPaneByTTY(tty)
        }
        
        // Step 6b: If zellij, deterministically switch to tab containing the pi pane for this cwd
        if focused && muxInfo?.type == "zellij", let zellijSession = muxInfo?.session {
            selectZellijTabForSession(session: zellijSession, cwd: cwd, tty: tty)
        }
        
        // Step 7: Non-terminal fallback (eg. app-hosted pi via RPC/subprocess)
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
    
    // MARK: - cmux (Ghostty Multiplexer) Support
    
    /// Default cmux Unix socket path
    private static let cmuxSocketPath = "/tmp/cmux.sock"
    
    /// Check if cmux is available (socket exists)
    private func isCmuxAvailable() -> Bool {
        return FileManager.default.fileExists(atPath: JumpHandler.cmuxSocketPath)
    }
    
    /// A persistent cmux socket connection that supports sending multiple commands.
    /// cmux checks process ancestry on connect, so external apps must authenticate
    /// with a password (set in cmux Settings > Socket > Password mode).
    private class CmuxConnection {
        private let fd: Int32
        
        private init(fd: Int32) {
            self.fd = fd
        }
        
        deinit {
            close(fd)
        }
        
        /// Connect to the cmux socket and optionally authenticate
        static func connect(socketPath: String = JumpHandler.cmuxSocketPath, password: String? = nil) -> CmuxConnection? {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else {
                NSLog("JumpHandler: cmux socket() failed: %d", errno)
                return nil
            }
            
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
                socketPath.withCString { cstr in
                    _ = strcpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self), cstr)
                }
            }
            
            let connectResult = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            
            guard connectResult == 0 else {
                NSLog("JumpHandler: cmux connect() failed: %d", errno)
                close(fd)
                return nil
            }
            
            let conn = CmuxConnection(fd: fd)
            
            // Authenticate if password provided
            if let password = password, !password.isEmpty {
                let authResponse = conn.send("auth \(password)")
                if let resp = authResponse, resp.contains("ERROR") {
                    NSLog("JumpHandler: cmux auth failed: %@", resp)
                    return nil
                }
            }
            
            // Test the connection with a ping
            let pingResponse = conn.send("ping")
            if pingResponse == nil || pingResponse?.contains("Access denied") == true || pingResponse?.contains("ERROR") == true {
                NSLog("JumpHandler: cmux connection rejected: %@", pingResponse ?? "nil")
                return nil
            }
            
            return conn
        }
        
        /// Send a command and read the response (newline-delimited protocol).
        /// The cmux socket keeps the connection open for multiple commands.
        func send(_ command: String) -> String? {
            let msg = command + "\n"
            let sent = msg.withCString { cstr -> Int in
                Darwin.send(fd, cstr, msg.utf8.count, 0)
            }
            guard sent > 0 else {
                NSLog("JumpHandler: cmux send failed for '%@': %d", command, errno)
                return nil
            }
            
            // Read response until newline (each response is one line)
            var responseData = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            
            while true {
                let bytesRead = recv(fd, &buffer, buffer.count, 0)
                if bytesRead <= 0 { break }
                responseData.append(contentsOf: buffer[0..<bytesRead])
                // Check if we have a complete response (ends with newline)
                if buffer[bytesRead - 1] == 0x0A { break }
            }
            
            guard let response = String(data: responseData, encoding: .utf8) else { return nil }
            let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
            
            if trimmed.hasPrefix("ERROR:") {
                NSLog("JumpHandler: cmux '%@' -> %@", command, trimmed)
                return nil
            }
            
            return trimmed
        }
    }
    
    /// Send a single command to the cmux socket (opens a new connection each time).
    /// For multi-command flows, use CmuxConnection directly.
    private func cmuxCommand(_ command: String) -> String? {
        guard let conn = CmuxConnection.connect() else { return nil }
        return conn.send(command)
    }
    
    /// Jump to a PID using cmux: scan all surfaces across workspaces for the πid pattern.
    /// Uses a single persistent socket connection for all commands.
    private func jumpViaCmux(pid: Int) -> JumpResult? {
        let searchPattern = "πid\(pid) "
        
        // Open a persistent connection (authenticates if password is configured)
        guard let conn = CmuxConnection.connect() else {
            NSLog("JumpHandler: cmux connection failed (socket may require password — set in cmux Settings)")
            return nil
        }
        
        // 1. Get current workspace so we can restore if not found
        guard let currentWs = conn.send("current_workspace") else {
            NSLog("JumpHandler: cmux current_workspace failed")
            return nil
        }
        
        // 2. List all workspaces
        guard let wsOutput = conn.send("list_workspaces") else {
            NSLog("JumpHandler: cmux list_workspaces failed")
            return nil
        }
        
        // Parse workspace list: "* 0: <UUID> <title>" or "  1: <UUID> <title>"
        struct WsInfo {
            let index: Int
            let id: String
        }
        var workspaces: [WsInfo] = []
        for line in wsOutput.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "* ", with: "")
            let parts = trimmed.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let idx = Int(parts[0].trimmingCharacters(in: .whitespaces)) else { continue }
            let rest = parts[1].trimmingCharacters(in: .whitespaces)
            let uuid = String(rest.split(separator: " ", maxSplits: 1).first ?? "")
            workspaces.append(WsInfo(index: idx, id: uuid))
        }
        
        NSLog("JumpHandler: cmux found %d workspaces", workspaces.count)
        
        struct CmuxTarget {
            let workspaceIndex: Int
            let surfaceIndex: Int
        }
        
        var target: CmuxTarget? = nil
        
        // 3. For each workspace, select it, list surfaces, read screen content
        for ws in workspaces {
            _ = conn.send("select_workspace \(ws.index)")
            
            guard let surfOutput = conn.send("list_surfaces") else { continue }
            
            // Parse surface list: "  0: <UUID>" or "* 2: <UUID> [selected]"
            var surfaceIndexes: [Int] = []
            for line in surfOutput.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "* ", with: "")
                let parts = trimmed.split(separator: ":", maxSplits: 1)
                guard parts.count >= 1, let idx = Int(parts[0].trimmingCharacters(in: .whitespaces)) else { continue }
                surfaceIndexes.append(idx)
            }
            
            for surfIdx in surfaceIndexes {
                guard let screen = conn.send("read_screen \(surfIdx) --lines 3") else { continue }
                
                if screen.contains(searchPattern) {
                    target = CmuxTarget(workspaceIndex: ws.index, surfaceIndex: surfIdx)
                    NSLog("JumpHandler: cmux found PID %d in workspace %d surface %d", pid, ws.index, surfIdx)
                    break
                }
            }
            
            if target != nil { break }
        }
        
        guard let target = target else {
            // Restore original workspace
            _ = conn.send("select_workspace \(currentWs)")
            return nil
        }
        
        // 4. Select workspace and focus surface
        _ = conn.send("select_workspace \(target.workspaceIndex)")
        _ = conn.send("focus_surface \(target.surfaceIndex)")
        
        // 5. Bring cmux to the front (not Ghostty — cmux is its own app)
        _ = activateCmux()
        
        NSLog("JumpHandler: cmux jump complete: workspace=%d, surface=%d", target.workspaceIndex, target.surfaceIndex)
        
        return JumpResult(
            ok: true,
            focused: true,
            focusedApp: "cmux",
            openedShell: false,
            message: "Focused workspace \(target.workspaceIndex) surface \(target.surfaceIndex) via cmux"
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
    
    // MARK: - Ghostty Native Scripting API (v1.3.0+)
    
    /// Query all Ghostty terminals via the native AppleScript scripting API.
    /// Returns nil if the scripting API is not available (older Ghostty versions).
    /// Uses runAppleScriptRaw to preserve case (Ghostty terminal IDs are case-sensitive UUIDs).
    private func queryGhosttyTerminals() -> [GhosttyTerminalInfo]? {
        let script = """
        tell application id "com.mitchellh.ghostty"
            set allTerms to terminals
            if (count of allTerms) is 0 then return ""
            set output to ""
            repeat with t in allTerms
                set output to output & id of t & "|||" & name of t & "|||" & working directory of t & linefeed
            end repeat
            return output
        end tell
        """
        
        guard let result = runAppleScriptRaw(script) else {
            return nil
        }
        
        var terminals: [GhosttyTerminalInfo] = []
        for line in result.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.components(separatedBy: "|||")
            guard parts.count >= 3 else { continue }
            terminals.append(GhosttyTerminalInfo(
                id: parts[0].trimmingCharacters(in: .whitespaces),
                name: parts[1].trimmingCharacters(in: .whitespaces),
                cwd: parts[2].trimmingCharacters(in: .whitespaces)
            ))
        }
        
        return terminals.isEmpty ? nil : terminals
    }
    
    /// Focus a Ghostty terminal by its ID via the native scripting API.
    /// The ID must be in its original case (Ghostty uses case-sensitive UUID matching).
    private func focusGhosttyTerminal(id: String) -> Bool {
        let escaped = escapeForAppleScript(id)
        let script = """
        tell application id "com.mitchellh.ghostty"
            focus terminal id "\(escaped)"
            activate
        end tell
        return "ok"
        """
        
        let result = runAppleScriptRaw(script)
        return result != nil
    }
    
    /// Jump to a terminal using Ghostty's native AppleScript scripting API (v1.3.0+).
    /// Matches by PID pattern in title, working directory, or hint strings.
    /// Returns true if the terminal was found and focused.
    /// Falls back gracefully (returns false) on older Ghostty versions without scripting support,
    /// or when multiple terminals match ambiguously (lets legacy PID-based search handle it).
    /// Write debug info to /tmp/jump_debug.txt for diagnosing jump issues
    private func debugLog(_ msg: String) {
        let entry = "\(Date()): \(msg)\n"
        NSLog("JumpHandler: %@", msg)
        if let data = entry.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: "/tmp/jump_debug.txt") {
                if let fh = FileHandle(forWritingAtPath: "/tmp/jump_debug.txt") {
                    fh.seekToEndOfFile()
                    fh.write(data)
                    fh.closeFile()
                }
            } else {
                FileManager.default.createFile(atPath: "/tmp/jump_debug.txt", contents: data)
            }
        }
    }
    
    private func jumpViaGhosttyScripting(pid: Int, cwd: String?, hints: [String]) -> Bool {
        debugLog("=== jumpViaGhosttyScripting START for PID \(pid), cwd=\(cwd ?? "nil") ===")
        
        guard let terminals = queryGhosttyTerminals() else {
            debugLog("Ghostty scripting API not available")
            return false
        }
        
        debugLog("queried \(terminals.count) terminals")
        for t in terminals {
            debugLog("  id=\(t.id) name='\(t.name)' cwd='\(t.cwd)'")
        }
        
        // Pass 1: Match by PID pattern in title (most precise — always unique)
        let pidPattern = "πid\(pid) "
        if let match = terminals.first(where: { $0.name.localizedCaseInsensitiveContains(pidPattern) }) {
            NSLog("JumpHandler: matched terminal by PID pattern in title: %@", match.id)
            return focusGhosttyTerminal(id: match.id)
        }
        
        // Pass 2: Match by working directory (only if unambiguous)
        if let cwd = cwd {
            // Exact CWD match
            let cwdMatches = terminals.filter { $0.cwd.caseInsensitiveCompare(cwd) == .orderedSame }
            if cwdMatches.count == 1 {
                NSLog("JumpHandler: matched terminal by unique exact CWD: %@", cwdMatches[0].id)
                return focusGhosttyTerminal(id: cwdMatches[0].id)
            } else if cwdMatches.count > 1 {
                NSLog("JumpHandler: skipping CWD match — %d terminals share CWD '%@'", cwdMatches.count, cwd)
            }
            
            // Directory name match (last path component)
            let dirName = URL(fileURLWithPath: cwd).lastPathComponent
            if !dirName.isEmpty {
                let dirMatches = terminals.filter {
                    $0.cwd.hasSuffix("/\(dirName)") || $0.cwd.caseInsensitiveCompare(dirName) == .orderedSame
                }
                if dirMatches.count == 1 {
                    NSLog("JumpHandler: matched terminal by unique dir name '%@': %@", dirName, dirMatches[0].id)
                    return focusGhosttyTerminal(id: dirMatches[0].id)
                } else if dirMatches.count > 1 {
                    NSLog("JumpHandler: skipping dir name match — %d terminals match '%@'", dirMatches.count, dirName)
                }
            }
        }
        
        // Pass 3: Match by hints in title or working directory (only if unambiguous)
        for hint in hints where !hint.isEmpty {
            let matches = terminals.filter {
                $0.name.localizedCaseInsensitiveContains(hint) || $0.cwd.localizedCaseInsensitiveContains(hint)
            }
            if matches.count == 1 {
                NSLog("JumpHandler: matched terminal by unique hint '%@': %@", hint, matches[0].id)
                return focusGhosttyTerminal(id: matches[0].id)
            } else if matches.count > 1 {
                NSLog("JumpHandler: skipping hint '%@' — %d terminals match", hint, matches.count)
            }
        }
        
        // Pass 4: Ambiguous match — focus each candidate and check screen content for πid pattern.
        // Uses scripting API for focus (simpler than AX tab clicking) + AX only for reading content.
        let candidates: [GhosttyTerminalInfo]
        if let cwd = cwd {
            // Narrow to terminals matching CWD
            let cwdCandidates = terminals.filter { $0.cwd.caseInsensitiveCompare(cwd) == .orderedSame }
            candidates = cwdCandidates.isEmpty ? terminals : cwdCandidates
        } else {
            candidates = terminals
        }
        
        if candidates.count > 1 {
            debugLog("Pass 4 — checking \(candidates.count) candidates for πid\(pid) via screen content")
            for (idx, candidate) in candidates.enumerated() {
                debugLog("Pass 4 candidate \(idx): focusing \(candidate.id) name='\(candidate.name)'")
                if focusGhosttyTerminal(id: candidate.id) {
                    Thread.sleep(forTimeInterval: 0.3) // Wait for terminal content to render
                    let found = ghosttyFocusedWindowContainsPID(pid)
                    debugLog("Pass 4 candidate \(idx): focus OK, screen contains πid\(pid)? \(found)")
                    if found {
                        debugLog("Pass 4 MATCHED: \(candidate.id)")
                        return true
                    }
                } else {
                    debugLog("Pass 4 candidate \(idx): focus FAILED")
                }
            }
            debugLog("Pass 4 — πid\(pid) not found in any candidate's screen content")
        } else {
            debugLog("Pass 4 skipped — candidates.count=\(candidates.count)")
        }
        
        debugLog("no match via scripting API — falling back to legacy")
        return false
    }
    
    /// Check if Ghostty's currently focused window contains the πid pattern in its screen content.
    /// Used to disambiguate when multiple terminals share the same CWD/title.
    private func ghosttyFocusedWindowContainsPID(_ pid: Int) -> Bool {
        let searchPattern = "πid\(pid) "
        
        guard let ghosttyApp = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.mitchellh.ghostty"
        }) else {
            debugLog("ghosttyFocusedWindowContainsPID: Ghostty not running")
            return false
        }
        
        let appRef = AXUIElementCreateApplication(ghosttyApp.processIdentifier)
        
        // Get the focused window
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appRef, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let window = windowRef as! AXUIElement? else {
            return false
        }
        
        // Recursively find all text areas
        var textAreas: [AXUIElement] = []
        func findTextAreas(in element: AXUIElement, depth: Int = 0) {
            guard depth < 10 else { return }
            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
            if (roleRef as? String) == "AXTextArea" {
                textAreas.append(element)
            }
            var childrenRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
               let children = childrenRef as? [AXUIElement] {
                for child in children {
                    findTextAreas(in: child, depth: depth + 1)
                }
            }
        }
        
        findTextAreas(in: window)
        
        debugLog("ghosttyFocusedWindowContainsPID(\(pid)): found \(textAreas.count) text areas")
        for (i, textArea) in textAreas.enumerated() {
            var valueRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(textArea, kAXValueAttribute as CFString, &valueRef) == .success,
                  let value = valueRef as? String else {
                debugLog("  textArea[\(i)]: no value")
                continue
            }
            // Check last 200 chars (status bar area)
            let checkRange = value.count > 200 ? String(value.suffix(200)) : value
            let escapedCheck = checkRange.replacingOccurrences(of: "\n", with: "\\n")
            debugLog("  textArea[\(i)]: len=\(value.count), last200='\(escapedCheck)'")
            debugLog("  textArea[\(i)]: contains '\(searchPattern)'? \(checkRange.contains(searchPattern))")
            if checkRange.contains(searchPattern) {
                return true
            }
        }
        
        debugLog("ghosttyFocusedWindowContainsPID(\(pid)): NOT FOUND")
        return false
    }
    
    // MARK: - Ghostty CGWindowList-based Tab Switching (Legacy Fallback)
    
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
    
    // MARK: - Ghostty PID-based Pane Focus
    
    /// Focus a Ghostty split pane by searching for PID in the status bar area.
    /// Returns true if the pane was found and focused.
    private func focusGhosttyPaneByPID(_ pid: Int) -> Bool {
        NSLog("JumpHandler: focusGhosttyPaneByPID starting for PID %d", pid)
        
        guard let ghosttyApp = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.mitchellh.ghostty"
        }) else {
            NSLog("JumpHandler: Ghostty not running")
            return false
        }
        
        // Robustly activate Ghostty (handles Space/Desktop switching)
        _ = forceActivateGhosttyFrontmost()
        
        let appRef = AXUIElementCreateApplication(ghosttyApp.processIdentifier)
        
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement],
              !windows.isEmpty else {
            NSLog("JumpHandler: Could not get Ghostty windows")
            return false
        }
        
        // Status bar format: πid{PID} followed by space (unique prefix for reliable matching)
        // The trailing space ensures we don't match log output that prints the pattern
        let searchPattern = "πid\(pid) "
        
        // Collect tab radio buttons across ALL windows (not just the first)
        var allWindowTabs: [(window: AXUIElement, tabs: [AXUIElement])] = []
        
        for window in windows {
            var childrenRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXChildrenAttribute as CFString, &childrenRef) == .success,
                  let children = childrenRef as? [AXUIElement] else {
                continue
            }
            
            // Find tab group
            var tabGroup: AXUIElement?
            for child in children {
                var roleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleRef)
                if (roleRef as? String) == "AXTabGroup" {
                    tabGroup = child
                    break
                }
            }
            
            guard let tabGroup else { continue }
            
            var tabsRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(tabGroup, kAXChildrenAttribute as CFString, &tabsRef) == .success,
                  let tabs = tabsRef as? [AXUIElement] else {
                continue
            }
            
            let radioButtons = tabs.filter { tab in
                var roleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(tab, kAXRoleAttribute as CFString, &roleRef)
                return (roleRef as? String) == "AXRadioButton"
            }
            
            if !radioButtons.isEmpty {
                allWindowTabs.append((window: window, tabs: radioButtons))
            }
        }
        
        let totalTabs = allWindowTabs.reduce(0) { $0 + $1.tabs.count }
        NSLog("JumpHandler: Found %d tabs across %d windows to search", totalTabs, allWindowTabs.count)
        
        // Helper to get all text areas from a specific window and check for PID
        func searchWindowForPID(_ targetWindow: AXUIElement) -> AXUIElement? {
            // Find all text areas recursively
            var textAreas: [AXUIElement] = []
            func findTextAreas(in element: AXUIElement, depth: Int = 0) {
                guard depth < 10 else { return }
                
                var roleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
                if (roleRef as? String) == "AXTextArea" {
                    textAreas.append(element)
                }
                
                var childrenRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
                   let children = childrenRef as? [AXUIElement] {
                    for child in children {
                        findTextAreas(in: child, depth: depth + 1)
                    }
                }
            }
            
            var contentRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(targetWindow, kAXChildrenAttribute as CFString, &contentRef) == .success,
                  let content = contentRef as? [AXUIElement] else {
                return nil
            }
            
            for child in content {
                findTextAreas(in: child)
            }
            
            NSLog("JumpHandler: Searching %d text areas for PID %d", textAreas.count, pid)
            
            // Check each text area for the PID pattern
            // Note: Ghostty only exposes text content for the focused pane via AX API
            for textArea in textAreas {
                var valueRef: CFTypeRef?
                guard AXUIElementCopyAttributeValue(textArea, kAXValueAttribute as CFString, &valueRef) == .success,
                      let value = valueRef as? String else {
                    continue
                }
                
                // Check last 200 chars (status bar area)
                let checkRange = value.count > 200 ? String(value.suffix(200)) : value
                
                if checkRange.contains(searchPattern) {
                    // Focus and return
                    AXUIElementSetAttributeValue(textArea, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                    return textArea
                }
            }
            
            return nil
        }
        
        // Focus a text area using AX API
        func focusTextArea(_ textArea: AXUIElement) -> Bool {
            let result = AXUIElementSetAttributeValue(textArea, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            NSLog("JumpHandler: Focus result: %d", result.rawValue)
            return result == .success
        }
        
        // Search across all windows and their tabs
        for (windowIdx, windowEntry) in allWindowTabs.enumerated() {
            let window = windowEntry.window
            let radioButtons = windowEntry.tabs
            
            // Raise this window so AX can read its content
            _ = AXUIElementSetAttributeValue(appRef, kAXMainWindowAttribute as CFString, window)
            _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            Thread.sleep(forTimeInterval: 0.05)
            
            // Check current tab of this window first
            if let textArea = searchWindowForPID(window) {
                _ = focusTextArea(textArea)
                NSLog("JumpHandler: Found PID %d in window %d current tab", pid, windowIdx)
                return true
            }
            
            // Click through each tab in this window
            for (i, tab) in radioButtons.enumerated() {
                let result = AXUIElementPerformAction(tab, kAXPressAction as CFString)
                if result != .success {
                    NSLog("JumpHandler: Failed to click tab %d in window %d: %d", i, windowIdx, result.rawValue)
                    continue
                }
                
                Thread.sleep(forTimeInterval: 0.1)  // Wait for content to update
                
                if let textArea = searchWindowForPID(window) {
                    _ = focusTextArea(textArea)
                    NSLog("JumpHandler: Found PID %d in window %d tab %d", pid, windowIdx, i)
                    return true
                }
            }
        }
        
        NSLog("JumpHandler: PID %d not found in any Ghostty tab/pane", pid)
        return false
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
    
    private func activateCmux() -> Bool {
        if let cmuxApp = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.cmuxterm.app"
        }) {
            _ = cmuxApp.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
            Thread.sleep(forTimeInterval: 0.12)
            return NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.cmuxterm.app"
        }
        return false
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
    
    /// Like runAppleScript but preserves original case in the output.
    /// Needed for Ghostty terminal IDs which are case-sensitive UUIDs.
    /// Uses osascript subprocess to avoid TCC "Not authorized to send Apple events" (-1743)
    /// that blocks in-process NSAppleScript from talking to apps like Ghostty.
    private func runAppleScriptRaw(_ script: String, timeout: TimeInterval = 10.0) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        
        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardInput = inPipe
        task.standardOutput = outPipe
        task.standardError = errPipe
        
        do {
            try task.run()
        } catch {
            debugLog("runAppleScriptRaw: failed to launch osascript: \(error)")
            return nil
        }
        
        // Write script to stdin
        inPipe.fileHandleForWriting.write(script.data(using: .utf8)!)
        inPipe.fileHandleForWriting.closeFile()
        
        // Read output before waiting (avoid deadlock on large output)
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        
        if task.terminationStatus != 0 {
            let errStr = String(data: errData, encoding: .utf8) ?? ""
            debugLog("runAppleScriptRaw: osascript failed (exit \(task.terminationStatus)): \(errStr)")
            return nil
        }
        
        guard let output = String(data: outData, encoding: .utf8) else { return nil }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
