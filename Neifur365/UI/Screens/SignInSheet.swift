import SwiftUI
import WebKit

struct SignInSheet: View {
    @EnvironmentObject private var app: AppContainer
    @Environment(\.dismiss) private var dismiss

    @State private var email = ""
    @State private var password = ""
    @State private var showPassword = false
    @State private var busy = false
    @State private var errorMessage: String?
    @State private var showSiteWebView = false
    @State private var resolvedBase: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Аккаунт Anime 365")
                            .font(NfType.display)
                            .foregroundColor(Nf.text)
                        Text("Видео, списки и отметки о просмотре синхронизируются с вашим аккаунтом Anime 365.")
                            .font(NfType.body)
                            .foregroundColor(Nf.textDim)
                    }
                    .padding(.vertical, 4)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 6, leading: 4, bottom: 6, trailing: 4))
                }

                Section {
                    TextField("E-mail", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    HStack {
                        if showPassword {
                            TextField("Пароль", text: $password)
                                .textContentType(.password)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        } else {
                            SecureField("Пароль", text: $password)
                                .textContentType(.password)
                        }
                        Button {
                            showPassword.toggle()
                        } label: {
                            Image(systemName: showPassword ? "eye.slash" : "eye")
                                .foregroundColor(Nf.textMute)
                        }
                        .buttonStyle(.plain)
                    }
                } footer: {
                    if let errorMessage {
                        Text(errorMessage)
                            .foregroundColor(Nf.red)
                    }
                }

                Section {
                    Button {
                        submitLogin()
                    } label: {
                        HStack {
                            Spacer()
                            if busy {
                                ProgressView()
                            } else {
                                Text("Войти")
                                    .font(NfType.title)
                            }
                            Spacer()
                        }
                    }
                    .disabled(busy || email.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty)
                }

                Section {
                    Button {
                        showSiteWebView = true
                    } label: {
                        Label("Войти через сайт", systemImage: "globe")
                    }
                    .disabled(resolvedBase == nil)
                } footer: {
                    Text("Подходит для входа через VK, Google, Shikimori, при двухфакторной защите или регистрации.")
                }
            }
            .navigationTitle("Вход")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { dismiss() }
                }
            }
            .task {
                resolvedBase = try? await app.a365.baseUrl()
            }
            .sheet(isPresented: $showSiteWebView) {
                if let base = resolvedBase {
                    SiteSignInSheet(baseUrl: base) {
                        showSiteWebView = false
                        dismiss()
                    }
                }
            }
        }
    }

    private func submitLogin() {
        guard !busy else { return }
        busy = true
        errorMessage = nil
        Task {
            do {
                _ = try await app.account.login(email: email, password: password)
                password = ""
                dismiss()
            } catch {
                errorMessage = error.userMessage
            }
            busy = false
        }
    }
}

// MARK: - In-app WebView Sign-In (VK / Google / Shikimori / Cloudflare)

private struct SiteSignInSheet: View {
    @EnvironmentObject private var app: AppContainer
    @Environment(\.dismiss) private var dismiss

    let baseUrl: String
    let onSignedIn: () -> Void

    @State private var isLoading = true
    @State private var loadError: String?
    @State private var reloadTrigger = 0
    @State private var adopted = false
    @State private var lastCookieFingerprint = ""
    @State private var checking = false

    private var loginURL: URL? {
        URL(string: "\(baseUrl)/users/login")
    }

    var body: some View {
        NavigationStack {
            ZStack {
                if let url = loginURL {
                    SiteLoginWebView(
                        url: url,
                        userAgent: app.a365.userAgent,
                        reloadTrigger: reloadTrigger,
                        isSiteHost: { app.a365.isSiteHost($0) },
                        isLoading: $isLoading,
                        loadError: $loadError,
                        onSitePageFinished: { Task { await checkWebCookies(force: false) } }
                    )
                } else {
                    Text("Неверный адрес зеркала: \(baseUrl)")
                        .font(.subheadline)
                        .foregroundColor(Nf.red)
                }

                if let loadError, !isLoading {
                    VStack(spacing: 12) {
                        Image(systemName: "wifi.slash")
                            .font(.system(size: 36))
                            .foregroundColor(Nf.amber)
                        Text("Не удалось открыть страницу входа")
                            .font(.headline)
                            .foregroundColor(Nf.text)
                        Text(loadError)
                            .font(.caption)
                            .foregroundColor(Nf.textDim)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                        Button("Повторить") {
                            self.loadError = nil
                            reloadTrigger += 1
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Nf.ink.opacity(0.95))
                }

                if adopted {
                    Color.black.opacity(0.82)
                        .ignoresSafeArea()
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 48))
                            .foregroundColor(Nf.mint)
                        Text("Вы вошли в Anime 365")
                            .font(NfType.title)
                            .foregroundColor(Nf.text)
                    }
                }
            }
            .navigationTitle(URL(string: baseUrl)?.host ?? "Anime 365")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") {
                        Task {
                            await checkWebCookies(force: true)
                            dismiss()
                        }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if isLoading || checking {
                        ProgressView()
                    }
                }
            }
            .task {
                while !Task.isCancelled && !adopted {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    await checkWebCookies(force: false)
                }
                if adopted {
                    try? await Task.sleep(nanoseconds: 900_000_000)
                    onSignedIn()
                }
            }
        }
    }

    @MainActor
    private func checkWebCookies(force: Bool) async {
        guard !adopted && !checking else { return }
        let allCookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        let siteCookies = allCookies.filter { cookie in
            let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
            return app.a365.isSiteHost(domain)
        }
        guard !siteCookies.isEmpty else { return }

        let fingerprint = siteCookies
            .sorted { $0.name < $1.name }
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: ";")
        if !force && fingerprint == lastCookieFingerprint { return }
        lastCookieFingerprint = fingerprint

        checking = true
        let profile = await app.account.adoptBrowserCookies(siteCookies)
        checking = false
        if profile != nil {
            adopted = true
        }
    }
}

private struct SiteLoginWebView: UIViewRepresentable {
    let url: URL
    let userAgent: String
    let reloadTrigger: Int
    let isSiteHost: (String?) -> Bool
    @Binding var isLoading: Bool
    @Binding var loadError: String?
    let onSitePageFinished: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = userAgent
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = UIColor(Nf.ink)
        webView.load(URLRequest(url: url))
        context.coordinator.lastReloadTrigger = reloadTrigger
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        if context.coordinator.lastReloadTrigger != reloadTrigger {
            context.coordinator.lastReloadTrigger = reloadTrigger
            uiView.load(URLRequest(url: url))
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private let parent: SiteLoginWebView
        var lastReloadTrigger = 0

        init(_ parent: SiteLoginWebView) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.isLoading = true
            parent.loadError = nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.isLoading = false
            if parent.isSiteHost(webView.url?.host) {
                parent.onSitePageFinished()
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
            if (error as NSError).code != NSURLErrorCancelled {
                parent.loadError = error.localizedDescription
            }
        }

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
    }
}
