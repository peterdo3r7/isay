import SwiftUI

// MARK: - VoicePermissionView

/// View mẫu minh hoạ cách sử dụng VoiceViewModel.
struct VoicePermissionView: View {

    @StateObject private var viewModel = VoiceViewModel()

    var body: some View {
        VStack(spacing: 24) {
            permissionStatusView
            sessionStatusView
        }
        .padding()
        .onAppear { viewModel.onAppear() }
        .onDisappear { viewModel.onDisappear() }
        // Alert khi quyền bị từ chối
        .alert("Cần quyền Microphone", isPresented: $viewModel.showPermissionAlert) {
            Button("Mở Cài đặt") { viewModel.openSettings() }
            Button("Huỷ", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage ?? "Vui lòng cấp quyền microphone trong Cài đặt.")
        }
    }

    // MARK: - Sub-views

    @ViewBuilder
    private var permissionStatusView: some View {
        HStack(spacing: 12) {
            Image(systemName: permissionIcon)
                .font(.title2)
                .foregroundStyle(permissionColor)

            VStack(alignment: .leading, spacing: 4) {
                Text("Microphone")
                    .font(.headline)
                Text(permissionLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var sessionStatusView: some View {
        HStack(spacing: 12) {
            Image(systemName: viewModel.isSessionReady ? "speaker.wave.2.fill" : "speaker.slash.fill")
                .font(.title2)
                .foregroundStyle(viewModel.isSessionReady ? .green : .gray)

            Text(viewModel.isSessionReady ? "Session sẵn sàng" : "Session chưa khởi động")
                .font(.subheadline)
            Spacer()
        }
        .padding()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Computed Helpers

    private var permissionIcon: String {
        switch viewModel.permission {
        case .granted:      return "mic.fill"
        case .denied:       return "mic.slash.fill"
        case .undetermined: return "mic"
        }
    }

    private var permissionColor: Color {
        switch viewModel.permission {
        case .granted:      return .green
        case .denied:       return .red
        case .undetermined: return .orange
        }
    }

    private var permissionLabel: String {
        switch viewModel.permission {
        case .granted:      return "Đã cấp quyền"
        case .denied:       return "Bị từ chối — nhấn để mở Cài đặt"
        case .undetermined: return "Chưa xác định"
        }
    }
}

// MARK: - Preview

#Preview {
    VoicePermissionView()
}
