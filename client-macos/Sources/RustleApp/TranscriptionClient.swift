import Foundation

/// Talks to rustle-server. Wispr Flow uses a bidirectional gRPC stream
/// (flow_api.v1.TranscriptionService/TranscribeStream); this MVP uses a single HTTP POST
/// per utterance, which mirrors Wispr's own HTTP fallback path.
struct TranscriptionClient {
    struct Result: Decodable {
        let raw: String
        let text: String
        let formatter: String
        let latencyMs: Int

        enum CodingKeys: String, CodingKey {
            case raw, text, formatter
            case latencyMs = "latency_ms"
        }
    }

    private struct Request: Encodable {
        let audioWavB64: String
        let context: FocusContext.Snapshot?
        let language: String?

        enum CodingKeys: String, CodingKey {
            case audioWavB64 = "audio_wav_b64"
            case context, language
        }
    }

    let baseURL: URL

    func dictate(wav: Data, context: FocusContext.Snapshot?, language: String?) async throws -> Result {
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/dictate"))
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(Request(audioWavB64: wav.base64EncodedString(), context: context, language: language))

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "RustleApp", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Server error: \(body.prefix(200))"])
        }
        return try JSONDecoder().decode(Result.self, from: data)
    }
}
