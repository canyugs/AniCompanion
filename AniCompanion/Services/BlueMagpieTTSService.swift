import Foundation

final class BlueMagpieTTSService: TTSServiceProtocol, Sendable {
    private let endpoint: String
    private let inferenceTimesteps: Int
    private let session: URLSession

    init(endpoint: String, inferenceTimesteps: Int) {
        self.endpoint = endpoint
        self.inferenceTimesteps = inferenceTimesteps

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 180
        configuration.timeoutIntervalForResource = 600
        self.session = URLSession(configuration: configuration)
    }

    func synthesize(text: String, emotion: Emotion) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        continuation.finish(throwing: TTSError.emptyText)
                        return
                    }

                    let request = try buildRequest(text: text)
                    let (data, response) = try await session.data(for: request)

                    guard let httpResponse = response as? HTTPURLResponse else {
                        continuation.finish(throwing: TTSError.invalidResponse)
                        return
                    }

                    guard httpResponse.statusCode == 200 else {
                        let body = String(data: data, encoding: .utf8) ?? ""
                        continuation.finish(throwing: TTSError.requestFailed(
                            statusCode: httpResponse.statusCode,
                            body: body
                        ))
                        return
                    }

                    continuation.yield(data)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func buildRequest(text: String) throws -> URLRequest {
        guard let url = ttsURL(from: endpoint) else {
            throw TTSError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/wav", forHTTPHeaderField: "Accept")
        request.setValue("close", forHTTPHeaderField: "Connection")

        let body: [String: Any] = [
            "text": text,
            "inference_timesteps": max(1, inferenceTimesteps)
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func ttsURL(from endpoint: String) -> URL? {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var components = URLComponents(string: trimmed) else {
            return nil
        }

        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.isEmpty {
            components.path = "/v1/tts"
        } else if path != "v1/tts" {
            components.path = "/" + path + "/v1/tts"
        }

        return components.url
    }
}
