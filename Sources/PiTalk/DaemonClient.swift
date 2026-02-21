import Foundation
import Darwin

// Debug logging - only prints when PITALK_DEBUG=1
fileprivate let debugEnabled = ProcessInfo.processInfo.environment["PITALK_DEBUG"] == "1"
fileprivate func debugLog(_ message: String) {
    if debugEnabled {
        print(message)
    }
}

/// Client for communicating with pi-statusd daemon
/// Reused from pi-statusbar
enum DaemonClient {
    private static let socketPath = (NSHomeDirectory() as NSString).appendingPathComponent(".pi/agent/statusd.sock")

    struct StatusResponse: Decodable {
        let ok: Bool
        let timestamp: Int?
        let agents: [AgentState]?
        let summary: StatusSummary?
        let source: String?
        let error: String?
    }

    struct AgentState: Decodable, Identifiable {
        let pid: Int32
        let ppid: Int32
        let state: String
        let tty: String
        let cpu: Double
        let cwd: String?
        let activity: String
        let confidence: String
        let mux: String?
        let muxSession: String?
        let clientPid: Int32?
        let attachedWindow: Bool?
        let terminalApp: String?

        enum CodingKeys: String, CodingKey {
            case pid, ppid, state, tty, cpu, cwd, activity, confidence, mux
            case muxSession = "mux_session"
            case clientPid = "client_pid"
            case attachedWindow = "attached_window"
            case terminalApp = "terminal_app"
        }

        var id: Int32 { pid }
    }

    struct StatusSummary: Decodable {
        let total: Int
        let running: Int
        let waitingInput: Int
        let unknown: Int
        let color: String
        let label: String

        enum CodingKeys: String, CodingKey {
            case total, running, unknown, color, label
            case waitingInput = "waiting_input"
        }
    }

    struct JumpResponse: Decodable {
        let ok: Bool
        let pid: Int32?
        let clientPid: Int32?
        let focused: Bool?
        let openedAttach: Bool?
        let openedShell: Bool?
        let error: String?

        enum CodingKeys: String, CodingKey {
            case ok, pid, focused, error
            case clientPid = "client_pid"
            case openedAttach = "opened_attach"
            case openedShell = "opened_shell"
        }
    }

    static func status() -> StatusResponse? {
        request("status", as: StatusResponse.self)
    }

    static func jump(pid: Int32) -> JumpResponse? {
        debugLog("DaemonClient: sending jump \(pid)")
        let response = request("jump \(pid)", as: JumpResponse.self)
        debugLog("DaemonClient: jump response = \(String(describing: response))")
        return response
    }
    
    static func isDaemonRunning() -> Bool {
        return status()?.ok == true
    }

    private static func request<T: Decodable>(_ command: String, as type: T.Type) -> T? {
        guard let data = send(command: command + "\n") else { 
            debugLog("DaemonClient: send failed for '\(command)'")
            return nil 
        }
        do {
            let decoded = try JSONDecoder().decode(T.self, from: data)
            return decoded
        } catch {
            debugLog("DaemonClient: decode error: \(error)")
            if let str = String(data: data, encoding: .utf8) {
                debugLog("DaemonClient: raw response: \(str)")
            }
            return nil
        }
    }

    private static func send(command: String) -> Data? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 { 
            debugLog("DaemonClient: socket() failed")
            return nil 
        }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        addr.sun_family = sa_family_t(AF_UNIX)

        let pathBytes = Array(socketPath.utf8) + [0]
        withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
            buffer.initializeMemory(as: UInt8.self, repeating: 0)
            let n = min(pathBytes.count, buffer.count)
            _ = buffer.copyBytes(from: pathBytes.prefix(n))
        }

        let connectOK = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connectOK != 0 { 
            debugLog("DaemonClient: connect() failed - is pi-statusd running?")
            return nil 
        }

        command.withCString { cstr in
            _ = write(fd, cstr, strlen(cstr))
        }

        var result = Data()
        var buf = [UInt8](repeating: 0, count: 4096)

        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            result.append(contentsOf: buf[0..<n])
            if buf.prefix(max(0, n)).contains(10) { // newline
                break
            }
        }

        return result
    }
}
