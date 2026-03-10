import SwiftUI
import Combine

// MARK: - VoiceState

/// State machine toàn bộ vòng đời của một lượt nói chuyện.
enum VoiceState: Equatable {
    case idle                   // Chờ người dùng nhấn nút
    case recording              // Đang ghi âm (người dùng đang giữ nút)
    case sending                // Đang gửi file lên server
    case speaking(text: String) // Đang đọc kết quả qua TTS
    case error(message: String) // Có lỗi xảy ra

    var statusLabel: String {
        switch self {
        case .idle:           return "Giữ để nói"
        case .recording:      return "Đang ghi âm..."
        case .sending:        return "Đang gửi..."
        case .speaking:       return "Đang đọc..."
        case .error(let msg): return msg
        }
    }

    var isIdle:      Bool { self == .idle }
    var isRecording: Bool { self == .recording }
    var isBusy:      Bool {
        switch self {
        case .sending, .speaking: return true
        default: return false
        }
    }
}

// MARK: - VoiceViewModel

@MainActor
final class VoiceViewModel: ObservableObject {

    // MARK: Published state
    @Published private(set) var voiceState: VoiceState = .idle
    @Published private(set) var permission: MicrophonePermission = .undetermined
    @Published private(set) var transcribedText: String = ""
    @Published private(set) var isSessionReady: Bool = false
    @Published var showPermissionAlert: Bool = false

    var errorMessage: String? {
        if case .error(let msg) = voiceState { return msg }
        return nil
    }

    // MARK: Private
    private let voiceService:         VoiceService
    private let transcriptionService: TranscriptionService
    private var cancellables = Set<AnyCancellable>()
    private var recordingURL: URL?

    // MARK: Init
    init(
        voiceService:         VoiceService         = .shared,
        transcriptionService: TranscriptionService = .shared
    ) {
        self.voiceService         = voiceService
        self.transcriptionService = transcriptionService
        bindService()
    }

    // MARK: - Lifecycle

    func onAppear() {
        Task {
            let result = await voiceService.requestMicrophonePermission()
            if result == .granted {
                do {
                    try voiceService.configureSession()
                    isSessionReady = true
                } catch {
                    isSessionReady = false
                }
            }
        }
    }

    func onDisappear() {
        voiceService.stopSpeaking()
        _ = voiceService.stopRecording()
        voiceService.deactivateSession()
        voiceState = .idle
        isSessionReady = false
    }

    // MARK: - Hold-to-Talk actions

    /// Người dùng nhấn giữ nút → bắt đầu ghi âm.
    func holdBegan() {
        guard permission == .granted,
              voiceState.isIdle else { return }

        do {
            recordingURL = try voiceService.startRecording()
            voiceState = .recording
        } catch {
            voiceState = .error(message: error.localizedDescription)
            scheduleReset()
        }
    }

    /// Người dùng thả nút → dừng ghi và gửi lên server.
    func holdEnded() {
        guard voiceState.isRecording else { return }

        guard let url = voiceService.stopRecording() else {
            voiceState = .error(message: "Không tìm thấy file ghi âm.")
            scheduleReset()
            return
        }

        sendAndSpeak(fileURL: url)
    }

    /// Người dùng kéo ngón tay ra ngoài nút → huỷ ghi âm.
    func holdCancelled() {
        guard voiceState.isRecording else { return }
        if let url = voiceService.stopRecording() {
            voiceService.deleteRecording(at: url)
        }
        voiceState = .idle
    }

    // MARK: - Permission

    func openSettings() {
        voiceService.openAppSettings()
    }

    // MARK: - Private

    private func sendAndSpeak(fileURL: URL) {
        voiceState = .sending

        Task {
            defer { voiceService.deleteRecording(at: fileURL) }

            do {
                let text = try await transcriptionService.transcribe(fileURL: fileURL)
                transcribedText = text
                voiceState = .speaking(text: text)

                // Đọc to kết quả, sau đó về idle
                await withCheckedContinuation { continuation in
                    voiceService.speak(text: text) {
                        continuation.resume()
                    }
                }
                voiceState = .idle

            } catch {
                voiceState = .error(message: error.localizedDescription)
                scheduleReset()
            }
        }
    }

    /// Tự động về idle sau 3 giây khi có lỗi.
    private func scheduleReset() {
        Task {
            try? await Task.sleep(for: .seconds(3))
            if case .error = voiceState { voiceState = .idle }
        }
    }

    private func bindService() {
        voiceService.$microphonePermission
            .receive(on: DispatchQueue.main)
            .sink { [weak self] perm in
                self?.permission = perm
                if perm == .denied { self?.showPermissionAlert = true }
            }
            .store(in: &cancellables)
    }
}
