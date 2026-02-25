import Foundation
import AppKit

/// Transcribes audio to text using ElevenLabs or Google Cloud API
final class SpeechToText {
    
    struct TranscriptionResult {
        let success: Bool
        let text: String?
        let error: String?
    }
    
    /// Get current TTS provider setting
    private static var currentProvider: SpeechPlaybackCoordinator.TTSProvider {
        SpeechPlaybackCoordinator.currentProvider
    }
    
    /// Transcribe audio data to text using the current provider
    static func transcribe(audioData: Data, completion: @escaping (TranscriptionResult) -> Void) {
        switch currentProvider {
        case .elevenlabs:
            transcribeWithElevenLabs(audioData: audioData, completion: completion)
        case .google:
            transcribeWithGoogle(audioData: audioData, completion: completion)
        case .local:
            completion(TranscriptionResult(
                success: false,
                text: nil,
                error: "Speech-to-text is not available in Local mode yet. Switch provider to ElevenLabs or Google."
            ))
        }
    }
    
    // MARK: - ElevenLabs STT
    
    private static func transcribeWithElevenLabs(audioData: Data, completion: @escaping (TranscriptionResult) -> Void) {
        guard let apiKey = ElevenLabsApiKeyManager.resolvedKey(), !apiKey.isEmpty else {
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
    
    // MARK: - Google Cloud STT
    
    private static func transcribeWithGoogle(audioData: Data, completion: @escaping (TranscriptionResult) -> Void) {
        guard let apiKey = GoogleApiKeyManager.resolvedKey(), !apiKey.isEmpty else {
            completion(TranscriptionResult(
                success: false,
                text: nil,
                error: "Google Cloud API key not found. Add it in settings or import from ~/.env."
            ))
            return
        }
        
        // Google Cloud Speech-to-Text endpoint
        let url = URL(string: "https://speech.googleapis.com/v1/speech:recognize?key=\(apiKey)")!
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        
        // Convert audio to base64
        let audioBase64 = audioData.base64EncodedString()
        
        // Build request body
        // Note: The audio is recorded as M4A (AAC), so we use encoding: "AAC" or send as FLAC/LINEAR16
        // Google supports various encodings. For M4A files, we'll try with automatic detection
        let body: [String: Any] = [
            "config": [
                "encoding": "ENCODING_UNSPECIFIED",  // Let Google auto-detect
                "sampleRateHertz": 44100,
                "languageCode": "en-US",
                "enableAutomaticPunctuation": true,
                "model": "latest_long"  // Best for longer audio
            ],
            "audio": [
                "content": audioBase64
            ]
        ]
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            completion(TranscriptionResult(success: false, text: nil, error: "Failed to encode request"))
            return
        }
        
        print("SpeechToText: Sending \(audioData.count) bytes to Google Cloud")
        
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
                    
                    // Check for error
                    if let error = json["error"] as? [String: Any],
                       let message = error["message"] as? String {
                        DispatchQueue.main.async {
                            completion(TranscriptionResult(success: false, text: nil, error: message))
                        }
                        return
                    }
                    
                    // Parse results
                    if let results = json["results"] as? [[String: Any]] {
                        var fullText = ""
                        for result in results {
                            if let alternatives = result["alternatives"] as? [[String: Any]],
                               let firstAlt = alternatives.first,
                               let transcript = firstAlt["transcript"] as? String {
                                fullText += transcript
                            }
                        }
                        
                        if !fullText.isEmpty {
                            DispatchQueue.main.async {
                                completion(TranscriptionResult(success: true, text: fullText, error: nil))
                            }
                            return
                        }
                    }
                    
                    // No results - might be empty audio or no speech detected
                    DispatchQueue.main.async {
                        completion(TranscriptionResult(success: true, text: "", error: nil))
                    }
                    return
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
}
