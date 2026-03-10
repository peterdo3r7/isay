import SwiftUI

// MARK: - HoldToTalkView

struct HoldToTalkView: View {

    @StateObject private var viewModel = VoiceViewModel()

    var body: some View {
        VStack(spacing: 32) {
            Spacer()
            transcriptPanel
            statusLabel
            micButton
            Spacer()
        }
        .padding()
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .onAppear { viewModel.onAppear() }
        .onDisappear { viewModel.onDisappear() }
        .alert("Cần quyền Microphone", isPresented: $viewModel.showPermissionAlert) {
            Button("Mở Cài đặt") { viewModel.openSettings() }
            Button("Huỷ", role: .cancel) {}
        } message: {
            Text("Vui lòng cấp quyền microphone trong Cài đặt để sử dụng tính năng này.")
        }
    }

    // MARK: - Sub-views

    /// Vùng hiển thị văn bản nhận dạng được
    @ViewBuilder
    private var transcriptPanel: some View {
        GroupBox {
            ScrollView {
                Text(viewModel.transcribedText.isEmpty
                     ? "Văn bản nhận dạng sẽ hiện ở đây..."
                     : viewModel.transcribedText)
                    .font(.body)
                    .foregroundStyle(viewModel.transcribedText.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .animation(.default, value: viewModel.transcribedText)
            }
            .frame(minHeight: 120, maxHeight: 200)
        } label: {
            Label("Kết quả", systemImage: "text.bubble")
                .font(.headline)
        }
    }

    /// Nhãn trạng thái động (Đang ghi âm / Đang gửi / v.v.)
    @ViewBuilder
    private var statusLabel: some View {
        HStack(spacing: 8) {
            if viewModel.voiceState.isRecording {
                // Chấm nhấp nháy khi đang ghi âm
                Circle()
                    .fill(.red)
                    .frame(width: 10, height: 10)
                    .modifier(PulseEffect())
            } else if viewModel.voiceState.isBusy {
                ProgressView().scaleEffect(0.8)
            }

            Text(viewModel.voiceState.statusLabel)
                .font(.subheadline)
                .foregroundStyle(statusColor)
                .animation(.default, value: viewModel.voiceState.statusLabel)
        }
        .frame(height: 24)
    }

    /// Nút micro chính — giữ để nói
    @ViewBuilder
    private var micButton: some View {
        let isDisabled = viewModel.voiceState.isBusy
                      || viewModel.permission == .denied

        MicButtonView(
            isRecording: viewModel.voiceState.isRecording,
            isDisabled:  isDisabled,
            onBegan:     { viewModel.holdBegan() },
            onEnded:     { viewModel.holdEnded() },
            onCancelled: { viewModel.holdCancelled() }
        )
        .accessibilityLabel("Giữ để nói")
        .accessibilityHint(isDisabled ? "Không khả dụng" : "Nhấn giữ để bắt đầu ghi âm")
    }

    // MARK: - Helpers

    private var statusColor: Color {
        switch viewModel.voiceState {
        case .recording:    return .red
        case .sending:      return .orange
        case .speaking:     return .blue
        case .error:        return .red
        case .idle:         return .secondary
        }
    }
}

// MARK: - MicButtonView

/// Nút micro sử dụng DragGesture để detect giữ / thả / huỷ.
private struct MicButtonView: View {

    let isRecording: Bool
    let isDisabled:  Bool
    let onBegan:     () -> Void
    let onEnded:     () -> Void
    let onCancelled: () -> Void

    // Theo dõi xem ngón tay có còn trong vùng nút không
    @State private var fingerInside = false

    private let buttonSize: CGFloat = 88

    var body: some View {
        ZStack {
            // Vòng ngoài mở rộng khi đang ghi
            Circle()
                .stroke(isRecording ? Color.red.opacity(0.3) : Color.clear, lineWidth: 16)
                .frame(width: buttonSize + 24, height: buttonSize + 24)
                .animation(.easeInOut(duration: 0.25), value: isRecording)

            // Nút chính
            Circle()
                .fill(buttonBackground)
                .frame(width: buttonSize, height: buttonSize)
                .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
                .overlay {
                    Image(systemName: isRecording ? "waveform" : "mic.fill")
                        .font(.system(size: 32, weight: .medium))
                        .foregroundStyle(.white)
                        .animation(.default, value: isRecording)
                }
                .scaleEffect(isRecording ? 1.1 : 1.0)
                .animation(.spring(response: 0.3), value: isRecording)
        }
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { value in
                    let inside = isInsideButton(value.location)
                    if !fingerInside && !isDisabled {
                        // Lần đầu chạm vào nút
                        fingerInside = true
                        onBegan()
                    } else if fingerInside && !inside {
                        // Kéo ra ngoài vùng nút → huỷ
                        fingerInside = false
                        onCancelled()
                    }
                }
                .onEnded { _ in
                    if fingerInside {
                        fingerInside = false
                        onEnded()
                    }
                }
        )
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.4 : 1)
    }

    private var buttonBackground: LinearGradient {
        let colors: [Color] = isRecording
            ? [.red, Color(red: 0.8, green: 0.1, blue: 0.1)]
            : [.blue, Color(red: 0.1, green: 0.3, blue: 0.9)]
        return LinearGradient(colors: colors,
                              startPoint: .topLeading,
                              endPoint: .bottomTrailing)
    }

    /// Kiểm tra điểm chạm có nằm trong hình tròn không.
    private func isInsideButton(_ point: CGPoint) -> Bool {
        let center = CGPoint(x: buttonSize / 2 + 12, y: buttonSize / 2 + 12)
        let radius = buttonSize / 2 + 12
        let dx = point.x - center.x
        let dy = point.y - center.y
        return (dx * dx + dy * dy) <= (radius * radius)
    }
}

// MARK: - PulseEffect

/// Hiệu ứng nhấp nháy cho chấm đỏ khi đang ghi âm.
private struct PulseEffect: ViewModifier {
    @State private var animating = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(animating ? 1.4 : 0.8)
            .opacity(animating ? 0.4 : 1.0)
            .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true),
                       value: animating)
            .onAppear { animating = true }
    }
}

// MARK: - Preview

#Preview {
    HoldToTalkView()
}
