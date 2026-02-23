import Foundation
import AppKit

/// Transcribes audio to text using ElevenLabs API
final class SpeechToText {
    
    struct TranscriptionResult {
        let success: Bool
        let text: String?
        let error: String?
    }
    
    /// Transcribe audio data to text
    static func transcribe(audioData: Data, completion: @escaping (TranscriptionResult) -> Void) {
        // Get API key from environment or AppStorage
        guard let apiKey = getApiKey(), !apiKey.isEmpty else {
            completion(TranscriptionResult(
                success: false,
                text: nil,
                error: "ElevenLabs API key not found. Add it in settings or import from ~/.env."
            ))
            return
        }
        
        // ElevenLabs speech-to-text endpoint
        let url = URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        
        // Create multipart form data
        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        var body = Data()
        
        // Add audio file
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"recording.m4a\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/mp4\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n".data(using: .utf8)!)
        
        // Add model parameter (optional, use default)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model_id\"\r\n\r\n".data(using: .utf8)!)
        body.append("scribe_v1\r\n".data(using: .utf8)!)
        
        // Close boundary
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        
        request.httpBody = body
        
        print("SpeechToText: Sending \(audioData.count) bytes to ElevenLabs")
        
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                print("SpeechToText: Network error: \(error)")
                DispatchQueue.main.async {
                    completion(TranscriptionResult(success: false, text: nil, error: error.localizedDescription))
                }
                return
            }
            
            guard let data = data else {
                print("SpeechToText: No data received")
                DispatchQueue.main.async {
                    completion(TranscriptionResult(success: false, text: nil, error: "No data received"))
                }
                return
            }
            
            // Parse response
            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    print("SpeechToText: Response: \(json)")
                    
                    if let text = json["text"] as? String {
                        DispatchQueue.main.async {
                            completion(TranscriptionResult(success: true, text: text, error: nil))
                        }
                        return
                    }
                    
                    // Check for error
                    if let detail = json["detail"] as? [String: Any],
                       let message = detail["message"] as? String {
                        DispatchQueue.main.async {
                            completion(TranscriptionResult(success: false, text: nil, error: message))
                        }
                        return
                    }
                }
                
                // Try to get raw string response
                if let responseString = String(data: data, encoding: .utf8) {
                    print("SpeechToText: Raw response: \(responseString)")
                }
                
                DispatchQueue.main.async {
                    completion(TranscriptionResult(success: false, text: nil, error: "Failed to parse response"))
                }
            } catch {
                print("SpeechToText: JSON parse error: \(error)")
                DispatchQueue.main.async {
                    completion(TranscriptionResult(success: false, text: nil, error: "Failed to parse response"))
                }
            }
        }
        
        task.resume()
    }
    
    private static func getApiKey() -> String? {
        ElevenLabsApiKeyManager.resolvedKey()
    }
}
