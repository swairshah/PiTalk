import Foundation
import AppKit
import Speech

/// Transcribes audio to text using the active cloud provider (currently ElevenLabs or Google)
final class SpeechToText {
    
    struct TranscriptionResult {
        let success: Bool
        let text: String?
        let error: String?
    }

    /// Owns the Apple recognition task until it completes. The task callback
    /// retains this object, and `finish` breaks that cycle. This is important for
    /// longer recordings, whose final result arrives after `transcribe` returns.
    private final class AppleOnDeviceTranscription {
        private let recognizer: SFSpeechRecognizer
        private let recordingURL: URL
        private let completion: (TranscriptionResult) -> Void
        private var task: SFSpeechRecognitionTask?
        private var latestText = ""
        private var completed = false

        init(
            recognizer: SFSpeechRecognizer,
            recordingURL: URL,
            completion: @escaping (TranscriptionResult) -> Void
        ) {
            self.recognizer = recognizer
            self.recordingURL = recordingURL
            self.completion = completion
        }

        func start() {
            let request = SFSpeechURLRecognitionRequest(url: recordingURL)
            request.shouldReportPartialResults = true
            request.requiresOnDeviceRecognition = true
            request.taskHint = .dictation
            request.contextualStrings = ["PiTalk", "Codex", "Claude", "Ghostty", "Herdr"]

            task = recognizer.recognitionTask(with: request) { [self] result, error in
                guard !completed else { return }

                if let result {
                    latestText = result.bestTranscription.formattedString
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if result.isFinal {
                        finish(error: latestText.isEmpty ? "No speech recognized" : nil)
                        return
                    }
                }

                if let error {
                    // Apple can return an error after already producing a useful
                    // partial transcript. Preserve that text instead of dropping it.
                    finish(error: latestText.isEmpty ? error.localizedDescription : nil)
                }
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
                guard let self, !self.completed else { return }
                self.finish(error: self.latestText.isEmpty
                    ? "On-device transcription timed out"
                    : nil)
            }
        }

        private func finish(error: String?) {
            guard !completed else { return }
            completed = true

            task?.cancel()
            task = nil
            try? FileManager.default.removeItem(at: recordingURL)

            let text = latestText
            DispatchQueue.main.async { [completion] in
                completion(TranscriptionResult(
                    success: error == nil && !text.isEmpty,
                    text: error == nil && !text.isEmpty ? text : nil,
                    error: error
                ))
            }
        }
    }
    
    /// Get current TTS provider setting
    private static var currentProvider: SpeechPlaybackCoordinator.TTSProvider {
        SpeechPlaybackCoordinator.currentProvider
    }
    
    /// Transcribe audio using the backend associated with the selected output
    /// provider. Local output uses Apple's on-device Speech recognizer.
    static func transcribe(audioData: Data, completion: @escaping (TranscriptionResult) -> Void) {
        switch currentProvider {
        case .elevenlabs:
            transcribeWithElevenLabs(audioData: audioData, completion: completion)
        case .google:
            transcribeWithGoogle(audioData: audioData, completion: completion)
        case .deepgram, .local:
            transcribeWithAppleOnDevice(audioData: audioData, completion: completion)
        }
    }

    // MARK: - Apple On-Device STT

    private static func transcribeWithAppleOnDevice(
        audioData: Data,
        completion: @escaping (TranscriptionResult) -> Void
    ) {
        let authorizationStatus = SFSpeechRecognizer.authorizationStatus()
        if authorizationStatus == .notDetermined {
            SFSpeechRecognizer.requestAuthorization { status in
                guard status == .authorized else {
                    DispatchQueue.main.async {
                        completion(TranscriptionResult(
                            success: false,
                            text: nil,
                            error: "Speech recognition permission was not granted."
                        ))
                    }
                    return
                }
                transcribeWithAppleOnDevice(audioData: audioData, completion: completion)
            }
            return
        }

        guard authorizationStatus == .authorized else {
            completion(TranscriptionResult(
                success: false,
                text: nil,
                error: "Speech recognition permission is disabled in System Settings."
            ))
            return
        }

        guard let recognizer = SFSpeechRecognizer(locale: Locale.current), recognizer.isAvailable else {
            completion(TranscriptionResult(
                success: false,
                text: nil,
                error: "Apple Speech recognition is unavailable for the current language."
            ))
            return
        }

        guard recognizer.supportsOnDeviceRecognition else {
            completion(TranscriptionResult(
                success: false,
                text: nil,
                error: "On-device speech recognition is not installed for the current language."
            ))
            return
        }

        let recordingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pitalk-stt-\(UUID().uuidString).m4a")
        do {
            try audioData.write(to: recordingURL, options: .atomic)
        } catch {
            completion(TranscriptionResult(
                success: false,
                text: nil,
                error: "Could not prepare the recording for transcription."
            ))
            return
        }

        AppleOnDeviceTranscription(
            recognizer: recognizer,
            recordingURL: recordingURL,
            completion: completion
        ).start()
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
