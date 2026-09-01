import Foundation

public actor CloudflareTransport: Transport {
    private let endpoint: URL
    private let urlSession: URLSession
    private var socket: URLSessionWebSocketTask?
    private var stream: AsyncThrowingStream<ProtocolV1.Event, Error>?
    private var continuation: AsyncThrowingStream<ProtocolV1.Event, Error>.Continuation?
    private var state: ProtocolV1.TransportState = .disconnected

    public init(endpoint: URL, configuration: URLSessionConfiguration = .default) {
        self.endpoint = endpoint
        self.urlSession = URLSession(configuration: configuration)
    }

    public func events() async -> AsyncThrowingStream<ProtocolV1.Event, Error> {
        if let stream {
            return stream
        }

        var capturedContinuation: AsyncThrowingStream<ProtocolV1.Event, Error>.Continuation?
        let newStream = AsyncThrowingStream<ProtocolV1.Event, Error> { continuation in
            capturedContinuation = continuation
        }
        stream = newStream
        continuation = capturedContinuation
        return newStream
    }

    public func connect() async throws {
        guard socket == nil else { return }
        state = .connecting
        emitState(.connecting)

        let newSocket = urlSession.webSocketTask(with: endpoint)
        socket = newSocket
        newSocket.resume()
        state = .connected
        emitState(.connected)
        receiveNext(from: newSocket)
    }

    public func disconnect() async {
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        state = .disconnected
        emitState(.disconnected)
    }

    public func currentState() async -> ProtocolV1.TransportState {
        state
    }

    public func send(_ command: ProtocolV1.Command) async throws {
        guard let socket else {
            throw TransportError.notConnected
        }

        do {
            let data = try JSONEncoder.remoteAI.encode(command)
            try await withCheckedThrowingContinuation { continuation in
                socket.send(.data(data)) { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        } catch let error as TransportError {
            throw error
        } catch {
            throw TransportError.underlying(error.localizedDescription)
        }
    }

    private func receiveNext(from socket: URLSessionWebSocketTask) {
        socket.receive { [weak self] result in
            Task {
                await self?.handle(result, from: socket)
            }
        }
    }

    private func handle(_ result: Result<URLSessionWebSocketTask.Message, Error>, from socket: URLSessionWebSocketTask) {
        guard self.socket === socket else { return }

        switch result {
        case .success(let message):
            do {
                let data: Data
                switch message {
                case .data(let receivedData): data = receivedData
                case .string(let string):
                    guard let stringData = string.data(using: .utf8) else { throw TransportError.invalidPayload }
                    data = stringData
                @unknown default:
                    throw TransportError.invalidPayload
                }
                let event = try JSONDecoder.remoteAI.decode(ProtocolV1.Event.self, from: data)
                continuation?.yield(event)
                receiveNext(from: socket)
            } catch {
                continuation?.yield(with: .failure(TransportError.underlying(error.localizedDescription)))
            }
        case .failure(let error):
            self.socket = nil
            state = .reconnecting
            emitState(.reconnecting)
            continuation?.yield(ProtocolV1.Event(
                sequence: 0,
                type: .error,
                body: ProtocolV1.EventBody(errorCode: "websocket_receive", errorMessage: error.localizedDescription)
            ))
        }
    }

    private func emitState(_ newState: ProtocolV1.TransportState) {
        continuation?.yield(ProtocolV1.Event(
            sequence: 0,
            type: .transportState,
            body: ProtocolV1.EventBody(state: newState)
        ))
    }
}

private extension JSONEncoder {
    static var remoteAI: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var remoteAI: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
