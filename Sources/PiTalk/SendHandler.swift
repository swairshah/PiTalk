import Foundation

/// Sends text to a pi session via file-based inbox (pi-messenger style)
final class SendHandler {
    
    struct SendResult {
        let success: Bool
        let message: String?
    }
    
    private static let inboxBaseDir = (NSHomeDirectory() as NSString).appendingPathComponent(".pi/agent/pitalk-inbox")
    
    static func send(pid: Int?, tty: String?, mux: String?, text: String, completion: @escaping (SendResult) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = performSend(pid: pid, text: text)
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }
    
    private static func performSend(pid: Int?, text: String) -> SendResult {
        guard let pid = pid else {
            return SendResult(success: false, message: "No PID")
        }
        
        print("SendHandler: sending to PID \(pid) via inbox")
        
        // Write message to the pi session's inbox
        let inboxDir = (inboxBaseDir as NSString).appendingPathComponent("\(pid)")
        
        // Ensure inbox directory exists
        do {
            try FileManager.default.createDirectory(atPath: inboxDir, withIntermediateDirectories: true)
        } catch {
            return SendResult(success: false, message: "Failed to create inbox: \(error.localizedDescription)")
        }
        
        // Create message file
        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let random = String(format: "%06x", Int.random(in: 0..<0xFFFFFF))
        let filename = "\(timestamp)-\(random).json"
        let filePath = (inboxDir as NSString).appendingPathComponent(filename)
        
        let message: [String: Any] = [
            "text": text,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "from": "pi-talk-app"
        ]
        
        do {
            let data = try JSONSerialization.data(withJSONObject: message, options: .prettyPrinted)
            try data.write(to: URL(fileURLWithPath: filePath))
            print("SendHandler: wrote message to \(filePath)")
            return SendResult(success: true, message: "Sent via inbox")
        } catch {
            return SendResult(success: false, message: "Failed to write message: \(error.localizedDescription)")
        }
    }
}
