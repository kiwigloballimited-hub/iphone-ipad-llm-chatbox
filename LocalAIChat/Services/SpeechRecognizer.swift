import AVFoundation
import Foundation
import Observation
import Speech

/// 语音转文字（苹果语音识别；设备支持时优先在本机识别）
@MainActor
@Observable
final class SpeechRecognizer {
    var transcript = ""
    var isRecording = false
    var errorMessage: String?
    /// 输入音量（0...1），用于显示动画
    var level: Float = 0

    @ObservationIgnored private var audioEngine = AVAudioEngine()
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?

    static let languages: [(id: String, name: String)] = [
        ("zh-CN", String(localized: "中文（普通话）")),
        ("zh-HK", String(localized: "粤语")),
        ("zh-TW", String(localized: "中文（台湾）")),
        ("en-GB", "English (UK)"),
        ("en-US", "English (US)"),
    ]

    func start(localeID: String) async {
        errorMessage = nil
        guard await Self.requestPermissions() else {
            errorMessage = String(localized: "需要麦克风和语音识别权限。请在「设置 › 隐私与安全性」中允许「本地AI」使用麦克风和语音识别。")
            return
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeID)), recognizer.isAvailable else {
            errorMessage = String(localized: "当前语言的语音识别暂时不可用。")
            return
        }
        stop()
        transcript = ""

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.addsPunctuation = true
            if recognizer.supportsOnDeviceRecognition {
                request.requiresOnDeviceRecognition = true
            }
            self.request = request

            let input = audioEngine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.makeTap(request: request) { [weak self] level in
                Task { @MainActor in self?.level = level }
            })
            audioEngine.prepare()
            try audioEngine.start()

            task = recognizer.recognitionTask(with: request, resultHandler: Self.makeHandler { [weak self] text, isFinal, failed in
                Task { @MainActor in
                    guard let self else { return }
                    if let text { self.transcript = text }
                    if isFinal || failed { self.stop() }
                }
            })
            isRecording = true
        } catch {
            errorMessage = String(localized: "无法开始录音：\(error.localizedDescription)")
            stop()
        }
    }

    func stop() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.finish()
        request = nil
        task = nil
        isRecording = false
        level = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // 以下回调在音频 / 识别线程上调用，所以在非隔离的环境中创建

    nonisolated private static func makeTap(
        request: SFSpeechAudioBufferRecognitionRequest,
        onLevel: @escaping @Sendable (Float) -> Void
    ) -> AVAudioNodeTapBlock {
        { buffer, _ in
            request.append(buffer)
            guard let data = buffer.floatChannelData?[0] else { return }
            let count = Int(buffer.frameLength)
            guard count > 0 else { return }
            var sum: Float = 0
            for i in 0..<count { sum += data[i] * data[i] }
            let rms = (sum / Float(count)).squareRoot()
            onLevel(min(1, rms * 12))
        }
    }

    nonisolated private static func makeHandler(
        _ callback: @escaping @Sendable (String?, Bool, Bool) -> Void
    ) -> (SFSpeechRecognitionResult?, Error?) -> Void {
        { result, error in
            callback(result?.bestTranscription.formattedString, result?.isFinal ?? false, error != nil)
        }
    }

    private static func requestPermissions() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
        guard speech else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }
}
