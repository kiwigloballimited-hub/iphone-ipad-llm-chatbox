import SwiftUI

/// 语音提问：说完后可以直接发送，或放进输入框再修改
struct VoiceInputSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let agent: Agent?
    let onSend: (String) -> Void
    let onInsert: (String) -> Void

    @State private var recognizer = SpeechRecognizer()
    @State private var text = ""
    @State private var editing = false

    var body: some View {
        @Bindable var store = store

        NavigationStack {
            VStack(spacing: 20) {
                if let agent {
                    HStack(spacing: 8) {
                        AgentAvatar(avatar: agent.avatar, size: 32)
                        Text(agent.name).font(.headline)
                    }
                }

                ScrollView {
                    Group {
                        if editing || !recognizer.isRecording {
                            TextField("说点什么…", text: $text, axis: .vertical)
                                .lineLimit(3...12)
                        } else {
                            Text(recognizer.transcript.isEmpty ? "请开始说话…" : recognizer.transcript)
                                .foregroundStyle(recognizer.transcript.isEmpty ? .secondary : .primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .font(.title3)
                    .padding()
                }
                .frame(maxHeight: 260)
                .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemBackground)))

                if let error = recognizer.errorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                Button {
                    toggleRecording()
                } label: {
                    ZStack {
                        Circle()
                            .fill(recognizer.isRecording ? Color.red.opacity(0.15) : Color.accentColor.opacity(0.15))
                            .frame(width: 96 + CGFloat(recognizer.level) * 40, height: 96 + CGFloat(recognizer.level) * 40)
                            .animation(.easeOut(duration: 0.15), value: recognizer.level)
                        Circle()
                            .fill(recognizer.isRecording ? Color.red : Color.accentColor)
                            .frame(width: 80, height: 80)
                        Image(systemName: recognizer.isRecording ? "stop.fill" : "mic.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(.white)
                    }
                    .frame(height: 140)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(recognizer.isRecording ? "停止录音" : "开始录音")

                Text(recognizer.isRecording ? "说完后点一下停止" : "点按麦克风开始说话")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Picker("识别语言", selection: $store.media.voiceLocale) {
                    ForEach(SpeechRecognizer.languages, id: \.id) { language in
                        Text(language.name).tag(language.id)
                    }
                }
                .pickerStyle(.menu)
                .disabled(recognizer.isRecording)

                Spacer(minLength: 0)
            }
            .padding()
            .navigationTitle("语音提问")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        recognizer.stop()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("放入输入框") {
                        finish { onInsert($0) }
                    }
                    .disabled(currentText.isBlank)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("发送") {
                        finish { onSend($0) }
                    }
                    .disabled(currentText.isBlank)
                }
            }
            .onChange(of: recognizer.isRecording) { _, recording in
                if !recording && !recognizer.transcript.isEmpty { text = recognizer.transcript }
            }
            .onChange(of: recognizer.transcript) { _, value in
                // 停止后可能还会收到带标点的最终结果
                if !recognizer.isRecording && !value.isEmpty { text = value }
            }
            .task {
                // 打开后自动开始录音
                await recognizer.start(localeID: store.media.voiceLocale)
            }
            .onDisappear { recognizer.stop() }
        }
        .presentationDetents([.medium, .large])
    }

    private var currentText: String {
        recognizer.isRecording ? recognizer.transcript : text
    }

    private func toggleRecording() {
        if recognizer.isRecording {
            recognizer.stop()
        } else {
            editing = false
            Task { await recognizer.start(localeID: store.media.voiceLocale) }
        }
    }

    private func finish(_ action: (String) -> Void) {
        let value = currentText.trimmed
        recognizer.stop()
        guard !value.isEmpty else { return }
        action(value)
        dismiss()
    }
}
