import AVFoundation
import Foundation

/// Records audio while button is held, provides audio data on release
final class AudioRecorder: NSObject, ObservableObject {
    private var audioRecorder: AVAudioRecorder?
    private var recordingURL: URL?
    
    @Published var isRecording = false
    @Published var permissionGranted = false
    
    override init() {
        super.init()
        checkPermission()
    }
    
    /// Check and request microphone permission
    func checkPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            permissionGranted = true
            print("AudioRecorder: Microphone permission granted")
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    self?.permissionGranted = granted
                    print("AudioRecorder: Microphone permission \(granted ? "granted" : "denied")")
                }
            }
        case .denied, .restricted:
            permissionGranted = false
            print("AudioRecorder: Microphone permission denied")
        @unknown default:
            permissionGranted = false
        }
    }
    
    /// Start recording audio
    func startRecording() {
        // Check permission first
        guard permissionGranted else {
            print("AudioRecorder: No microphone permission")
            checkPermission()
            return
        }
        // Create temp file for recording
        let tempDir = FileManager.default.temporaryDirectory
        let filename = "pitalk-recording-\(UUID().uuidString).m4a"
        recordingURL = tempDir.appendingPathComponent(filename)
        
        guard let url = recordingURL else { return }
        
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        
        do {
            audioRecorder = try AVAudioRecorder(url: url, settings: settings)
            audioRecorder?.record()
            isRecording = true
            print("AudioRecorder: Started recording to \(url.path)")
        } catch {
            print("AudioRecorder: Failed to start recording: \(error)")
        }
    }
    
    /// Stop recording and return the audio data
    func stopRecording() -> Data? {
        guard let recorder = audioRecorder, recorder.isRecording else {
            isRecording = false
            return nil
        }
        
        recorder.stop()
        isRecording = false
        
        guard let url = recordingURL else { return nil }
        
        print("AudioRecorder: Stopped recording")
        
        // Read the recorded audio file
        do {
            let data = try Data(contentsOf: url)
            print("AudioRecorder: Got \(data.count) bytes of audio")
            
            // Clean up temp file
            try? FileManager.default.removeItem(at: url)
            
            return data
        } catch {
            print("AudioRecorder: Failed to read recording: \(error)")
            return nil
        }
    }
    
    /// Cancel recording without returning data
    func cancelRecording() {
        audioRecorder?.stop()
        isRecording = false
        
        if let url = recordingURL {
            try? FileManager.default.removeItem(at: url)
        }
        
        print("AudioRecorder: Cancelled recording")
    }
}
