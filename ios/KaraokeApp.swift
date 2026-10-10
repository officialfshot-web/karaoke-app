// Native iPhone shell for the Karaoke web app. Paste this over the KaraokeApp.swift
// that Xcode generates (and delete ContentView.swift). See README.md.
// Needs Info → "Privacy - Microphone Usage Description" in the Xcode target (for the voice studio).
import SwiftUI
import WebKit
import AuthenticationServices
import CryptoKit
import AVFoundation
import Accelerate

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
        cfg.userContentController.addScriptMessageHandler(context.coordinator, contentWorld: .page, name: "voice")
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.isOpaque = true
        wv.backgroundColor = UIColor(red: 11/255, green: 7/255, blue: 20/255, alpha: 1)
        wv.scrollView.bounces = false
        wv.scrollView.contentInsetAdjustmentBehavior = .never
        wv.uiDelegate = context.coordinator
        context.coordinator.webView = wv
        VoiceEngine.shared.onFrame = { [weak wv] rms, hz in
            wv?.evaluateJavaScript("window.nativeVoice&&window.nativeVoice(\(rms),\(hz))")
        }
        VoiceEngine.shared.onRoute = { [weak wv] info in
            guard let data = try? JSONSerialization.data(withJSONObject: info), let json = String(data: data, encoding: .utf8) else { return }
            wv?.evaluateJavaScript("window.nativeVoiceRoute&&window.nativeVoiceRoute(\(json))")
        }
        wv.load(URLRequest(url: appURL))
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    @MainActor
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
                Task { @MainActor in self?.exchange(code: code, verifier: verifier, redirect: redirect) }
            }
            session?.presentationContextProvider = self
            session?.start()
        }

        func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage,
                                   replyHandler: @escaping (Any?, String?) -> Void) {
            if message.name == "voice" { return handleVoice(message.body, replyHandler) }
            // Lets the page reach YouTube Music (album tracks + their lyrics) and NetEase (word-by-word
            // timings). Browsers block these; only these two hosts are allowed.
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
            let request = req
            Task { @MainActor in
                do {
                    let (data, _) = try await URLSession.shared.data(for: request)
                    replyHandler(String(decoding: data, as: UTF8.self), nil)
                } catch { replyHandler(nil, error.localizedDescription) }
            }
        }

        // The page's mic button / voice studio sheet talk to the native vocal chain through this.
        func handleVoice(_ body: Any, _ reply: @escaping (Any?, String?) -> Void) {
            guard let d = body as? [String: Any], let cmd = d["cmd"] as? String else { return reply(nil, "bad message") }
            Task { @MainActor in
                let v = VoiceEngine.shared
                v.configure(d)
                switch cmd {
                case "start": reply(await v.start(), nil)
                case "stop": v.stop(); reply(["ok": true], nil)
                case "reset": v.resetSafety(); reply(["ok": true, "tier": v.tier], nil)
                case "recStart": reply(v.recStart(videoTime: d["videoTime"] as? Double ?? 0, append: d["append"] as? Bool ?? false), nil)
                case "recPause": v.recPause(); reply(["ok": true], nil)
                case "recStop": reply(v.recStop(), nil)
                case "playTake": reply(v.playTake(videoTime: d["videoTime"] as? Double ?? 0), nil)
                case "stopTake": v.stopTake(); reply(["ok": true], nil)
                default: reply(["ok": true], nil)
                }
            }
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
            let request = req
            Task { @MainActor [weak self] in
                guard let (data, _) = try? await URLSession.shared.data(for: request),
                      let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tok = j["access_token"] as? String else { return }
                let secs = j["expires_in"] as? Int ?? 3600
                self?.webView?.evaluateJavaScript("window.nativeToken(\"\(tok)\", \(secs))")
            }
        }

        static func b64(_ d: Data) -> String {
            d.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }

        nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
            MainActor.assumeIsolated { webView?.window ?? ASPresentationAnchor() }   // always asked on the main thread
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

// MARK: - Voice studio

/// Live vocal chain, built from Apple's pro audio units:
/// mic → preset EQ (low cut, de-mud, presence, air) → your EQ → compressor → [dry + doubler] → echo → reverb → limiter → your ears.
/// Full-quality music audio session: no voice processing ("phone call" mode) anywhere.
/// It also measures loudness and pitch (YIN) for the note lane and the singing coach.
///
/// Crash safety: audio-graph mistakes on iOS kill the app instantly (they can't be caught), so the engine
/// remembers that it was starting. If the app died mid-start, the next start drops to a simpler "safe" chain,
/// and after that to "off", instead of crashing again. `resetSafety` goes back to the full studio.
@MainActor
final class VoiceEngine {
    static let shared = VoiceEngine()

    var onFrame: ((Float, Float) -> Void)?          // (loudness, pitch in Hz or -1)
    var onRoute: (([String: Any]) -> Void)?

