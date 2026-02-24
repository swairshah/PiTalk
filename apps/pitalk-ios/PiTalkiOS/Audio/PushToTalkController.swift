import AVFoundation
import Combine
import Foundation
import Speech

@MainActor
final class PushToTalkController: NSObject, ObservableObject {
    @Published private(set) var isRecording = false

    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?

    func startRecording() {
        guard !isRecording else { return }

        requestPermissionsIfNeeded { [weak self] granted in
            guard let self else { return }
            guard granted else { return }

            do {
                let audioSession = AVAudioSession.sharedInstance()
                try audioSession.setCategory(
                    .playAndRecord,
                    mode: .spokenAudio,
                    options: [.defaultToSpeaker, .allowBluetooth]
                )
                try audioSession.setActive(true)

                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("pitalk-ptt-\(UUID().uuidString).m4a")

                let settings: [String: Any] = [
                    AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                    AVSampleRateKey: 44_100,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
                ]

                let recorder = try AVAudioRecorder(url: url, settings: settings)
                recorder.prepareToRecord()
                recorder.record()

                self.recorder = recorder
                self.recordingURL = url
                self.isRecording = true
            } catch {
                self.recorder = nil
                self.recordingURL = nil
                self.isRecording = false
            }
        }
    }

    func stopAndTranscribe() async -> String? {
        guard isRecording else { return nil }

        recorder?.stop()
        recorder = nil
        isRecording = false

        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)

        guard let recordingURL else { return nil }
        self.recordingURL = nil

        let transcript = await transcribeFile(at: recordingURL)

        try? FileManager.default.removeItem(at: recordingURL)
        return transcript?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func requestPermissionsIfNeeded(completion: @escaping (Bool) -> Void) {
        let audioSession = AVAudioSession.sharedInstance()
        audioSession.requestRecordPermission { granted in
            guard granted else {
                completion(false)
                return
            }

            SFSpeechRecognizer.requestAuthorization { status in
                completion(status == .authorized)
            }
        }
    }

    private func transcribeFile(at url: URL) async -> String? {
        guard let recognizer = SFSpeechRecognizer(locale: Locale.current), recognizer.isAvailable else {
            return nil
        }

        return await withCheckedContinuation { continuation in
            let request = SFSpeechURLRecognitionRequest(url: url)
            request.shouldReportPartialResults = false

            var resumed = false
            _ = recognizer.recognitionTask(with: request) { result, error in
                if resumed { return }

                if let result, result.isFinal {
                    resumed = true
                    continuation.resume(returning: result.bestTranscription.formattedString)
                    return
                }

                if error != nil {
                    resumed = true
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}
