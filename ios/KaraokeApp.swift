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
            URLSession.shared.dataTask(with: req) { data, _, err in
                let text = data.map { String(decoding: $0, as: UTF8.self) }
                DispatchQueue.main.async {
                    if let text { replyHandler(text, nil) } else { replyHandler(nil, err?.localizedDescription ?? "failed") }
                }
            }.resume()
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

    func stop() {
        running = false
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
        c.apply(p, reverbAmount: reverbAmount, echoAmount: echoAmount)
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
        onRoute?(["wired": wired, "bluetooth": bluetooth, "car": car, "hearing": running, "running": running,
                  "summary": routeSummary, "tier": tier])
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
    let comp = AVAudioUnitEffect(audioComponentDescription: VoiceChain.apple(kAudioUnitSubType_DynamicsProcessor))
    let dblPitch = AVAudioUnitTimePitch()
    let dblDelay = AVAudioUnitDelay()
    let dblLevel = AVAudioMixerNode()
    let voiceBus = AVAudioMixerNode()
    let echo = AVAudioUnitDelay()
    let reverb = AVAudioUnitReverb()
    let limiter = AVAudioUnitEffect(audioComponentDescription: VoiceChain.apple(kAudioUnitSubType_PeakLimiter))
    let out = AVAudioMixerNode()
    let safe: Bool
    private var sink: AVAudioSinkNode?

    // pitch analysis: keep the last 4096 mic samples, analyse 2048 of them every 1024 new samples (~21 ms)
    private var ring = [Float](repeating: 0, count: 4096)
    private var ringPos = 0, fresh = 0
    private let analysisQ = DispatchQueue(label: "karaoke.voice.analysis")
    private var sampleRate: Double = 48000
    private let report: @Sendable (Float, Float) -> Void

    static func apple(_ sub: OSType) -> AudioComponentDescription {
        AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: sub,
                                  componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
    }

    /// safe = a minimal chain (mic → EQ → your EQ → reverb → out) with a plain tap for pitch:
    /// no doubler, compressor, limiter or real-time sink, the parts most likely to misbehave on unusual hardware.
    init(safe: Bool, report: @escaping @Sendable (Float, Float) -> Void) throws {
        self.safe = safe
        self.report = report
        let input = engine.inputNode
        let inFmt = input.outputFormat(forBus: 0)
        guard inFmt.sampleRate > 0, inFmt.channelCount > 0,
              let mono = AVAudioFormat(standardFormatWithSampleRate: inFmt.sampleRate, channels: 1) else {
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
            let sink = AVAudioSinkNode { [weak self] _, frames, abl -> OSStatus in
                let bufs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: abl))
                if let p = bufs.first?.mData?.assumingMemoryBound(to: Float.self) { self?.collect(p, Int(frames)) }
                return noErr
            }
            self.sink = sink
            for n in [inMix, eq, userEQ, comp, dblPitch, dblDelay, dblLevel, voiceBus, echo, reverb, limiter, out, sink] as [AVAudioNode] {
                engine.attach(n)
            }
            engine.connect(input, to: [AVAudioConnectionPoint(node: inMix, bus: 0), AVAudioConnectionPoint(node: sink, bus: 0)],
                           fromBus: 0, format: inFmt)
            engine.connect(inMix, to: eq, format: mono)
            engine.connect(eq, to: userEQ, format: mono)
            engine.connect(userEQ, to: comp, format: mono)
            engine.connect(comp, to: [AVAudioConnectionPoint(node: voiceBus, bus: 0), AVAudioConnectionPoint(node: dblPitch, bus: 0)],
                           fromBus: 0, format: mono)
            engine.connect(dblPitch, to: dblDelay, format: mono)      // doubler: a slightly detuned, slightly late copy
            engine.connect(dblDelay, to: dblLevel, format: mono)
            engine.connect(dblLevel, to: voiceBus, fromBus: 0, toBus: 1, format: mono)
            engine.connect(voiceBus, to: echo, format: mono)
            engine.connect(echo, to: reverb, format: mono)
            engine.connect(reverb, to: limiter, format: mono)
            engine.connect(limiter, to: out, format: mono)
            engine.connect(out, to: engine.mainMixerNode, format: mono)
        }
        engine.prepare()
    }

    func apply(_ p: VoicePreset, reverbAmount: Float, echoAmount: Float) {
        let b = eq.bands
        b[0].filterType = .highPass; b[0].frequency = p.lowCut; b[0].bypass = false
        b[1].filterType = .parametric; b[1].frequency = p.mudHz; b[1].bandwidth = 1.2; b[1].gain = p.mud; b[1].bypass = false
        b[2].filterType = .parametric; b[2].frequency = p.presenceHz; b[2].bandwidth = 1.5; b[2].gain = p.presence; b[2].bypass = false
        b[3].filterType = .highShelf; b[3].frequency = 11000; b[3].gain = p.air; b[3].bypass = false
        eq.globalGain = safe ? p.makeup * 0.5 : p.makeup     // no compressor in safe mode, so less makeup gain

        reverb.loadFactoryPreset(p.room)
        reverb.wetDryMix = min(80, p.roomWet * reverbAmount)
        if safe { return }

        set(comp, kDynamicsProcessorParam_Threshold, p.threshold)
        set(comp, kDynamicsProcessorParam_HeadRoom, p.headroom)
        set(comp, kDynamicsProcessorParam_ExpansionRatio, 1)
        set(comp, kDynamicsProcessorParam_AttackTime, 0.004)
        set(comp, kDynamicsProcessorParam_ReleaseTime, 0.12)

        dblPitch.pitch = 9            // +9 cents: the natural wobble of a second take
        dblDelay.delayTime = 0.018
        dblDelay.feedback = 0
        dblDelay.wetDryMix = 100
        dblLevel.outputVolume = p.double

        echo.delayTime = p.echoTime
        echo.feedback = p.echoFeedback
        echo.lowPassCutoff = 6000      // darker repeats sit behind the voice
        echo.wetDryMix = min(60, p.echoWet * echoAmount)
    }

    // Your EQ, on top of the preset: Bass 100 Hz · Body 250 Hz · Mid 1 kHz · Presence 3.5 kHz · Air 10 kHz
    func applyUserEQ(_ g: [Float]) {
        let spec: [(AVAudioUnitEQFilterType, Float)] = [(.lowShelf, 100), (.parametric, 250), (.parametric, 1000), (.parametric, 3500), (.highShelf, 10000)]
        for (i, b) in userEQ.bands.enumerated() where i < spec.count {
            b.filterType = spec[i].0; b.frequency = spec[i].1; b.bandwidth = 1.0
            b.gain = i < g.count ? g[i] : 0; b.bypass = false
        }
    }

    private func set(_ u: AVAudioUnitEffect, _ id: AudioUnitParameterID, _ v: Float) {
        AudioUnitSetParameter(u.audioUnit, id, kAudioUnitScope_Global, 0, v, 0)
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
