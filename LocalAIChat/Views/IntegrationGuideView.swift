import SwiftUI

/// 说明如何使用 Siri、快捷指令、操作按钮、小组件和分享菜单
struct IntegrationGuideView: View {
    var body: some View {
        List {
            Section {
                guide("问助手", "「嘿 Siri，问本地AI」，然后说出问题。Siri 会直接读出回答，问答保存在该助手的「Siri 与快捷指令」对话里。也可以说「问本地AI的写作伙伴」指定助手。")
                guide("语音提问", "「嘿 Siri，用本地AI语音提问」，会打开 App 并直接开始录音。")
                guide("新对话", "「嘿 Siri，打开本地AI的小老师」。")
            } header: {
                Text("Siri")
            } footer: {
                Text("Siri 短语是中文的；如果 Siri 设置为英文，可以在「快捷指令」App 里给这些操作起一个英文名字再用 Siri 调用。")
            }

            Section {
                guide("设置方法", "打开 iPhone「设置 › 操作按钮」，滑到「快捷指令」，选择「本地AI › 语音提问」。之后按住操作按钮就能直接说话提问。")
                guide("适用机型", "iPhone 15 Pro 及之后带操作按钮的机型。")
            } header: {
                Text("操作按钮")
            }

            Section {
                guide("1. 新建快捷指令", "打开「快捷指令」App，点 ＋ 新建，添加操作「本地AI › 发送给助手」。")
                guide("2. 接收分享的内容", "把「文字」设为「快捷指令输入」；如果要分享图片，把「图片」也设为「快捷指令输入」。可以在「要求」里写「翻译成中文」「总结要点」等。")
                guide("3. 显示在分享菜单", "点底部的 ⓘ（或快捷指令名称旁的设置），打开「在共享表单中显示」，输入类型选「文本」「图像」「URL」。")
                guide("4. 使用", "在 Safari 或其他 App 中选中文字 / 图片 › 分享 › 选择这个快捷指令，App 会打开并开始回复。")
            } header: {
                Text("从分享菜单发送")
            } footer: {
                Text("可以为不同用途分别建几个快捷指令，例如「翻译成中文」「用小老师讲解」。")
            }

            Section {
                guide("快速提问", "长按桌面 › 编辑 › 添加小组件 › 本地AI。可以放在桌面或锁屏上；长按小组件 › 编辑，可以填写助手名称、图标，以及点击后是「新对话」还是「语音提问」。")
            } header: {
                Text("小组件")
            }

            Section {
                guide("显示进度", "生成回复或浏览器助手工作时，切到其他 App 或锁屏，可以在灵动岛和锁屏上看到进度、用时和当前步骤，点按回到对话。")
                guide("注意", "iOS 只允许 App 在后台运行很短时间（通常约 30 秒），长时间的生成可能会暂停，回到 App 后会自动续传。")
            } header: {
                Text("灵动岛 / 实时活动")
            }
        }
        .navigationTitle("Siri、快捷指令与操作按钮")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func guide(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(text).font(.callout).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
