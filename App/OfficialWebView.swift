import SwiftUI
import WebKit
import ExViewerCore

struct WebDestination: Identifiable, Hashable {
    let id = UUID()
    var title: String
    var url: URL
    var login = false
    static var login: Self { .init(title: "站点登录", url: URL(string: "https://forums.e-hentai.org/index.php?act=Login&CODE=00")!, login: true) }
}
/// Uses the current navigation stack, so the shared bars stay on screen.
extension View {
    func officialWebPage(item: Binding<WebDestination?>, onDismiss: (() -> Void)? = nil) -> some View {
        navigationDestination(item: item) { OfficialWebView(destination: $0) }
            .onChange(of: item.wrappedValue?.id) { old, new in
                if old != nil && new == nil { onDismiss?() }
            }
    }
}

struct OfficialWebView: View {
    var destination: WebDestination
    @EnvironmentObject private var session: SiteSession
    @Environment(\.dismiss) private var dismiss
    @State private var ready = false
    @State private var loading = false
    @State private var error: String?
    @State private var verifying = false
    @State private var operation: UUID?
    @State private var verificationTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: FeedChrome.iconLabelSpacing) {
                Image(systemName: "lock.fill")
                Text(destination.url.host ?? "").textSelection(.enabled).lineLimit(1)
                Spacer(minLength: 0)
                if loading { ProgressView().controlSize(.mini) }
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, FeedChrome.contentInset).padding(.vertical, FeedChrome.contentTopGap)
            .background(FloatingChrome.background)
            if ready {
                SiteWebSurface(url: destination.url, store: session.webStore, loading: $loading, error: $error)
            } else {
                Spacer(); ProgressView(); Spacer()
            }
        }
        .appToast(message: $error, identifier: "official-web.error")
        .avoidingPinnedBottomBar()
        .background(Color(uiColor: .systemGroupedBackground))
        .appNavigationChrome(backButton: true, showsToolbarBackButton: false)
        .floatingPageHeader(destination.title, identifier: "official-web", pinned: true) {
            Button { dismiss() } label: { Image(systemName: "xmark") }
                .buttonStyle(FeedHeaderButtonStyle())
                .accessibilityLabel("关闭")
                .accessibilityIdentifier("official-web.close")
        } trailing: { completionAction }
        .task { await prepare() }
        .onDisappear {
            verificationTask?.cancel()
            verificationTask = nil
            if let operation { session.endWebOperation(operation) }
            operation = nil
            verifying = false
        }
    }

    @ViewBuilder private var completionAction: some View {
        if destination.login {
            Button(action: finishLogin) {
                if verifying { ProgressView().controlSize(.mini) }
                else { Image(systemName: "checkmark") }
            }
            .buttonStyle(FeedHeaderButtonStyle())
            .foregroundStyle(Color.accentColor)
            .disabled(verifying || (!AppMode.qa && operation == nil))
            .accessibilityLabel(verifying ? "验证中" : "完成登录")
            .accessibilityHint("读取并验证站点登录会话")
        }
    }

    private func prepare() async {
        // Keeping `ready` preserves entered web form content when switching tabs.
        if AppMode.qa { ready = true; return }
        do {
            let operation = try session.beginWebOperation()
            self.operation = operation
            try await session.prepareWebSession(operation: operation)
            try Task.checkCancellation()
            ready = true
        } catch is CancellationError { }
        catch {
            guard !Task.isCancelled else { return }
            self.error = (error as? ViewerError)?.localizedDescription ?? "网页会话准备失败 请重新打开"
        }
    }

    private func finishLogin() {
        verifying = true
        let currentOperation = operation
        verificationTask = Task {
            defer { if operation == currentOperation { verifying = false } }
            do {
                guard let currentOperation else { throw ViewerError.stale }
                try await session.captureWebSession(operation: currentOperation)
                try Task.checkCancellation()
                await session.verify()
                try Task.checkCancellation()
                guard operation == currentOperation else { return }
                dismiss()
            } catch is CancellationError { }
            catch {
                guard !Task.isCancelled, operation == currentOperation else { return }
                self.error = (error as? ViewerError)?.localizedDescription ?? "会话保存失败"
            }
        }
    }
}
struct SiteWebSurface: UIViewRepresentable {
    var url: URL
    var store: WKWebsiteDataStore
    @Binding var loading: Bool
    @Binding var error: String?
    func makeCoordinator() -> Coordinator { Coordinator(loading: $loading, error: $error) }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = AppMode.qa ? .nonPersistent() : store
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator; view.uiDelegate = context.coordinator
        if AppMode.qa {
            view.loadHTMLString(WebCompatibilityQA.html, baseURL: nil)
        } else if URLPolicy.account(url) { view.load(URLRequest(url: url)) }
        return view
    }
    func updateUIView(_ uiView: WKWebView, context: Context) { }
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        @Binding var loading: Bool
        @Binding var error: String?
        init(loading: Binding<Bool>, error: Binding<String?>) { _loading = loading; _error = error }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
            if SiteWebNavigation.allows(url, isMainFrame: navigationAction.targetFrame?.isMainFrame) { decisionHandler(.allow) }
            else { error = "链接不受支持 已停止跳转"; decisionHandler(.cancel) }
        }
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { loading = true; error = nil }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loading = false }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError: Error) { loading = false; error = "页面载入失败 请检查网络" }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError: Error) { loading = false; error = "页面载入未完成 请重试" }
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url, URLPolicy.account(url) { webView.load(URLRequest(url: url)) }
            return nil
        }
    }
}

enum WebCompatibilityQA {
    static let html = #"""
    <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"></head>
    <body><p>本机网页子页面检查</p><input aria-label="网页测试输入" placeholder="网页测试输入"><iframe title="Local bootstrap check" style="width:100%;height:160px;border:0" srcdoc="&lt;html&gt;&lt;body&gt;&lt;script&gt;document.body.textContent='子页面兼容检查通过';&lt;/script&gt;&lt;/body&gt;&lt;/html&gt;"></iframe></body></html>
    """#
}
struct WebCompatibilityQAView: View {
    @State private var loading = false
    @State private var error: String?
    private let store = WKWebsiteDataStore.nonPersistent()
    var body: some View {
        NavigationStack {
            VStack {
                SiteWebSurface(url: GallerySite.eh.baseURL, store: store, loading: $loading, error: $error)
            }.appToast(message: $error, identifier: "web-compat.error").navigationTitle("网页兼容检查")
        }
    }
}