    static let presets: [String: VoicePreset] = [
        "clean":     VoicePreset(lowCut: 80, mud: -1, mudHz: 300, presence: 1, presenceHz: 4000, air: 1, threshold: -16, headroom: 8, makeup: 2,
                                 double: 0, room: .mediumRoom, roomWet: 6, echoTime: 0.1, echoFeedback: 0, echoWet: 0),
        "studio":    VoicePreset(lowCut: 90, mud: -2.5, mudHz: 320, presence: 3, presenceHz: 4500, air: 3, threshold: -22, headroom: 6, makeup: 5,
                                 double: 0, room: .plate, roomWet: 14, echoTime: 0.12, echoFeedback: 0, echoWet: 0),
        "pop":       VoicePreset(lowCut: 100, mud: -3, mudHz: 300, presence: 4, presenceHz: 3200, air: 4, threshold: -26, headroom: 4, makeup: 7,
                                 double: 0.35, room: .plate, roomWet: 20, echoTime: 0.18, echoFeedback: 15, echoWet: 10),
        "rnb":       VoicePreset(lowCut: 80, mud: 1, mudHz: 200, presence: 2, presenceHz: 5000, air: 4, threshold: -28, headroom: 5, makeup: 7,
                                 double: 0.25, room: .mediumHall, roomWet: 22, echoTime: 0.27, echoFeedback: 20, echoWet: 10),
        "arena":     VoicePreset(lowCut: 90, mud: -2, mudHz: 250, presence: 2, presenceHz: 3500, air: 2, threshold: -20, headroom: 6, makeup: 5,
                                 double: 0.15, room: .largeHall2, roomWet: 32, echoTime: 0.32, echoFeedback: 25, echoWet: 14),
        "vintage":   VoicePreset(lowCut: 120, mud: 0, mudHz: 300, presence: 2, presenceHz: 2500, air: -2, threshold: -18, headroom: 7, makeup: 4,
                                 double: 0, room: .plate, roomWet: 26, echoTime: 0.11, echoFeedback: 0, echoWet: 18),
        "cathedral": VoicePreset(lowCut: 90, mud: -2, mudHz: 300, presence: 2, presenceHz: 4000, air: 2, threshold: -20, headroom: 6, makeup: 5,
                                 double: 0, room: .cathedral, roomWet: 38, echoTime: 0.2, echoFeedback: 0, echoWet: 0),
    ]

    // settings from the page
    private var presetName = "studio"
    private var monitor: Float = 0.9, reverbAmount: Float = 1, echoAmount: Float = 1
    private var userEQ: [Float] = [0, 0, 0, 0, 0]          // bass, body, mid, presence, air (dB)

    private var chain: VoiceChain?
    private(set) var running = false

    // crash memory
    private let defaults = UserDefaults.standard
    private(set) var tier: Int                // 0 = full studio, 1 = safe chain, 2 = off
    private var crashedLastTime = false

