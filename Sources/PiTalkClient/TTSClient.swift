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
    
    /// Available voices
    public static let availableVoices = ["alba", "marius", "javert", "fantine", "cosette", "eponine", "azelma"]
    
    /// Check if server is running
    public func healthCheck() async throws -> Bool {
        let url = baseURL.appendingPathComponent("health")
        let (_, response) = try await URLSession.shared.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse else { return false }
        return httpResponse.statusCode == 200
    }
    
    /// Stream TTS audio as raw PCM (s16le, 24kHz, mono)
    /// Returns an AsyncThrowingStream of Data chunks
    public func streamSpeech(text: String, voice: String = "alba") -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let url = baseURL.appendingPathComponent("stream")
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    
                    let body = ["text": text, "voice": voice]
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)
                    
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    
                    guard let httpResponse = response as? HTTPURLResponse,
                          httpResponse.statusCode == 200 else {
                        throw TTSError.serverError("Server returned non-200 status")
                    }
                    
                    var buffer = Data()
                    let chunkSize = 4096
                    
                    for try await byte in bytes {
                        buffer.append(byte)
                        if buffer.count >= chunkSize {
                            continuation.yield(buffer)
                            buffer = Data()
                        }
                    }
                    
                    // Yield remaining data
                    if !buffer.isEmpty {
                        continuation.yield(buffer)
                    }
                    
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
    
    /// Synthesize text and return complete audio data
    public func synthesize(text: String, voice: String = "alba") async throws -> Data {
        let url = baseURL.appendingPathComponent("stream")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body = ["text": text, "voice": voice]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw TTSError.serverError("Server returned non-200 status")
        }
        
        return data
    }
    
    /// Stop current speech
    public func stop() async throws {
        let url = baseURL.appendingPathComponent("stop")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        _ = try await URLSession.shared.data(for: request)
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
