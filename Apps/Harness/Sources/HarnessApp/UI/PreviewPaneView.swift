import AppKit
import WebKit
import HarnessCore

/// Lives in the same pane island and responder chain as a terminal. Page scripts
/// receive no Harness bridge; browsing state is memory-only for this view's lifetime.
@MainActor
final class PreviewPaneView: NSView, WKNavigationDelegate, WKUIDelegate {
    let surfaceID: SurfaceID
    let hostOwner: String
    private let web: WKWebView
    private let address = HarnessTextField()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let external = HarnessPillButton(title: "Open in browser", kind: .secondary)
    private let back = HarnessPillButton(title: "Back", kind: .secondary)
    private let reload = HarnessPillButton(title: "Reload", kind: .secondary)
    private var externalURL: URL?
    private var specification: PreviewSpecification?
    private var loadGeneration = 0
    private var forwardToken = UUID()
    private var stopped = false
    private var resolvedURL: URL?
    var onEdit: ((PreviewSpecification) -> Void)?

    init(surfaceID: SurfaceID, hostOwner: String) {
        self.surfaceID = surfaceID; self.hostOwner = hostOwner
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        web = WKWebView(frame: .zero, configuration: configuration)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = HarnessChrome.current.sidebarBackground.cgColor
        web.navigationDelegate = self; web.uiDelegate = self
        back.target = self; back.action = #selector(goBack)
        reload.target = self; reload.action = #selector(reloadPage)
        address.placeholderString = "http://localhost:3000"; address.target = self; address.action = #selector(editAddress)
        address.setAccessibilityLabel("Preview URL on \(hostOwner)")
        external.target = self; external.action = #selector(openExternal); external.isHidden = true
        status.setAccessibilityLabel("Preview status"); status.maximumNumberOfLines = 3
        status.font = .systemFont(ofSize: 11)
        address.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let toolbar = NSStackView(views: [back, reload, address]); toolbar.orientation = .horizontal; toolbar.spacing = 6
        let messages = NSStackView(views: [status, external]); messages.orientation = .horizontal; messages.spacing = 8
        let stack = NSStackView(views: [toolbar, messages, web]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8), stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8), stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            toolbar.widthAnchor.constraint(equalTo: stack.widthAnchor), messages.widthAnchor.constraint(equalTo: stack.widthAnchor), web.widthAnchor.constraint(equalTo: stack.widthAnchor),
            address.widthAnchor.constraint(greaterThanOrEqualToConstant: 80), web.heightAnchor.constraint(greaterThanOrEqualToConstant: 80)
        ])
        web.setContentHuggingPriority(.init(1), for: .vertical)
        setAccessibilityLabel("Preview pane on \(hostOwner)")
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged(_:)), name: NotificationBus.shared.snapshotChanged, object: nil)
        applyChrome()
    }
    deinit { NotificationCenter.default.removeObserver(self) }
    @objc private func themeChanged(_ notification: Notification) {
        guard notification.userInfo?["chromeChanged"] as? Bool == true else { return }
        applyChrome()
    }
    private func applyChrome() {
        let c = HarnessChrome.current
        layer?.backgroundColor = c.sidebarBackground.cgColor
        address.applyChrome()
        status.textColor = c.textSecondary
        for button in [back, reload, external] { button.applyChrome() }
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    func update(_ value: PreviewSpecification) {
        guard specification != value else { return }; specification = value; address.stringValue = value.url; load()
    }
    func focusContent() { window?.makeFirstResponder(web) }
    func stop() {
        stopped = true; loadGeneration += 1; web.stopLoading()
        SSHTunnelManager.shared.stopPreview(host: hostOwner, surfaceID: surfaceID, token: forwardToken)
    }
    @objc private func goBack() { web.goBack() }
    @objc private func reloadPage() { load() }
    @objc private func editAddress() {
        let value = PreviewSpecification(url: address.stringValue, title: specification?.title)
        do { _ = try value.validatedURL(); onEdit?(value) } catch { status.stringValue = error.localizedDescription }
    }
    @objc private func openExternal() {
        guard let externalURL else { return }; NSWorkspace.shared.open(externalURL); self.externalURL = nil; external.isHidden = true
    }
    private func load() {
        guard !stopped, let specification else { return }
        loadGeneration += 1; forwardToken = UUID(); let generation = loadGeneration
        web.stopLoading(); resolvedURL = nil; externalURL = nil; external.isHidden = true
        do {
            let url = try specification.validatedURL()
            guard hostOwner == DaemonSidebar.localID else { status.stringValue = "Connecting preview to \(hostOwner)…"; loadRemote(specification, generation: generation); return }
            resolvedURL = url; status.stringValue = "Loading…"; web.load(URLRequest(url: url))
        } catch { status.stringValue = error.localizedDescription }
    }
    private func loadRemote(_ specification: PreviewSpecification, generation: Int) {
        let owner = hostOwner, id = surfaceID, token = forwardToken, epoch = SSHTunnelManager.shared.connectionEpoch(for: hostOwner)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result: Result<URL, Error> = Result {
                guard let host = RemoteHostsService.shared.hosts().first(where: { $0.name == owner }) else { throw SSHTunnelError.invalidConfiguration("The preview host is no longer configured.") }
                return try SSHTunnelManager.shared.previewURL(for: host, surfaceID: id, token: token, specification: specification, expectedEpoch: epoch)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.stopped, self.loadGeneration == generation else {
                    SSHTunnelManager.shared.stopPreview(host: owner, surfaceID: id, token: token); return
                }
                switch result {
                case let .success(url): self.resolvedURL = url; self.status.stringValue = "Loading through SSH…"; self.web.load(URLRequest(url: url))
                case let .failure(error): self.status.stringValue = error.localizedDescription
                }
            }
        }
    }
    private func allows(_ url: URL) -> Bool {
        guard (try? PreviewSpecification(url: url.absoluteString).validatedURL()) != nil else { return false }
        guard hostOwner != DaemonSidebar.localID else { return true }
        // A remote page's navigation must stay on its managed forward. Its logical
        // remote loopback URLs are not rewritten or opened against this Mac.
        guard let resolvedURL else { return false }
        return url.host == resolvedURL.host && url.port == resolvedURL.port && url.scheme == resolvedURL.scheme
    }
    private func blocked(_ url: URL?) {
        guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.user == nil, url.password == nil else { status.stringValue = "This navigation is unavailable in preview panes."; return }
        externalURL = url; external.isHidden = false
        status.stringValue = "External navigation was blocked. Open the link using the browser button." // Button requires a native user action, even for script-triggered links.
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard !action.shouldPerformDownload, let url = action.request.url, !url.isFileURL else { status.stringValue = "Downloads and file navigation are unavailable."; return .cancel }
        if action.targetFrame?.isMainFrame != false && !allows(url) { blocked(url); return .cancel }
        // External HTTP(S) subresources are allowed; this is not an all-network sandbox.
        guard ["http", "https", "about", "blob", "data"].contains(url.scheme?.lowercased() ?? "") else { return .cancel }
        return .allow
    }
    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        guard response.canShowMIMEType, !response.isForMainFrame || response.response.url.map(allows) == true else { status.stringValue = "This response cannot be displayed in the preview."; return .cancel }
        return .allow
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { blocked(action.request.url); return nil }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { status.stringValue = "Preview on \(hostOwner) · browser data stays in memory" }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { showFailure(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { showFailure(error) }
    private func showFailure(_ error: Error) { guard (error as NSError).code != NSURLErrorCancelled else { return }; status.stringValue = error.localizedDescription + " Use Reload after the server or connection is available." }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { status.stringValue = "The preview renderer stopped. Reload to reconnect." }
}