    private init() {
        tier = defaults.integer(forKey: "voice.tier")
        if defaults.bool(forKey: "voice.starting") {          // we died while starting the mic last time
            tier = min(2, tier + 1); crashedLastTime = true
            defaults.set(tier, forKey: "voice.tier"); defaults.set(false, forKey: "voice.starting")
        }
        let nc = NotificationCenter.default
        nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in VoiceEngine.shared.applyRoute() }
        }
        nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { _ in
            Task { @MainActor in VoiceEngine.shared.rebuild() }   // headphones in/out can change the sample rate
        }
        nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { n in
            // a call, Siri, another app…: when it's over, bring the mic back
            let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) == .ended else { return }
            Task { @MainActor in
                try? AVAudioSession.sharedInstance().setActive(true)
                VoiceEngine.shared.rebuild()
            }
        }
    }

    func configure(_ d: [String: Any]) {
        if let p = d["preset"] as? String, Self.presets[p] != nil { presetName = p }
        if let m = d["monitor"] as? Double { monitor = Float(max(0, min(1.5, m))) }
        if let r = d["reverb"] as? Double { reverbAmount = Float(max(0, min(2, r))) }
        if let e = d["echo"] as? Double { echoAmount = Float(max(0, min(2, e))) }
        if let g = d["eq"] as? [Double], g.count == 5 { userEQ = g.map { Float(max(-12, min(12, $0))) } }
        applyPreset(); applyRoute()
    }

    func resetSafety() {
        tier = 0; crashedLastTime = false
        defaults.set(0, forKey: "voice.tier"); defaults.set(false, forKey: "voice.starting")
    }

    /// Every check that can fail is done up front and turned into a message, so nothing here crashes the app.
    func start() async -> [String: Any] {
        func fail(_ msg: String) -> [String: Any] { ["ok": false, "error": msg, "tier": tier] }
        guard Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil else {
            return fail("This build is missing the microphone permission. In Xcode: Karaoke target → Info → + → “Privacy - Microphone Usage Description”, then press ▶.")
        }
        guard tier < 2 else {
            return fail("Live voice was turned off because it crashed twice. Tap “Reset voice engine” in Voice studio to try again.")
        }
        let session = AVAudioSession.sharedInstance()
        if session.recordPermission == .denied {
            return fail("Microphone is off for Karaoke. Turn it on in Settings → Karaoke → Microphone.")
        }
        guard await Self.askMicPermission() else {
            return fail("Microphone is off for Karaoke. Turn it on in Settings → Karaoke → Microphone.")
        }
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP, .mixWithOthers])
            try? session.setPreferredSampleRate(48000)
            try? session.setPreferredIOBufferDuration(0.005)   // ~5 ms buffers: low enough to hear yourself without echo
            try session.setActive(true)
        } catch { return fail("Couldn’t open the audio system: \(error.localizedDescription)") }
        guard session.isInputAvailable else { return fail("No microphone is available right now.") }

        do { try startChain() } catch {
            return fail("Couldn’t start the mic: \(error.localizedDescription)")
        }
        running = true
        var r: [String: Any] = ["ok": true, "route": routeSummary, "tier": tier]
        if crashedLastTime { r["notice"] = "The voice studio crashed last time, so it’s running in safe mode (fewer effects)." }
        crashedLastTime = false
        return r
    }

    private static func askMicPermission() async -> Bool {
        if #available(iOS 17.0, *) { return await AVAudioApplication.requestRecordPermission() }
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            AVAudioSession.sharedInstance().requestRecordPermission { @Sendable granted in cont.resume(returning: granted) }
        }
    }

    // MARK: Record & listen back
    // Your processed voice is written to a file while you sing. To play it back in time with the song we need
    // to know where each sample sits on the video's clock: you sing to what you *hear* (output delay) and the mic
    // adds its own (input delay). iOS reports both, so the take is lined up automatically, with no sync slider.
    private var take: (url: URL, start: Double, latency: Double)?
    private let takePlayer = TakePlayer()

    func recStart(videoTime: Double, append: Bool) -> [String: Any] {
        guard let c = chain else { return ["ok": false, "error": "Mic isn’t on"] }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("take.caf")
        do {
            if append, take != nil, c.isRecordingFileOpen {
                c.resumeRecording()
            } else {
                try c.startRecording(url: url)
                let s = AVAudioSession.sharedInstance()
                take = (url, videoTime, s.inputLatency + s.outputLatency + s.ioBufferDuration)
            }
            return ["ok": true]
        } catch { return ["ok": false, "error": error.localizedDescription] }
    }
    func recPause() { chain?.pauseRecording() }
    func recStop() -> [String: Any] {
        let secs = chain?.finishRecording() ?? 0
        guard let t = take, secs > 0 else { return ["ok": false] }
        return ["ok": true, "start": t.start, "duration": secs, "latency": t.latency]
    }
    func playTake(videoTime: Double) -> [String: Any] {
        guard let t = take else { return ["ok": false, "error": "No take recorded yet"] }
        do {
            try takePlayer.play(url: t.url, from: videoTime - t.start + t.latency)
            return ["ok": true]
        } catch { return ["ok": false, "error": error.localizedDescription] }
    }
    func stopTake() { takePlayer.stop() }

    func stop() {
        running = false
        _ = chain?.finishRecording()
        chain?.engine.stop(); chain = nil
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
    }

    private func rebuild() {
        guard running else { return }
        chain?.engine.stop(); chain = nil
        do { try startChain() } catch {
            running = false
            onRoute?(["running": false, "error": "The mic stopped: \(error.localizedDescription). Tap the mic to restart."])
        }
    }

    private func startChain() throws {
        // mark "starting" on disk before touching the audio graph; cleared once it has run for a few seconds
        defaults.set(true, forKey: "voice.starting"); defaults.synchronize()
        let c = try VoiceChain(safe: tier >= 1) { rms, hz in
            Task { @MainActor in VoiceEngine.shared.onFrame?(rms, hz) }
        }
        chain = c
        applyPreset(); applyRoute()
        try c.engine.start()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if VoiceEngine.shared.running { UserDefaults.standard.set(false, forKey: "voice.starting") }
        }
    }

    private func applyPreset() {
        guard let c = chain, let p = Self.presets[presetName] else { return }
        c.apply(p, name: presetName, reverbAmount: reverbAmount, echoAmount: echoAmount)
        c.applyUserEQ(userEQ)
    }

    private var outputs: [AVAudioSession.Port] { AVAudioSession.sharedInstance().currentRoute.outputs.map { $0.portType } }
    var routeSummary: String {
        let o = outputs
        if o.contains(where: { [.headphones, .usbAudio, .lineOut].contains($0) }) { return "🎧 Hearing yourself live" }
        if o.contains(where: { [.bluetoothA2DP, .bluetoothLE, .bluetoothHFP].contains($0) }) { return "🎧 Hearing yourself (Bluetooth adds a little delay)" }
        if o.contains(.carAudio) { return "🚗 Hearing yourself in the car. Lower “Your voice” if it rings" }
        return "🔊 Hearing yourself on the speaker. Lower “Your voice” if it rings"
    }

    // Always play your voice back. Through open speakers it starts a bit quieter so it doesn't ring.
    private func applyRoute() {
        let outs = outputs
        let wired = outs.contains { [.headphones, .usbAudio, .lineOut].contains($0) }
        let bluetooth = outs.contains { [.bluetoothA2DP, .bluetoothLE, .bluetoothHFP].contains($0) }
        let car = outs.contains(.carAudio)
        chain?.out.outputVolume = (wired || bluetooth) ? monitor : monitor * 0.6
        let s = AVAudioSession.sharedInstance()
        let delayMs = Int(((s.inputLatency + s.outputLatency + 2 * s.ioBufferDuration) * 1000).rounded())
        onRoute?(["wired": wired, "bluetooth": bluetooth, "car": car, "hearing": running, "running": running,
                  "summary": routeSummary, "tier": tier, "delayMs": delayMs])
    }
}

nonisolated struct VoicePreset: Sendable {
    var lowCut: Float, mud: Float, mudHz: Float, presence: Float, presenceHz: Float, air: Float
    var threshold: Float, headroom: Float, makeup: Float
    var double: Float
    var room: AVAudioUnitReverbPreset, roomWet: Float
    var echoTime: Double, echoFeedback: Float, echoWet: Float
}

