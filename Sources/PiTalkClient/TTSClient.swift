import Foundation

/// Client for communicating with the PiTalk server
public class TTSClient {
    public let host: String
    public let port: Int
    
    public var baseURL: URL {
        URL(string: "http://\(host):\(port)")!
    }
    
    public init(host: String = "127.0.0.1", port: Int = 18080) {
        self.host = host
        self.port = port
    }
    
    /// Available voice aliases across supported providers.
    /// Actual availability depends on the selected provider in PiTalk settings.
    public static let availableVoices = [
        "ally", "dorothy", "lily", "alice", "dave", "joseph",
        "george", "emma", "oliver", "sophia", "charlotte", "william",
        "jack", "olivia", "isla", "liam"
    ]
    
    /// Check if server is running
    public func healthCheck() async throws -> Bool {
        let url = baseURL.appendingPathComponent("health")
        let (_, response) = try await URLSession.shared.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse else { return false }
        return httpResponse.statusCode == 200
    }
}

public enum TTSError: Error, LocalizedError {
    case serverNotRunning
    case serverError(String)
    case invalidResponse
    
    public var errorDescription: String? {
        switch self {
        case .serverNotRunning:
            return "PiTalk server is not running. Start the PiTalk app first."
        case .serverError(let message):
            return "Server error: \(message)"
        case .invalidResponse:
            return "Invalid response from server"
        }
    }
}
