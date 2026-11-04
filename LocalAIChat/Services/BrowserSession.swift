import Foundation
import Observation
import WebKit

/// 某个对话专用的内置浏览器。AI 通过它打开网页、阅读、点击和输入；用户也可以直接在界面上操作。
@MainActor
@Observable
final class BrowserSession: NSObject, WKUIDelegate {
    let webView: WKWebView
    var currentURL = ""
    var title = ""
    var isLoading = false
    var canGoBack = false

    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    /// 页面快照（文字中内嵌了可交互元素的编号）
    struct Snapshot {
        let title: String
        let url: String
        let content: String
        let elementCount: Int
    }

    struct ElementInfo {
        let found: Bool
        let tag: String
        let type: String
        let text: String
        let hasPasswordInForm: Bool
        let isSubmit: Bool
    }

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.allowsInlineMediaPlayback = true
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: configuration)
        super.init()
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        webView.allowsBackForwardNavigationGestures = true
        webView.uiDelegate = self

        observations = [
            webView.observe(\.url) { [weak self] webView, _ in
                Task { @MainActor in self?.currentURL = webView.url?.absoluteString ?? "" }
            },
            webView.observe(\.title) { [weak self] webView, _ in
                Task { @MainActor in self?.title = webView.title ?? "" }
            },
            webView.observe(\.isLoading) { [weak self] webView, _ in
                Task { @MainActor in self?.isLoading = webView.isLoading }
            },
            webView.observe(\.canGoBack) { [weak self] webView, _ in
                Task { @MainActor in self?.canGoBack = webView.canGoBack }
            },
        ]
    }

    // 在新窗口打开的链接（target=_blank / window.open）改为在当前页面打开
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
    }

    // MARK: - Navigation

    func load(_ url: URL) async {
        webView.load(URLRequest(url: url))
        await waitForLoad()
    }

    func goBack() async -> Bool {
        guard webView.canGoBack else { return false }
        webView.goBack()
        await waitForLoad()
        return true
    }

    func scroll(down: Bool) async {
        _ = try? await webView.callAsyncJavaScript(
            "window.scrollBy(0, (down ? 0.8 : -0.8) * window.innerHeight); return true;",
            arguments: ["down": down],
            contentWorld: .defaultClient
        )
        try? await Task.sleep(nanoseconds: 600_000_000)
    }

    /// 等待页面加载完成（含一点渲染时间）
    func waitForLoad(timeout: TimeInterval = 15) async {
        try? await Task.sleep(nanoseconds: 400_000_000)
        let deadline = Date().addingTimeInterval(timeout)
        while webView.isLoading && Date() < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        try? await Task.sleep(nanoseconds: 500_000_000)
    }

    // MARK: - Page reading

    func snapshot() async -> Snapshot {
        let fallback = Snapshot(title: webView.title ?? "", url: webView.url?.absoluteString ?? "", content: "", elementCount: 0)
        guard let raw = try? await webView.callAsyncJavaScript(Self.snapshotScript, arguments: ["L": Self.elementLabels], contentWorld: .defaultClient),
              let string = raw as? String,
              let data = string.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return fallback
        }
        return Snapshot(
            title: json["title"] as? String ?? fallback.title,
            url: json["url"] as? String ?? fallback.url,
            content: json["content"] as? String ?? "",
            elementCount: json["count"] as? Int ?? 0
        )
    }

    func elementInfo(_ id: Int) async -> ElementInfo {
        let missing = ElementInfo(found: false, tag: "", type: "", text: "", hasPasswordInForm: false, isSubmit: false)
        guard let raw = try? await webView.callAsyncJavaScript(Self.describeScript, arguments: ["id": String(id)], contentWorld: .defaultClient),
              let string = raw as? String,
              let data = string.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              json["found"] as? Bool == true else {
            return missing
        }
        return ElementInfo(
            found: true,
            tag: json["tag"] as? String ?? "",
            type: json["type"] as? String ?? "",
            text: json["text"] as? String ?? "",
            hasPasswordInForm: json["hasPasswordInForm"] as? Bool ?? false,
            isSubmit: json["isSubmit"] as? Bool ?? false
        )
    }

    // MARK: - Interaction

    /// 点击元素。返回 false 表示找不到该编号的元素。
    func click(_ id: Int) async -> Bool {
        let result = try? await webView.callAsyncJavaScript(Self.clickScript, arguments: ["id": String(id)], contentWorld: .defaultClient)
        if let string = result as? String, string == "NOT_FOUND" { return false }
        await waitForLoad(timeout: 10)
        return true
    }

    /// 输入文字（或选择下拉框选项）。返回 "OK" / "NOT_FOUND" / "NO_OPTION"
    func type(_ id: Int, text: String, submit: Bool) async -> String {
        let result = try? await webView.callAsyncJavaScript(
            Self.typeScript,
            arguments: ["id": String(id), "text": text, "submit": submit],
            contentWorld: .defaultClient
        )
        let status = (result as? String) ?? "OK"
        if status == "OK" {
            await waitForLoad(timeout: submit ? 12 : 2)
        }
        return status
    }

    static func clearAllData() async {
        let store = WKWebsiteDataStore.default()
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }

    /// 页面快照中元素类型的名称（发给模型，跟随 App 语言）
    private static var elementLabels: [String: String] {
        [
            "link": String(localized: "链接"),
            "button": String(localized: "按钮"),
            "checkbox": String(localized: "复选框"),
            "radio": String(localized: "单选"),
            "checked": String(localized: "(已选中)"),
            "unchecked": String(localized: "(未选中)"),
            "password": String(localized: "密码框"),
            "input": String(localized: "输入框"),
            "textarea": String(localized: "多行输入框"),
            "value": String(localized: "当前值"),
            "select": String(localized: "下拉框"),
            "current": String(localized: "当前"),
            "options": String(localized: "选项"),
            "editable": String(localized: "编辑区"),
            "clickable": String(localized: "可点击"),
            "image": String(localized: "图片"),
        ]
    }

    // MARK: - Scripts（在独立的 JS 环境中运行，网页脚本无法篡改）

    private static let snapshotScript = #"""
    document.querySelectorAll('[data-ai-id]').forEach(e => e.removeAttribute('data-ai-id'));
    const out = [];
    let id = 0;
    let length = 0;
    const LIMIT = 300000;
    const SKIP = new Set(['SCRIPT','STYLE','NOSCRIPT','TEMPLATE','IFRAME','CANVAS','svg','SVG','HEAD','META','LINK']);
    const BLOCK = new Set(['P','DIV','SECTION','ARTICLE','LI','UL','OL','TR','TABLE','H1','H2','H3','H4','H5','H6','HEADER','FOOTER','NAV','MAIN','FORM','BR','HR','DT','DD','BLOCKQUOTE','PRE','FIGURE','ASIDE','DETAILS']);
    const ROLES = ['button','link','tab','menuitem','checkbox','radio','switch','option','combobox','textbox','searchbox'];
    const clean = s => (s || '').replace(/\s+/g, ' ').trim();
    const short = (s, n) => { s = clean(s); return s.length > n ? s.slice(0, n) + '…' : s; };
    const push = s => { if (length < LIMIT) { out.push(s); length += s.length; } };

    function hidden(el) {
      const st = getComputedStyle(el);
      return st.display === 'none' || st.visibility === 'hidden' || el.getAttribute('aria-hidden') === 'true';
    }
    function interactive(el) {
      const tag = el.tagName;
      if (tag === 'A') return el.hasAttribute('href');
      if (['BUTTON','INPUT','TEXTAREA','SELECT','SUMMARY'].includes(tag)) return !el.disabled;
      const role = el.getAttribute('role');
      if (role && ROLES.includes(role)) return true;
      if (el.hasAttribute('onclick')) return true;
      return el.isContentEditable && el.getAttribute('contenteditable') !== null;
    }
    function fieldLabel(el) {
      let text = el.getAttribute('aria-label') || el.getAttribute('placeholder') || '';
      if (!text && el.id) {
        const l = document.querySelector('label[for="' + CSS.escape(el.id) + '"]');
        if (l) text = l.innerText;
      }
      if (!text) { const l = el.closest('label'); if (l) text = l.innerText; }
      return short(text || el.getAttribute('name') || el.getAttribute('title') || '', 50);
    }
    function describe(el, n) {
      const tag = el.tagName;
      const type = (el.getAttribute('type') || '').toLowerCase();
      if (tag === 'A') {
        let text = short(el.innerText || el.getAttribute('aria-label') || el.title, 70);
        if (!text) { const img = el.querySelector('img[alt]'); if (img) text = short(img.alt, 70); }
        let href = '';
        try { const u = new URL(el.href); href = (u.host + u.pathname).slice(0, 70); } catch (e) {}
        return '[' + n + ']' + L.link + '「' + text + '」' + (href ? '→' + href : '');
      }
      if (tag === 'INPUT') {
        if (['submit','button','reset','image'].includes(type)) return '[' + n + ']' + L.button + '「' + short(el.value || el.getAttribute('aria-label') || el.alt, 40) + '」';
        if (type === 'checkbox' || type === 'radio') return '[' + n + ']' + (type === 'checkbox' ? L.checkbox : L.radio) + '「' + fieldLabel(el) + '」' + (el.checked ? L.checked : L.unchecked);
        if (type === 'password') return '[' + n + ']' + L.password + '「' + fieldLabel(el) + '」';
        const value = el.value ? ' ' + L.value + ':"' + short(el.value, 40) + '"' : '';
        return '[' + n + ']' + L.input + '「' + fieldLabel(el) + '」' + value;
      }
      if (tag === 'TEXTAREA') {
        const value = el.value ? ' ' + L.value + ':"' + short(el.value, 40) + '"' : '';
        return '[' + n + ']' + L.textarea + '「' + fieldLabel(el) + '」' + value;
      }
      if (tag === 'SELECT') {
        const options = Array.from(el.options).slice(0, 15).map(o => short(o.text, 20)).join(' / ');
        const current = el.selectedOptions[0] ? short(el.selectedOptions[0].text, 20) : '';
        return '[' + n + ']' + L.select + '「' + fieldLabel(el) + '」' + L.current + ':' + current + ' ' + L.options + ':' + options;
      }
      if (el.isContentEditable) return '[' + n + ']' + L.editable + '「' + short(el.innerText, 40) + '」';
      const text = short(el.innerText || el.getAttribute('aria-label') || el.title || el.value, 60);
      return '[' + n + ']' + (tag === 'BUTTON' ? L.button : L.clickable) + '「' + text + '」';
    }
    function walk(node) {
      if (length >= LIMIT) return;
      if (node.nodeType === 3) {
        const t = node.textContent.replace(/\s+/g, ' ');
        if (t.trim()) push(t);
        return;
      }
      if (node.nodeType !== 1) return;
      const el = node;
      if (SKIP.has(el.tagName) || hidden(el)) return;
      if (el.tagName === 'INPUT' && (el.getAttribute('type') || '').toLowerCase() === 'hidden') return;
      if (interactive(el)) {
        id += 1;
        el.setAttribute('data-ai-id', String(id));
        push(' ' + describe(el, id) + ' ');
        return;
      }
      const block = BLOCK.has(el.tagName);
      if (block) push('\n');
      if (el.tagName === 'IMG' && el.alt) push('[' + L.image + ':' + short(el.alt, 40) + ']');
      for (const child of el.childNodes) walk(child);
      if (block) push('\n');
    }
    if (document.body) walk(document.body);
    const content = out.join('')
      .split('\n').map(l => l.replace(/[ \t]+/g, ' ').trim()).filter(l => l.length > 0).join('\n');
    return JSON.stringify({ title: document.title, url: location.href, content: content, count: id });
    """#

    private static let describeScript = #"""
    const el = document.querySelector('[data-ai-id="' + id + '"]');
    if (!el) return JSON.stringify({ found: false });
    const form = el.form || el.closest('form');
    const type = (el.getAttribute('type') || (el.tagName === 'BUTTON' ? 'submit' : '')).toLowerCase();
    const text = (el.innerText || el.value || el.getAttribute('aria-label') || el.title || el.getAttribute('placeholder') || '').replace(/\s+/g, ' ').trim().slice(0, 80);
    return JSON.stringify({
      found: true,
      tag: el.tagName.toLowerCase(),
      type: type,
      text: type === 'password' ? '' : text,
      hasPasswordInForm: !!(form && form.querySelector('input[type=password]')),
      isSubmit: !!form && type === 'submit'
    });
    """#

    private static let clickScript = #"""
    const el = document.querySelector('[data-ai-id="' + id + '"]');
    if (!el) return 'NOT_FOUND';
    el.scrollIntoView({ block: 'center' });
    if (el.tagName === 'A' && el.getAttribute('target')) el.removeAttribute('target');
    if (typeof el.click === 'function') { el.click(); }
    else { el.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true })); }
    return 'OK';
    """#

    private static let typeScript = #"""
    const el = document.querySelector('[data-ai-id="' + id + '"]');
    if (!el) return 'NOT_FOUND';
    el.scrollIntoView({ block: 'center' });
    if (el.focus) el.focus();
    if (el.tagName === 'SELECT') {
      const options = Array.from(el.options);
      const option = options.find(o => o.text.trim() === text || o.value === text) || options.find(o => o.text.includes(text));
      if (!option) return 'NO_OPTION';
      el.value = option.value;
      el.dispatchEvent(new Event('input', { bubbles: true }));
      el.dispatchEvent(new Event('change', { bubbles: true }));
      return 'OK';
    }
    if (el.isContentEditable) {
      el.textContent = text;
      el.dispatchEvent(new InputEvent('input', { bubbles: true }));
    } else {
      const proto = el.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
      const descriptor = Object.getOwnPropertyDescriptor(proto, 'value');
      if (descriptor && descriptor.set) { descriptor.set.call(el, text); } else { el.value = text; }
      el.dispatchEvent(new Event('input', { bubbles: true }));
      el.dispatchEvent(new Event('change', { bubbles: true }));
    }
    if (submit) {
      const form = el.form || el.closest('form');
      if (form) {
        if (form.requestSubmit) { form.requestSubmit(); } else { form.submit(); }
      } else {
        const init = { key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true, cancelable: true };
        el.dispatchEvent(new KeyboardEvent('keydown', init));
        el.dispatchEvent(new KeyboardEvent('keypress', init));
        el.dispatchEvent(new KeyboardEvent('keyup', init));
      }
    }
    return 'OK';
    """#
}