/// One engine + its nodes. Rebuilt from scratch whenever the audio hardware changes.
/// Not tied to the main thread: parts of it run on the real-time audio thread.
nonisolated final class VoiceChain: @unchecked Sendable {
    let engine = AVAudioEngine()
    let inMix = AVAudioMixerNode()
    let eq = AVAudioUnitEQ(numberOfBands: 4)
    let userEQ = AVAudioUnitEQ(numberOfBands: 5)
    let reverb = AVAudioUnitReverb()          // safe mode only
    let out = AVAudioMixerNode()
    let safe: Bool
    private var studio: AVAudioUnitEffect?     // full mode: our Studio FX audio unit
    private var sink: AVAudioSinkNode?

    // pitch analysis: keep the last 4096 mic samples, analyse 2048 of them every 1024 new samples (~21 ms)
    private var ring = [Float](repeating: 0, count: 4096)
    private var ringPos = 0, fresh = 0
    private let analysisQ = DispatchQueue(label: "karaoke.voice.analysis")
    private var sampleRate: Double = 48000
    private let report: @Sendable (Float, Float) -> Void

    /// Full: mic → tone EQ → your EQ → Studio FX (compressor, de-esser, warmth, doubler, echo, reverb, limiter) → you.
    /// Safe: mic → tone EQ → your EQ → Apple reverb → you, with a plain tap for pitch (fallback after a crash).
    init(safe: Bool, report: @escaping @Sendable (Float, Float) -> Void) throws {
        self.safe = safe
        self.report = report
        let input = engine.inputNode
        let inFmt = input.outputFormat(forBus: 0)
        guard inFmt.sampleRate > 0, inFmt.channelCount > 0,
              let mono = AVAudioFormat(standardFormatWithSampleRate: inFmt.sampleRate, channels: 1),
              let stereo = AVAudioFormat(standardFormatWithSampleRate: inFmt.sampleRate, channels: 2) else {
            throw NSError(domain: "Karaoke", code: 1, userInfo: [NSLocalizedDescriptionKey: "no usable microphone input"])
        }
        sampleRate = inFmt.sampleRate

        if safe {
            for n in [inMix, eq, userEQ, reverb, out] as [AVAudioNode] { engine.attach(n) }
            engine.connect(input, to: inMix, format: inFmt)
            engine.connect(inMix, to: eq, format: mono)
            engine.connect(eq, to: userEQ, format: mono)
            engine.connect(userEQ, to: reverb, format: mono)
            engine.connect(reverb, to: out, format: mono)
            engine.connect(out, to: engine.mainMixerNode, format: mono)
            inMix.installTap(onBus: 0, bufferSize: 2048, format: mono) { [weak self] buf, _ in
                guard let self, let p = buf.floatChannelData?[0] else { return }
                self.collect(p, Int(buf.frameLength))
            }
        } else {
            StudioFXUnit.register()
            let fx = AVAudioUnitEffect(audioComponentDescription: StudioFXUnit.desc)
            studio = fx
            let sink = AVAudioSinkNode { [weak self] _, frames, abl -> OSStatus in
                let bufs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: abl))
                if let p = bufs.first?.mData?.assumingMemoryBound(to: Float.self) { self?.collect(p, Int(frames)) }
                return noErr
            }
            self.sink = sink
            for n in [inMix, eq, userEQ, fx, out, sink] as [AVAudioNode] { engine.attach(n) }
            engine.connect(input, to: [AVAudioConnectionPoint(node: inMix, bus: 0), AVAudioConnectionPoint(node: sink, bus: 0)],
                           fromBus: 0, format: inFmt)
            engine.connect(inMix, to: eq, format: stereo)       // the mixer spreads the mono mic to both sides
            engine.connect(eq, to: userEQ, format: stereo)
            engine.connect(userEQ, to: fx, format: stereo)
            engine.connect(fx, to: out, format: stereo)
            engine.connect(out, to: engine.mainMixerNode, format: stereo)
        }
        engine.prepare()
    }

    func apply(_ p: VoicePreset, name: String, reverbAmount: Float, echoAmount: Float) {
        let b = eq.bands
        b[0].filterType = .highPass; b[0].frequency = p.lowCut; b[0].bypass = false
        b[1].filterType = .parametric; b[1].frequency = p.mudHz; b[1].bandwidth = 1.2; b[1].gain = p.mud; b[1].bypass = false
        b[2].filterType = .parametric; b[2].frequency = p.presenceHz; b[2].bandwidth = 1.5; b[2].gain = p.presence; b[2].bypass = false
        b[3].filterType = .highShelf; b[3].frequency = 11000; b[3].gain = p.air; b[3].bypass = false
        if safe {
            eq.globalGain = p.makeup * 0.5
            reverb.loadFactoryPreset(p.room)
            reverb.wetDryMix = min(80, p.roomWet * reverbAmount)
        } else {
            eq.globalGain = 0     // Studio FX does its own level management
            (studio?.auAudioUnit as? StudioFXUnit)?.kernel.setPreset(name, reverbAmount: reverbAmount, echoAmount: echoAmount)
        }
    }

    // Your EQ, on top of the preset: Bass 100 Hz · Body 250 Hz · Mid 1 kHz · Presence 3.5 kHz · Air 10 kHz
    func applyUserEQ(_ g: [Float]) {
        let spec: [(AVAudioUnitEQFilterType, Float)] = [(.lowShelf, 100), (.parametric, 250), (.parametric, 1000), (.parametric, 3500), (.highShelf, 10000)]
        for (i, b) in userEQ.bands.enumerated() where i < spec.count {
            b.filterType = spec[i].0; b.frequency = spec[i].1; b.bandwidth = 1.0
            b.gain = i < g.count ? g[i] : 0; b.bypass = false
        }
    }

    // recording: a tap on the final output (what you hear), written straight to disk
    private var recFile: AVAudioFile?
    private var tapOn = false
    var isRecordingFileOpen: Bool { recFile != nil }
    func startRecording(url: URL) throws {
        _ = finishRecording()
        try? FileManager.default.removeItem(at: url)
        let fmt = out.outputFormat(forBus: 0)
        recFile = try AVAudioFile(forWriting: url, settings: fmt.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        resumeRecording()
    }
    func resumeRecording() {
        guard recFile != nil, !tapOn else { return }
        out.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buf, _ in try? self?.recFile?.write(from: buf) }
        tapOn = true
    }
    func pauseRecording() {
        if tapOn { out.removeTap(onBus: 0); tapOn = false }
    }
    /// Closes the file; returns its length in seconds.
    func finishRecording() -> Double {
        pauseRecording()
        guard let f = recFile else { return 0 }
        let secs = Double(f.length) / f.processingFormat.sampleRate
        recFile = nil
        return secs
    }

    private func collect(_ p: UnsafePointer<Float>, _ n: Int) {
        for i in 0..<n { ring[ringPos] = p[i]; ringPos = (ringPos + 1) & 4095 }
        fresh += n
        guard fresh >= 1024 else { return }
        fresh = 0
        var snap = [Float](repeating: 0, count: 2048)
        let start = (ringPos - 2048 + 4096) & 4095
        for i in 0..<2048 { snap[i] = ring[(start + i) & 4095] }
        let sr = sampleRate, report = report
        analysisQ.async {
            var ms: Float = 0
            vDSP_measqv(snap, 1, &ms, vDSP_Length(snap.count))
            let rms = sqrt(ms)
            report(rms, rms > 0.012 ? VoiceChain.yin(snap, Float(sr)) : -1)
        }
    }

    /// YIN pitch detection: steadier than plain autocorrelation and much less prone to octave jumps.
    static func yin(_ x: [Float], _ sr: Float) -> Float {
        let w = 1024
        let minLag = max(2, Int(sr / 1100)), maxLag = min(x.count - w - 2, Int(sr / 65))
        guard maxLag > minLag + 2 else { return -1 }
        var d = [Float](repeating: 0, count: maxLag + 2)
        var diff = [Float](repeating: 0, count: w)
        x.withUnsafeBufferPointer { xp in
            guard let base = xp.baseAddress else { return }
            for tau in 1...(maxLag + 1) {
                vDSP_vsub(base + tau, 1, base, 1, &diff, 1, vDSP_Length(w))
                var s: Float = 0
                vDSP_svesq(diff, 1, &s, vDSP_Length(w))
                d[tau] = s
            }
        }
        var run: Float = 0
        var cm = [Float](repeating: 1, count: maxLag + 2)
        for tau in 1...(maxLag + 1) { run += d[tau]; cm[tau] = run > 0 ? d[tau] * Float(tau) / run : 1 }
        var tau = minLag
        while tau <= maxLag {
            if cm[tau] < 0.15 {
                while tau + 1 <= maxLag && cm[tau + 1] < cm[tau] { tau += 1 }
                let a = cm[tau - 1], b = cm[tau], c = cm[tau + 1], den = a + c - 2 * b
                let t = den != 0 ? Float(tau) + (a - c) / (2 * den) : Float(tau)
                return sr / t
            }
            tau += 1
        }
        return -1
    }
}

