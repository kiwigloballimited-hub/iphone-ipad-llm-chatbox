import SwiftUI
import WebKit

/// 显示内置浏览器（AI 正在操作的网页），用户也可以直接在里面操作
struct BrowserPanel: View {
    let session: BrowserSession
    var onClose: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    Task { _ = await session.goBack() }
                } label: {
                    Image(systemName: "chevron.backward")
                }
                .disabled(!session.canGoBack)

                VStack(alignment: .leading, spacing: 1) {
                    Text(session.title.isEmpty ? String(localized: "浏览器") : session.title)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Text(URL(string: session.currentURL)?.host ?? session.currentURL)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if session.isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        session.webView.reload()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }

                if let url = URL(string: session.currentURL), url.scheme?.hasPrefix("http") == true {
                    Link(destination: url) {
                        Image(systemName: "safari")
                    }
                    .accessibilityLabel("在 Safari 中打开")
                }

                if let onClose {
                    Button(action: onClose) {
                        Image(systemName: "xmark.circle.fill")
                            .symbolRenderingMode(.hierarchical)
                    }
                    .accessibilityLabel("收起浏览器")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)

            Divider()

            WebViewContainer(webView: session.webView)
        }
    }
}

/// 折叠状态下显示在聊天上方的一条浏览器状态栏（iPhone）
struct BrowserStatusBar: View {
    let session: BrowserSession
    let onExpand: () -> Void

    var body: some View {
        Button(action: onExpand) {
            HStack(spacing: 8) {
                Image(systemName: "globe")
                if session.isLoading {
                    ProgressView().controlSize(.mini)
                }
                Text(session.title.isEmpty ? (URL(string: session.currentURL)?.host ?? String(localized: "浏览器")) : session.title)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.down")
            }
            .font(.caption)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .buttonStyle(.plain)
    }
}

/// 把会话里的 WKWebView 放进 SwiftUI。用容器视图承载，避免同一个 WKWebView 被重复创建。
struct WebViewContainer: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.clipsToBounds = true
        attach(to: container)
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        if webView.superview !== container {
            attach(to: container)
        }
    }

    private func attach(to container: UIView) {
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = true
        webView.frame = container.bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(webView)
    }
}
