import AVFoundation
import Foundation
import Speech

enum SpeechInputLifecycleState: Equatable {
    case idle
    case requestingPermissions
    case recording
}

enum SpeechInputLifecycleEvent: Equatable {
    case startRequested
    case recordingStarted
    case stopRequested
    case permissionDenied
    case interrupted
}

struct SpeechInputLifecycleReducer {
    static func reduce(_ state: SpeechInputLifecycleState, event: SpeechInputLifecycleEvent) -> SpeechInputLifecycleState {
        switch event {
        case .startRequested:
            return state == .idle ? .requestingPermissions : state
        case .recordingStarted:
            return state == .requestingPermissions ? .recording : state
        case .stopRequested, .permissionDenied, .interrupted:
            return .idle
        }
    }
}

struct SpeechRecognitionCallbackDecision: Equatable {
    let shouldStop: Bool
    let shouldReportError: Bool

    static func evaluate(isFinal: Bool, hasError: Bool) -> SpeechRecognitionCallbackDecision {
        SpeechRecognitionCallbackDecision(
            shouldStop: isFinal || hasError,
            shouldReportError: hasError && !isFinal
        )
    }
}

@MainActor
final class SpeechInputController: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var isStarting = false
    @Published private(set) var errorMessage: String?
    private(set) var lifecycleState: SpeechInputLifecycleState = .idle

    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?
    private var tapInstalled = false
    private var lifecycleGeneration: UInt64 = 0
    private var interruptionObserver: NSObjectProtocol?

    override init() {
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
        super.init()
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw),
                  type == .began else { return }
            Task { @MainActor [weak self] in
                guard let self, self.isRecording || self.isStarting else { return }
                self.errorMessage = "语音输入已被系统中断，请重新开始。"
                self.stop()
            }
        }
    }

    deinit {
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
    }

    func dismissError() { errorMessage = nil }

    private func transition(_ event: SpeechInputLifecycleEvent) {
        lifecycleState = SpeechInputLifecycleReducer.reduce(lifecycleState, event: event)
        isStarting = lifecycleState == .requestingPermissions
        isRecording = lifecycleState == .recording
    }

    func toggle(onTranscript: @escaping (String) -> Void) {
        if isRecording || isStarting {
            stop()
        } else {
            Task { await start(onTranscript: onTranscript) }
        }
    }

    func stop() {
        lifecycleGeneration &+= 1
        transition(.stopRequested)
        if audioEngine.isRunning { audioEngine.stop() }
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func start(onTranscript: @escaping (String) -> Void) async {
        guard !isStarting && !isRecording else { return }
        transition(.startRequested)
        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        defer {
            if generation == lifecycleGeneration && lifecycleState == .requestingPermissions {
                transition(.interrupted)
            }
        }
        errorMessage = nil
        let speechAuthorized = await requestSpeechAuthorization()
        guard generation == lifecycleGeneration else { return }
        guard speechAuthorized else {
            errorMessage = "需要语音识别权限才能使用语音输入。"
            transition(.permissionDenied)
            return
        }
        let microphoneAuthorized = await requestMicrophoneAuthorization()
        guard generation == lifecycleGeneration else { return }
        guard microphoneAuthorized else {
            errorMessage = "需要麦克风权限才能使用语音输入。"
            transition(.permissionDenied)
            return
        }
        guard generation == lifecycleGeneration else { return }
        guard let recognizer, recognizer.isAvailable else {
            errorMessage = "当前语音识别暂不可用。"
            transition(.interrupted)
            return
        }

        if audioEngine.isRunning { audioEngine.stop() }
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            if #available(iOS 16.0, *) { request.addsPunctuation = true }
            recognitionRequest = request

            let inputNode = audioEngine.inputNode
            let format = inputNode.outputFormat(forBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak request] buffer, _ in
                request?.append(buffer)
            }
            tapInstalled = true
            audioEngine.prepare()
            try audioEngine.start()
            guard generation == lifecycleGeneration else {
                stop()
                return
            }
            transition(.recordingStarted)

            recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    guard let self, generation == self.lifecycleGeneration else { return }
                    if let result {
                        onTranscript(result.bestTranscription.formattedString)
                    }
                    let decision = SpeechRecognitionCallbackDecision.evaluate(
                        isFinal: result?.isFinal == true,
                        hasError: error != nil
                    )
                    if decision.shouldReportError {
                        self.errorMessage = "语音识别已中断，请重试。"
                    }
                    if decision.shouldStop {
                        self.stop()
                    }
                }
            }
        } catch {
            errorMessage = "无法启动语音输入：\(error.localizedDescription)"
            stop()
        }
    }

    private func requestSpeechAuthorization() async -> Bool {
        if SFSpeechRecognizer.authorizationStatus() == .authorized { return true }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    private func requestMicrophoneAuthorization() async -> Bool {
        let session = AVAudioSession.sharedInstance()
        switch session.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            return await withCheckedContinuation { continuation in
                session.requestRecordPermission { granted in continuation.resume(returning: granted) }
            }
        @unknown default:
            return false
        }
    }

}