/// Plays a recorded take back on its own little engine, starting at a given point in the file.
@MainActor
final class TakePlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var attached = false

    func play(url: URL, from seconds: Double) throws {
        let file = try AVAudioFile(forReading: url)
        let s = AVAudioSession.sharedInstance()
        try s.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try s.setActive(true)
        if !attached { engine.attach(node); attached = true }
        node.stop()
        engine.disconnectNodeOutput(node)
        engine.connect(node, to: engine.mainMixerNode, format: file.processingFormat)
        if !engine.isRunning { try engine.start() }
        let start = AVAudioFramePosition(max(0, seconds) * file.processingFormat.sampleRate)
        guard start < file.length else { return }
        node.scheduleSegment(file, startingFrame: start, frameCount: AVAudioFrameCount(file.length - start), at: nil)
        node.play()
    }

    func stop() { node.stop() }
}

// MARK: - Studio FX engine (port of dsp/studio.mjs; `node dsp/test.mjs` checks it)

nonisolated struct StudioParams: Sendable {
    var deess: Float, thr: Float, ratio: Float, warm: Float, dbl: Float
    var dlyTime: Float, dlyFb: Float, dlyMix: Float
    var rvSize: Float, rvDecay: Float, rvDamp: Float, rvPre: Float, rvMix: Float
    var width: Float

    static let presets: [String: StudioParams] = [
        "clean":     StudioParams(deess: 4, thr: -18, ratio: 2.5, warm: 0.10, dbl: 0,    dlyTime: 0,    dlyFb: 0,    dlyMix: 0,    rvSize: 0.55, rvDecay: 0.9, rvDamp: 0.55, rvPre: 8,  rvMix: 0.08, width: 0.6),
        "studio":    StudioParams(deess: 6, thr: -22, ratio: 3.5, warm: 0.25, dbl: 0,    dlyTime: 0,    dlyFb: 0,    dlyMix: 0,    rvSize: 0.75, rvDecay: 1.6, rvDamp: 0.5,  rvPre: 22, rvMix: 0.16, width: 0.8),
        "pop":       StudioParams(deess: 7, thr: -26, ratio: 4,   warm: 0.30, dbl: 0.30, dlyTime: 0.25, dlyFb: 0.28, dlyMix: 0.12, rvSize: 0.8,  rvDecay: 1.9, rvDamp: 0.45, rvPre: 28, rvMix: 0.18, width: 1),
        "rnb":       StudioParams(deess: 6, thr: -26, ratio: 3.5, warm: 0.35, dbl: 0.20, dlyTime: 0.36, dlyFb: 0.32, dlyMix: 0.10, rvSize: 0.9,  rvDecay: 2.6, rvDamp: 0.55, rvPre: 35, rvMix: 0.22, width: 1),
        "arena":     StudioParams(deess: 5, thr: -20, ratio: 3,   warm: 0.20, dbl: 0.12, dlyTime: 0.42, dlyFb: 0.40, dlyMix: 0.16, rvSize: 1.0,  rvDecay: 3.4, rvDamp: 0.5,  rvPre: 45, rvMix: 0.30, width: 1),
        "vintage":   StudioParams(deess: 4, thr: -18, ratio: 3,   warm: 0.55, dbl: 0,    dlyTime: 0.11, dlyFb: 0.05, dlyMix: 0.20, rvSize: 0.7,  rvDecay: 1.4, rvDamp: 0.75, rvPre: 12, rvMix: 0.18, width: 0.5),
        "cathedral": StudioParams(deess: 5, thr: -20, ratio: 3,   warm: 0.15, dbl: 0,    dlyTime: 0,    dlyFb: 0,    dlyMix: 0,    rvSize: 1.0,  rvDecay: 5.5, rvDamp: 0.6,  rvPre: 60, rvMix: 0.36, width: 1),
    ]
}

