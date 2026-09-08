#if DEBUG
    import Foundation
    import ManuscriptCore
    import WebKit

    extension MarkdownWebEditor.Coordinator {
        func evaluateForValidation(_ script: String) async throws -> Any {
            guard let webView else { throw ManuscriptError.editorUnavailable }
            let data: Data = try await withCheckedThrowingContinuation { continuation in
                let reply = ValidationReply(continuation)
                let timeout = Task { @MainActor in
                    do { try await Task.sleep(for: .seconds(25)) } catch { return }
                    reply.finish(
                        .failure(
                            NSError(
                                domain: "MyEditorValidation", code: 1,
                                userInfo: [
                                    NSLocalizedDescriptionKey: "WebKit validation timed out: "
                                        + String(script.prefix(120))
                                ])))
                }
                webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { result in
                    timeout.cancel()
                    do {
                        reply.finish(
                            .success(
                                try JSONSerialization.data(
                                    withJSONObject: result.get(), options: [.fragmentsAllowed])))
                    } catch { reply.finish(.failure(error)) }
                }
            }
            return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        }
    }

    @MainActor private final class ValidationReply {
        private var continuation: CheckedContinuation<Data, any Error>?
        init(_ continuation: CheckedContinuation<Data, any Error>) {
            self.continuation = continuation
        }
        func finish(_ result: Result<Data, any Error>) {
            continuation?.resume(with: result)
            continuation = nil
        }
    }
#endif
