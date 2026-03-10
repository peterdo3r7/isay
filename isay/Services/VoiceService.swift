import AVFoundation
import Combine
import UIKit

// MARK: - Microphone Permission

enum MicrophonePermission {
    case granted
    case denied
    case undetermined
}

// MARK: - VoiceServiceError

enum VoiceServiceError: LocalizedError {
    case permissionDenied
    case sessionConfigurationFailed(Error)
    case recordingFailed(Error)
    case noRecordingFound

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Quyền truy cập microphone bị từ chối. Vui lòng bật trong Cài đặt."
        case .sessionConfigurationFailed(let e):
            return "Không thể cấu hình phiên âm thanh: \(e.localizedDescription)"
        case .recordingFailed(let e):
            return "Ghi âm thất bại: \(e.localizedDescription)"
        case .noRecordingFound:
            return "Không tìm thấy file ghi âm."
        }
    }
}

extension VoiceServiceError: Equatable {
    static func == (lhs: VoiceServiceError, rhs: VoiceServiceError) -> Bool {
        lhs.errorDescription == rhs.errorDescription
    }
}

// MARK: - VoiceService

/// Quản lý toàn bộ vòng đời âm thanh:
///   • AVAudioSession  — cấu hình mic + loa ngoài
///   • AVAudioRecorder — thu âm → file .m4a tạm
///   • AVSpeechSynthesizer — Text-to-Speech phát qua loa
final class VoiceService: NSObject {

    // MARK: Singleton
    static let shared = VoiceService()

    // MARK: Private AV objects
    private let session     = AVAudioSession.sharedInstance()
    private var recorder:   AVAudioRecorder?
    private let synthesizer = AVSpeechSynthesizer()

    // URL của file ghi âm hiện tại (xóa sau khi gửi xong)
    private var currentRecordingURL: URL?

    // MARK: Published state
    @Published private(set) var microphonePermission: MicrophonePermission = .undetermined
    @Published private(set) var lastError: VoiceServiceError?
    @Published private(set) var isSpeaking: Bool = false

    // Completion gọi lại khi TTS xong
    private var speakCompletion: (() -> Void)?

    // MARK: Init
    private override init() {
        super.init()
        synthesizer.delegate = self
        syncPermissionState()
        observeSessionInterruptions()
    }

    // MARK: - Session

    /// Cấu hình AVAudioSession: playAndRecord + defaultToSpeaker.
    func configureSession() throws {
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP]
            )
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            let wrapped = VoiceServiceError.sessionConfigurationFailed(error)
            lastError = wrapped
            throw wrapped
        }
    }

    func deactivateSession() {
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Permission

    @discardableResult
    func requestMicrophonePermission() async -> MicrophonePermission {
        let current = currentPermissionState()
        guard current == .undetermined else {
            await MainActor.run { microphonePermission = current }
            return current
        }

        let granted: Bool
        if #available(iOS 17.0, *) {
            granted = await AVAudioApplication.requestRecordPermission()
        } else {
            granted = await withCheckedContinuation { continuation in
                session.requestRecordPermission { continuation.resume(returning: $0) }
            }
        }

        let result: MicrophonePermission = granted ? .granted : .denied
        await MainActor.run {
            microphonePermission = result
            if result == .denied { lastError = .permissionDenied }
        }
        return result
    }

    func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        Task { @MainActor in
            if await UIApplication.shared.canOpenURL(url) {
                await UIApplication.shared.open(url)
            }
        }
    }

    // MARK: - Recording

    /// Bắt đầu ghi âm vào file .m4a tạm trong thư mục tmp.
    /// - Returns: URL của file sẽ được ghi
    @discardableResult
    func startRecording() throws -> URL {
        // Tạo URL file tạm duy nhất mỗi lần ghi
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")

        // Cấu hình chất lượng âm thanh cho nhận dạng giọng nói
        let settings: [String: Any] = [
            AVFormatIDKey:            Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey:          16000,          // 16 kHz — phù hợp STT
            AVNumberOfChannelsKey:    1,               // mono
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        do {
            recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder?.delegate = self
            recorder?.record()
            currentRecordingURL = url
            return url
        } catch {
            let wrapped = VoiceServiceError.recordingFailed(error)
            lastError = wrapped
            throw wrapped
        }
    }

    /// Dừng ghi âm.
    /// - Returns: URL file .m4a vừa ghi, hoặc nil nếu chưa bắt đầu.
    func stopRecording() -> URL? {
        recorder?.stop()
        recorder = nil
        return currentRecordingURL
    }

    /// Xóa file ghi âm tạm sau khi đã gửi xong.
    func deleteRecording(at url: URL) {
        try? FileManager.default.removeItem(at: url)
        if currentRecordingURL == url { currentRecordingURL = nil }
    }

    // MARK: - Text-to-Speech

    /// Đọc to `text` qua loa, gọi `completion` khi xong.
    func speak(text: String, language: String = "vi-VN", completion: (() -> Void)? = nil) {
        // Dừng bất cứ thứ gì đang đọc
        synthesizer.stopSpeaking(at: .immediate)

        speakCompletion = completion
        isSpeaking = true

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: language)
            ?? AVSpeechSynthesisVoice(language: "en-US") // fallback nếu thiếu gói tiếng Việt
        utterance.rate  = AVSpeechUtteranceDefaultSpeechRate
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0
        synthesizer.speak(utterance)
    }

    func stopSpeaking() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    // MARK: - Private helpers

    private func currentPermissionState() -> MicrophonePermission {
        if #available(iOS 17.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .granted:      return .granted
            case .denied:       return .denied
            case .undetermined: return .undetermined
            @unknown default:   return .undetermined
            }
        } else {
            switch session.recordPermission {
            case .granted:      return .granted
            case .denied:       return .denied
            case .undetermined: return .undetermined
            @unknown default:   return .undetermined
            }
        }
    }

    private func syncPermissionState() {
        microphonePermission = currentPermissionState()
    }

    private func observeSessionInterruptions() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: session
        )
    }

    @objc private func handleInterruption(_ notification: Notification) {
        guard
            let info = notification.userInfo,
            let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: typeValue)
        else { return }

        switch type {
        case .began:
            NotificationCenter.default.post(name: .voiceServiceDidInterrupt, object: nil)
        case .ended:
            if let optVal = info[AVAudioSessionInterruptionOptionKey] as? UInt {
                if AVAudioSession.InterruptionOptions(rawValue: optVal).contains(.shouldResume) {
                    try? configureSession()
                    NotificationCenter.default.post(name: .voiceServiceDidResume, object: nil)
                }
            }
        @unknown default: break
        }
    }
}

// MARK: - AVAudioRecorderDelegate

extension VoiceService: AVAudioRecorderDelegate {
    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        guard let error else { return }
        lastError = .recordingFailed(error)
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension VoiceService: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           didFinish utterance: AVSpeechUtterance) {
        isSpeaking = false
        speakCompletion?()
        speakCompletion = nil
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           didCancel utterance: AVSpeechUtterance) {
        isSpeaking = false
        speakCompletion = nil
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let voiceServiceDidInterrupt = Notification.Name("voiceServiceDidInterrupt")
    static let voiceServiceDidResume    = Notification.Name("voiceServiceDidResume")
}
