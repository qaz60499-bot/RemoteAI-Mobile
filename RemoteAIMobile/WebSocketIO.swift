import Foundation

private final class WebSocketContinuationBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func resume(with result: Result<Value, Error>) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()
        continuation.resume(with: result)
    }
}

enum WebSocketIO {
    static func send(
        _ message: URLSessionWebSocketTask.Message,
        on socket: URLSessionWebSocketTask,
        timeout: TimeInterval,
        timeoutReason: String = "websocket-send-timeout"
    ) async throws {
        guard timeout > 0 else { throw TransportError.timeout }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let box = WebSocketContinuationBox(continuation)
            let deadline = DispatchWorkItem {
                socket.cancel(with: .goingAway, reason: Data(timeoutReason.utf8))
                box.resume(with: .failure(TransportError.timeout))
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout, execute: deadline)
            socket.send(message) { error in
                deadline.cancel()
                if let error { box.resume(with: .failure(error)) }
                else { box.resume(with: .success(())) }
            }
        }
    }

    static func receive(
        from socket: URLSessionWebSocketTask,
        timeout: TimeInterval,
        timeoutReason: String = "websocket-receive-timeout"
    ) async throws -> URLSessionWebSocketTask.Message {
        guard timeout > 0 else { throw TransportError.timeout }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URLSessionWebSocketTask.Message, Error>) in
            let box = WebSocketContinuationBox(continuation)
            let deadline = DispatchWorkItem {
                socket.cancel(with: .goingAway, reason: Data(timeoutReason.utf8))
                box.resume(with: .failure(TransportError.timeout))
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout, execute: deadline)
            socket.receive { result in
                deadline.cancel()
                box.resume(with: result)
            }
        }
    }

    static func data(from message: URLSessionWebSocketTask.Message) -> Data {
        switch message {
        case .data(let value): return value
        case .string(let value): return Data(value.utf8)
        @unknown default: return Data()
        }
    }
}
