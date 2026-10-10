// Native iPhone shell for the Karaoke web app. Paste this over the KaraokeApp.swift
// that Xcode generates (and delete ContentView.swift). See README.md.
import SwiftUI
import WebKit
import AuthenticationServices
import CryptoKit

// 1. Where you hosted the web app (GitHub Pages etc.)
let appURL = URL(string: "https://officialfshot-web.github.io/karaoke-app/")!
// 2. Google Cloud OAuth client of type "iOS" (optional — only needed for Sign in)
let iosClientID = "PASTE-IOS-CLIENT-ID.apps.googleusercontent.com"

@main
struct KaraokeApp: App {
    var body: some Scene {
        WindowGroup {
            WebView()
                .ignoresSafeArea()
                .background(Color(red: 11/255, green: 7/255, blue: 20/255))
                .preferredColorScheme(.dark)
        }
    }
}

struct WebView: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.userContentController.add(context.coordinator, name: "signIn")
        cfg.userContentController.addScriptMessageHandler(context.coordinator, contentWorld: .page, name: "http")
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.isOpaque = true
        wv.backgroundColor = UIColor(red: 11/255, green: 7/255, blue: 20/255, alpha: 1)
        wv.scrollView.bounces = false
        wv.scrollView.contentInsetAdjustmentBehavior = .never
        wv.uiDelegate = context.coordinator
        context.coordinator.webView = wv
        wv.load(URLRequest(url: appURL))
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKUIDelegate, WKScriptMessageHandler, WKScriptMessageHandlerWithReply, ASWebAuthenticationPresentationContextProviding {
        weak var webView: WKWebView?
        var session: ASWebAuthenticationSession?

        // Google blocks sign-in inside web views, so use the system sign-in sheet (OAuth PKCE).
        func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
            let scheme = "com.googleusercontent.apps." + iosClientID.replacingOccurrences(of: ".apps.googleusercontent.com", with: "")
            let redirect = scheme + ":/oauth2redirect"
            let verifier = Self.b64(Data((0..<32).map { _ in UInt8.random(in: 0...255) }))
            let challenge = Self.b64(Data(SHA256.hash(data: Data(verifier.utf8))))
            var c = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
            c.queryItems = [
                .init(name: "client_id", value: iosClientID),
                .init(name: "redirect_uri", value: redirect),
                .init(name: "response_type", value: "code"),
                .init(name: "scope", value: "https://www.googleapis.com/auth/youtube.readonly"),
                .init(name: "code_challenge", value: challenge),
                .init(name: "code_challenge_method", value: "S256"),
                .init(name: "prompt", value: "select_account"),
            ]
            session = ASWebAuthenticationSession(url: c.url!, callbackURLScheme: scheme) { [weak self] url, _ in
                guard let url, let code = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "code" })?.value else { return }
                self?.exchange(code: code, verifier: verifier, redirect: redirect)
            }
            session?.presentationContextProvider = self
            session?.start()
        }

        // Lets the page reach YouTube Music (album tracks + their lyrics) and NetEase (word-by-word
        // timings). Browsers block these; only these two hosts are allowed.
        func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage,
                                   replyHandler: @escaping (Any?, String?) -> Void) {
            guard let d = message.body as? [String: Any], let s = d["url"] as? String,
                  let url = URL(string: s), ["music.youtube.com", "music.163.com"].contains(url.host ?? "") else { return replyHandler(nil, "blocked") }
            var req = URLRequest(url: url)
            if let body = d["body"] as? String {
                req.httpMethod = "POST"
                req.httpBody = body.data(using: .utf8)
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            if url.host == "music.youtube.com" { req.setValue("https://music.youtube.com", forHTTPHeaderField: "Origin") }
            for (k, v) in d["headers"] as? [String: String] ?? [:] { req.setValue(v, forHTTPHeaderField: k) }
            URLSession.shared.dataTask(with: req) { data, _, err in
                let text = data.map { String(decoding: $0, as: UTF8.self) }
                DispatchQueue.main.async {
                    if let text { replyHandler(text, nil) } else { replyHandler(nil, err?.localizedDescription ?? "failed") }
                }
            }.resume()
        }

        func exchange(code: String, verifier: String, redirect: String) {
            var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            var body = URLComponents()
            body.queryItems = [
                .init(name: "code", value: code), .init(name: "client_id", value: iosClientID),
                .init(name: "redirect_uri", value: redirect), .init(name: "code_verifier", value: verifier),
                .init(name: "grant_type", value: "authorization_code"),
            ]
            req.httpBody = body.percentEncodedQuery?.data(using: .utf8)
            URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
                guard let data, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tok = j["access_token"] as? String else { return }
                let secs = j["expires_in"] as? Int ?? 3600
                DispatchQueue.main.async {
                    self?.webView?.evaluateJavaScript("window.nativeToken(\"\(tok)\", \(secs))")
                }
            }.resume()
        }

        static func b64(_ d: Data) -> String {
            d.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }

        func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
            webView?.window ?? ASPresentationAnchor()
        }

        // Lets the page's mic-reactive glow (getUserMedia) work — without this iOS silently denies it.
        @available(iOS 15.0, *)
        func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                     initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                     decisionHandler: @escaping (WKPermissionDecision) -> Void) {
            decisionHandler(.grant)
        }

        // window.prompt() support (the 🔍 "find other lyrics" button)
        func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
            let a = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
            a.addTextField { $0.text = defaultText }
            a.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(nil) })
            a.addAction(UIAlertAction(title: "Search", style: .default) { _ in completionHandler(a.textFields?.first?.text) })
            webView.window?.rootViewController?.present(a, animated: true)
        }
    }
}
