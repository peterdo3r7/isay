import Foundation

// MARK: - Server Response Model

/// Cấu trúc JSON server trả về, ví dụ: { "text": "xin chào" }
struct TranscriptionResponse: Decodable {
    let text: String
}

// MARK: - TranscriptionError

enum TranscriptionError: LocalizedError {
    case invalidURL
    case networkError(Error)
    case serverError(statusCode: Int)
    case decodingError(Error)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "URL server không hợp lệ."
        case .networkError(let e):
            return "Lỗi mạng: \(e.localizedDescription)"
        case .serverError(let code):
            return "Server trả về lỗi HTTP \(code)."
        case .decodingError(let e):
            return "Không thể đọc phản hồi server: \(e.localizedDescription)"
        case .emptyResponse:
            return "Server trả về phản hồi rỗng."
        }
    }
}

// MARK: - TranscriptionService

/// Gửi file audio lên server qua Multipart/form-data và trả về văn bản nhận dạng.
actor TranscriptionService {

    // MARK: Singleton
    static let shared = TranscriptionService()

    // MARK: Configuration — đổi endpoint theo môi trường thực tế
    private let endpointURL: URL
    private let fieldName  = "audio"        // tên field multipart server mong đợi
    private let session    = URLSession.shared

    init(endpoint: String = "http://10.0.0.11:8000/transcribe") {
        // Force-unwrap an toàn vì endpoint là literal tĩnh
        self.endpointURL = URL(string: endpoint)!
    }

    // MARK: - Public API

    /// Gửi file audio tại `fileURL` lên server và trả về chuỗi văn bản.
    /// - Throws: `TranscriptionError`
    func transcribe(fileURL: URL) async throws -> String {
        let audioData = try loadAudioData(from: fileURL)
        let boundary  = "Boundary-\(UUID().uuidString)"
        let body      = buildMultipartBody(
            data:      audioData,
            fieldName: fieldName,
            fileName:  fileURL.lastPathComponent,
            mimeType:  "audio/m4a",
            boundary:  boundary
        )

        var request        = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)",
                         forHTTPHeaderField: "Content-Type")
        request.httpBody   = body

        let (data, response) = try await session.data(for: request)

        // Kiểm tra HTTP status
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw TranscriptionError.serverError(statusCode: http.statusCode)
        }

        guard !data.isEmpty else { throw TranscriptionError.emptyResponse }

        do {
            let decoded = try JSONDecoder().decode(TranscriptionResponse.self, from: data)
            return decoded.text
        } catch {
            throw TranscriptionError.decodingError(error)
        }
    }

    // MARK: - Private helpers

    private func loadAudioData(from url: URL) throws -> Data {
        do {
            return try Data(contentsOf: url)
        } catch {
            throw TranscriptionError.networkError(error)
        }
    }

    /// Tạo body Multipart/form-data theo chuẩn RFC 2046.
    private func buildMultipartBody(
        data:      Data,
        fieldName: String,
        fileName:  String,
        mimeType:  String,
        boundary:  String
    ) -> Data {
        var body = Data()
        let crlf = "\r\n"

        // Part header
        body.append("--\(boundary)\(crlf)")
        body.append("Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(fileName)\"\(crlf)")
        body.append("Content-Type: \(mimeType)\(crlf)")
        body.append(crlf)

        // Part body (binary audio)
        body.append(data)
        body.append(crlf)

        // Closing boundary
        body.append("--\(boundary)--\(crlf)")

        return body
    }
}

// MARK: - Data helper

private extension Data {
    /// Append UTF-8 string vào Data.
    mutating func append(_ string: String) {
        if let encoded = string.data(using: .utf8) {
            append(encoded)
        }
    }
}