// constants live in a nonisolated namespace so real-time code never touches main-actor state
nonisolated enum DSP {
    static let tau: Float = 2 * .pi
    @inline(__always) static func db(_ d: Float) -> Float { powf(10, d / 20) }
}

nonisolated struct Biquad {
    enum Kind { case lp, hp, bp }
    var b0: Float = 1, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0, z1: Float = 0, z2: Float = 0
    mutating func set(_ k: Kind, fs: Float, f: Float, q: Float) {
        let w = DSP.tau * min(f, fs * 0.45) / fs, c = cosf(w), s = sinf(w), al = s / (2 * q)
        var n0: Float, n1: Float, n2: Float
        switch k {
        case .lp: n0 = (1 - c) / 2; n1 = 1 - c; n2 = n0
        case .hp: n0 = (1 + c) / 2; n1 = -(1 + c); n2 = n0
        case .bp: n0 = al; n1 = 0; n2 = -al
        }
        let a0 = 1 + al
        b0 = n0 / a0; b1 = n1 / a0; b2 = n2 / a0; a1 = (-2 * c) / a0; a2 = (1 - al) / a0
    }
    @inline(__always) mutating func run(_ x: Float) -> Float {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }
}

nonisolated struct OnePole {
    var a: Float = 1, y: Float = 0
    mutating func setLP(fs: Float, f: Float) { a = 1 - expf(-DSP.tau * f / fs) }
    @inline(__always) mutating func lp(_ x: Float) -> Float { y += a * (x - y); return y }
    @inline(__always) mutating func hp(_ x: Float) -> Float { x - lp(x) }
}

/// Power-of-two ring buffer with fractional (linear) reads.
nonisolated final class DelayLine {
    let buf: UnsafeMutablePointer<Float>
    let mask: Int
    var w = 0
    init(max: Int) {
        var n = 1; while n < max + 2 { n <<= 1 }
        buf = .allocate(capacity: n); buf.initialize(repeating: 0, count: n); mask = n - 1
    }
    deinit { buf.deallocate() }
    @inline(__always) func write(_ x: Float) { buf[w] = x; w = (w + 1) & mask }
    @inline(__always) func read(_ d: Float) -> Float {
        let i = Int(d), f = d - Float(i)
        let a = buf[(w - i) & mask], b = buf[(w - i - 1) & mask]
        return a + (b - a) * f
    }
}

nonisolated final class Allpass {
    let d: DelayLine, len: Float, g: Float
    init(_ len: Int, _ g: Float) { d = DelayLine(max: len); self.len = Float(len); self.g = g }
    @inline(__always) func run(_ x: Float) -> Float {
        let v = d.read(len), u = x + g * v
        d.write(u)
        return v - g * u
    }
}

nonisolated final class StudioKernel: @unchecked Sendable {
    private var fs: Float = 48000
    // params arrive from the main thread; the audio thread picks them up at the start of the next buffer
    private var incoming = StudioParams.presets["studio"]!
    private var incomingAmounts: (Float, Float) = (1, 1)
    private var incomingGen = 0, seenGen = -1

    private var p = StudioParams.presets["studio"]!
    private var reverbAmt: Float = 1, echoAmt: Float = 1
    private var split = Biquad(), sib = Biquad()
    private var deEnv: Float = 0, fullEnv: Float = 0
    private var rms: Float = 0, gr: Float = 0, rmsA: Float = 0, attA: Float = 0, relA: Float = 0, env: Float = 0, envA: Float = 0, makeup: Float = 1
    private var dblLine = DelayLine(max: 2048), lfo1: Float = 0, lfo2: Float = 0.37, dblHP = OnePole()
    private var dL = DelayLine(max: 2), dR = DelayLine(max: 2)
    private var fbHPL = OnePole(), fbLPL = OnePole(), fbHPR = OnePole(), fbLPR = OnePole()
    private var pre = DelayLine(max: 2), rvHP = OnePole(), rvLP = OnePole()
    private var diff: [Allpass] = []
    private var baseLens: [Float] = [], lens: [Float] = Array(repeating: 1000, count: 8), gains: [Float] = Array(repeating: 0, count: 8)
    private var lines: [DelayLine] = []
    private var damp: [Float] = Array(repeating: 0, count: 8), dampA: Float = 0.5
    private var modPh: Float = 0
    private var mixDbl: Float = 0, mixDly: Float = 0, mixRv: Float = 0

    // scratch for hosts that hand us empty buffers
    let scratchL = UnsafeMutablePointer<Float>.allocate(capacity: 8192)
    let scratchR = UnsafeMutablePointer<Float>.allocate(capacity: 8192)
    deinit { scratchL.deallocate(); scratchR.deallocate() }

    /// Main thread: request a preset + slider amounts.
    func setPreset(_ name: String, reverbAmount: Float, echoAmount: Float) {
        incoming = StudioParams.presets[name] ?? StudioParams.presets["studio"]!
        incomingAmounts = (reverbAmount, echoAmount)
        incomingGen &+= 1
    }

    /// Not real-time: (re)build every buffer for this sample rate.
    func prepare(sampleRate: Double) {
        fs = Float(sampleRate)
        let ms = { (x: Float) in Int(x * self.fs / 1000) }
        split.set(.lp, fs: fs, f: 4800, q: 0.5)
        sib.set(.bp, fs: fs, f: 7000, q: 1.2)
        rmsA = 1 - expf(-1 / (0.006 * fs)); attA = 1 - expf(-1 / (0.004 * fs)); relA = 1 - expf(-1 / (0.14 * fs))
        envA = 1 - expf(-1 / (0.03 * fs))
        dblLine = DelayLine(max: ms(30)); dblHP.setLP(fs: fs, f: 180)
        dL = DelayLine(max: ms(1100)); dR = DelayLine(max: ms(1100))
        fbHPL.setLP(fs: fs, f: 280); fbLPL.setLP(fs: fs, f: 4500); fbHPR.setLP(fs: fs, f: 280); fbLPR.setLP(fs: fs, f: 4500)
        pre = DelayLine(max: ms(120)); rvHP.setLP(fs: fs, f: 220); rvLP.setLP(fs: fs, f: 8500)
        let sc = fs / 44100
        diff = [142, 107, 379, 277].map { Allpass(Int((Float($0) * sc).rounded()), 0.7) }
        baseLens = [1557, 1617, 1491, 1422, 1277, 1356, 1188, 1116].map { Float($0) * sc }
        lines = baseLens.map { DelayLine(max: Int(($0 * 1.3).rounded(.up)) + 64) }
        damp = Array(repeating: 0, count: 8)
        seenGen = -1
    }

    private func adopt() {
        p = incoming; (reverbAmt, echoAmt) = incomingAmounts
        let s = 0.6 + 0.4 * p.rvSize
        for i in 0..<8 {
            lens[i] = baseLens[i] * s
            gains[i] = powf(10, -3 * lens[i] / (fs * p.rvDecay))     // per-line feedback for the requested RT60
        }
        dampA = 1 - expf(-DSP.tau * (2500 + (1 - p.rvDamp) * 9000) / fs)
        makeup = DSP.db(-p.thr * (1 - 1 / p.ratio) * 0.45)
    }

    /// Real-time: mono voice (average of inL/inR) → stereo out. Buffers may alias.
    func process(inL: UnsafePointer<Float>, inR: UnsafePointer<Float>?, outL: UnsafeMutablePointer<Float>, outR: UnsafeMutablePointer<Float>, count: Int) {
        guard lines.count == 8 else {   // not prepared yet: pass through
            for n in 0..<count { let x = inR.map { (inL[n] + $0[n]) * 0.5 } ?? inL[n]; outL[n] = x; outR[n] = x }
            return
        }
        if seenGen != incomingGen { seenGen = incomingGen; adopt() }
        let preSamp = max(1, p.rvPre * fs / 1000), dSamp = max(1, p.dlyTime * fs)
        let tDbl = p.dbl, tDly = p.dlyMix * echoAmt, tRv = min(0.6, p.rvMix * reverbAmt)
        let thr = p.thr, slope = 1 - 1 / p.ratio, knee: Float = 6
        let deMax = p.deess, warm = p.warm, drive = 1 + warm * 3, norm = 1 / tanhf(drive)
        let w = p.width, sm: Float = 0.0015, H: Float = 1 / sqrtf(8), dFb = p.dlyFb
        let base = 0.013 * fs, dev = 0.0009 * fs

        for n in 0..<count {
            var x = inR.map { (inL[n] + $0[n]) * 0.5 } ?? inL[n]

            // compressor (soft knee)
            rms += rmsA * (x * x - rms)
            let lvl = 10 * log10f(rms + 1e-12), d = lvl - thr
            var want: Float = 0
            if d > knee / 2 { want = d * slope } else if d > -knee / 2 { want = slope * (d + knee / 2) * (d + knee / 2) / (2 * knee) }
            gr += (want > gr ? attA : relA) * (want - gr)
            x *= DSP.db(-gr) * makeup
            env += envA * (abs(x) - env)

            // de-esser: "s" band loud relative to the voice → turn the top band down
            let lo = split.run(x), hi = x - lo
            let sb = abs(sib.run(x)), ax = abs(x)
            deEnv += (sb > deEnv ? 0.3 : 0.0015) * (sb - deEnv)
            fullEnv += (ax > fullEnv ? 0.3 : 0.0015) * (ax - fullEnv)
            let ratio = deEnv / (0.3 * fullEnv + 1e-5)
            let over: Float = ratio > 1 ? min(deMax, 20 * log10f(ratio) * 1.2) : 0
            x = lo + hi * DSP.db(-over)

            // tape warmth
            if warm > 0 { x = x * (1 - warm) + tanhf(x * drive) * norm * warm }
            let dry = x

            mixDbl += sm * (tDbl - mixDbl); mixDly += sm * (tDly - mixDly); mixRv += sm * (tRv - mixRv)

            // doubler
            dblLine.write(dry)
            lfo1 += 0.31 / fs; if lfo1 >= 1 { lfo1 -= 1 }
            lfo2 += 0.47 / fs; if lfo2 >= 1 { lfo2 -= 1 }
            let v1 = dblHP.hp(dblLine.read(base + dev * sinf(DSP.tau * lfo1)))
            let v2 = dblLine.read(base * 1.27 + dev * sinf(DSP.tau * lfo2))
            let dblL = v1 * mixDbl, dblR = v2 * mixDbl

            // ping-pong echo, ducked while you sing
            var eL: Float = 0, eR: Float = 0
            if mixDly > 1e-4 {
                let rl = dL.read(dSamp), rr = dR.read(dSamp)
                let fl = fbLPL.lp(fbHPL.hp(rl)), fr = fbLPR.lp(fbHPR.hp(rr))
                dL.write(dry + fr * dFb)
                dR.write(fl * dFb)
                let duck = 1 - min(0.7, env * 6)
                eL = fl * mixDly * duck; eR = fr * mixDly * duck
            } else { dL.write(0); dR.write(0) }

            // reverb: feedback delay network
            pre.write(dry)
            var r = rvLP.lp(rvHP.hp(pre.read(preSamp)))
            for ap in diff { r = ap.run(r) }
            modPh += 0.5 / fs; if modPh >= 1 { modPh -= 1 }
            let mod = sinf(DSP.tau * modPh) * 6
            var st = (Float(0), Float(0), Float(0), Float(0), Float(0), Float(0), Float(0), Float(0))
            for i in 0..<8 {
                let m: Float = i == 0 ? mod : (i == 1 ? -mod : 0)
                let y = lines[i].read(lens[i] + m)
                damp[i] += dampA * (y - damp[i])
                let v = damp[i] * gains[i]
                switch i { case 0: st.0 = v; case 1: st.1 = v; case 2: st.2 = v; case 3: st.3 = v
                           case 4: st.4 = v; case 5: st.5 = v; case 6: st.6 = v; default: st.7 = v }
            }
            let a0 = st.0 + st.1, a1 = st.0 - st.1, a2 = st.2 + st.3, a3 = st.2 - st.3
            let a4 = st.4 + st.5, a5 = st.4 - st.5, a6 = st.6 + st.7, a7 = st.6 - st.7
            let b0 = a0 + a2, b1 = a1 + a3, b2 = a0 - a2, b3 = a1 - a3, b4 = a4 + a6, b5 = a5 + a7, b6 = a4 - a6, b7 = a5 - a7
            let inj = r * 0.35
            lines[0].write((b0 + b4) * H + inj); lines[1].write((b1 + b5) * H + inj)
            lines[2].write((b2 + b6) * H + inj); lines[3].write((b3 + b7) * H + inj)
            lines[4].write((b0 - b4) * H + inj); lines[5].write((b1 - b5) * H + inj)
            lines[6].write((b2 - b6) * H + inj); lines[7].write((b3 - b7) * H + inj)
            let rduck = 1 - min(0.35, env * 3)
            let rL = (st.0 - st.2 + st.4 - st.6) * 0.5 * mixRv * rduck
            let rR = (st.1 - st.3 + st.5 - st.7) * 0.5 * mixRv * rduck

            // width on the effects only, then the soft safety limiter
            var wl = dblL + eL + rL, wr = dblR + eR + rR
            let mid = (wl + wr) * 0.5, side = (wl - wr) * 0.5 * w
            wl = mid + side; wr = mid - side
            outL[n] = Self.soft(dry + wl)
            outR[n] = Self.soft(dry + wr)
        }
    }

    @inline(__always) static func soft(_ x: Float) -> Float {
        let a = abs(x)
        if a <= 0.8 { return x }
        return (x < 0 ? -1 : 1) * (0.8 + 0.2 * tanhf((a - 0.8) / 0.2))
    }
}

/// Wraps the kernel as a real Audio Unit so it sits in the AVAudioEngine graph like Apple's own effects.
nonisolated final class StudioFXUnit: AUAudioUnit, @unchecked Sendable {
    static let desc = AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: 0x6B53_7464 /* kStd */,
                                                componentManufacturer: 0x4B61_7261 /* Kara */, componentFlags: 0, componentFlagsMask: 0)
    private static let registered: Bool = {
        AUAudioUnit.registerSubclass(StudioFXUnit.self, as: desc, name: "Karaoke: Studio FX", version: 1)
        return true
    }()
    static func register() { _ = registered }

    let kernel = StudioKernel()
    private var inBus: AUAudioUnitBus!
    private var outBus: AUAudioUnitBus!
    private var ins: AUAudioUnitBusArray!
    private var outs: AUAudioUnitBusArray!

    override init(componentDescription: AudioComponentDescription, options: AudioComponentInstantiationOptions = []) throws {
        try super.init(componentDescription: componentDescription, options: options)
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        inBus = try AUAudioUnitBus(format: fmt)
        outBus = try AUAudioUnitBus(format: fmt)
        ins = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [inBus])
        outs = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [outBus])
        maximumFramesToRender = 4096
    }

    override var inputBusses: AUAudioUnitBusArray { ins }
    override var outputBusses: AUAudioUnitBusArray { outs }
    override var latency: TimeInterval { 0 }

    override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        kernel.prepare(sampleRate: outBus.format.sampleRate)
    }

    override var internalRenderBlock: AUInternalRenderBlock {
        let kernel = kernel
        return { _, timestamp, frames, _, outputData, _, pullInput in
            guard let pullInput else { return kAudioUnitErr_NoConnection }
            let abl = UnsafeMutableAudioBufferListPointer(outputData)
            let n = Int(frames)
            guard n <= 8192 else { return kAudioUnitErr_TooManyFramesToProcess }
            for i in 0..<abl.count where abl[i].mData == nil {
                abl[i].mData = UnsafeMutableRawPointer(i == 0 ? kernel.scratchL : kernel.scratchR)
                abl[i].mDataByteSize = UInt32(n * MemoryLayout<Float>.size)
            }
            var flags = AudioUnitRenderActionFlags()
            let status = pullInput(&flags, timestamp, frames, 0, outputData)
            guard status == noErr else { return status }
            guard let l = abl.first?.mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            let r = abl.count > 1 ? abl[1].mData?.assumingMemoryBound(to: Float.self) : nil
            kernel.process(inL: UnsafePointer(l), inR: r.map { UnsafePointer($0) }, outL: l, outR: r ?? l, count: n)
            return noErr
        }
    }
}
