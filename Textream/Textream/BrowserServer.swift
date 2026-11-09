//
//  BrowserServer.swift
//  Textream
//
//  Created by Fatih Kadir Akın on 8.02.2026.
//

import AppKit
import Foundation
import Network

// MARK: - Browser State

struct BrowserState: Codable {
    let words: [String]
    let highlightedCharCount: Int
    let totalCharCount: Int
    let audioLevels: [Double]
    let isListening: Bool
    let isDone: Bool
    let fontColor: String
    let cueColor: String
    let hasNextPage: Bool
    let isActive: Bool
    let highlightWords: Bool
    let lastSpokenText: String
}

// MARK: - Browser Server

class BrowserServer {
    private var httpListener: NWListener?
    private var wsListener: NWListener?
    private var wsConnections: [NWConnection] = []
    private var broadcastTimer: Timer?

    // Content state
    private var words: [String] = []
    private var totalCharCount: Int = 0
    private var hasNextPage: Bool = false
    private weak var speechRecognizer: SpeechRecognizer?
    /// The Mac's shared Classic/Voice-Activated reading position. The page
    /// only reads it; the session overlay is the only screen that advances it.
    private weak var scrollProgress: SharedScrollProgress?
    private var contentActive: Bool = false

    var httpPort: UInt16 { NotchSettings.shared.browserServerPort }
    var wsPort: UInt16 { httpPort + 1 }
    var isRunning: Bool { httpListener != nil }
    var connectedClients: Int { wsConnections.count }

    // MARK: - Lifecycle

    func start() {
        stop()
        startHTTPListener()
        startWSListener()
    }

    func stop() {
        broadcastTimer?.invalidate()
        broadcastTimer = nil

        httpListener?.cancel()
        httpListener = nil
        wsListener?.cancel()
        wsListener = nil

        for conn in wsConnections { conn.cancel() }
        wsConnections.removeAll()
        contentActive = false
    }

    // MARK: - Content Management

    func showContent(speechRecognizer: SpeechRecognizer, words: [String], totalCharCount: Int, hasNextPage: Bool, scrollProgress: SharedScrollProgress) {
        self.speechRecognizer = speechRecognizer
        self.scrollProgress = scrollProgress
        self.words = words
        self.totalCharCount = totalCharCount
        self.hasNextPage = hasNextPage
        self.contentActive = true
        startBroadcasting()
    }

    func updateContent(words: [String], totalCharCount: Int, hasNextPage: Bool) {
        self.words = words
        self.totalCharCount = totalCharCount
        self.hasNextPage = hasNextPage
    }

    func hideContent() {
        contentActive = false
        broadcastTimer?.invalidate()
        broadcastTimer = nil
        broadcastInactive()
    }

    // MARK: - HTTP Server

    private func startHTTPListener() {
        guard let port = NWEndpoint.Port(rawValue: httpPort) else { return }
        do {
            httpListener = try NWListener(using: .tcp, on: port)
        } catch { return }

        httpListener?.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.httpListener = nil }
        }
        httpListener?.newConnectionHandler = { [weak self] conn in
            self?.handleHTTPConnection(conn)
        }
        httpListener?.start(queue: .main)
    }

    private func handleHTTPConnection(_ conn: NWConnection) {
        conn.start(queue: .main)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            guard let self else { conn.cancel(); return }
            guard error == nil else { conn.cancel(); return }

            let head = String(decoding: (data ?? Data()).prefix(1024), as: UTF8.self)
            let response = Self.isTouchIconRequest(head)
                ? self.touchIconResponse() : self.buildHTTPResponse()
            conn.send(content: response, completion: .contentProcessed { _ in
                conn.cancel()
            })
        }
    }

    private func buildHTTPResponse() -> Data {
        let html = Self.generateHTML(wsPort: wsPort)
        let body = Data(html.utf8)
        let header = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"
        return Data(header.utf8) + body
    }

    /// True when the request line asks for an iOS Home Screen icon, for example
    /// "GET /apple-touch-icon.png HTTP/1.1". Every other request gets the page.
    static func isTouchIconRequest(_ head: String) -> Bool {
        guard let line = head.split(whereSeparator: \.isNewline).first else { return false }
        let parts = line.split(separator: " ")
        guard parts.count == 3 else { return false }
        let path = parts[1].split(separator: "?", omittingEmptySubsequences: false)[0]
        return path.hasPrefix("/apple-touch-icon") && path.hasSuffix(".png")
    }

    /// The app icon as a PNG, made once on first use.
    private lazy var touchIconPNG: Data? = BrowserServer.renderTouchIcon()

    private func touchIconResponse() -> Data {
        guard let png = touchIconPNG else {
            return Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
        }
        let header = "HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: \(png.count)\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"
        return Data(header.utf8) + png
    }

    /// Draws the app icon on an opaque 180x180 tile. iOS shows transparent
    /// pixels as black and adds its own rounded corners. The macOS icon has a
    /// clear margin of about 10% on each side, so it is drawn at 125% to make
    /// its rounded square fill the tile.
    private static func renderTouchIcon() -> Data? {
        guard let icon = NSApplication.shared.applicationIconImage,
              let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 180, pixelsHigh: 180,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.black.setFill()
        NSRect(x: 0, y: 0, width: 180, height: 180).fill()
        icon.draw(in: NSRect(x: -22.5, y: -22.5, width: 225, height: 225))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: - WebSocket Server

    private func startWSListener() {
        guard let port = NWEndpoint.Port(rawValue: wsPort) else { return }
        let params = NWParameters.tcp
        let wsOptions = NWProtocolWebSocket.Options()
        params.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        do {
            wsListener = try NWListener(using: params, on: port)
        } catch { return }

        wsListener?.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.wsListener = nil }
        }
        wsListener?.newConnectionHandler = { [weak self] conn in
            self?.handleWSConnection(conn)
        }
        wsListener?.start(queue: .main)
    }

    private func handleWSConnection(_ conn: NWConnection) {
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                // With no session, nothing else is sent until the next one starts,
                // so a new client gets the waiting state now. During a session the
                // broadcast timer reaches it within 0.1 s.
                if let self, !self.contentActive { self.send(Self.inactiveState, to: [conn]) }
            case .failed, .cancelled:
                self?.wsConnections.removeAll { $0 === conn }
            default: break
            }
        }
        conn.start(queue: .main)
        wsConnections.append(conn)
        receiveWSMessage(conn)
    }

    private func receiveWSMessage(_ conn: NWConnection) {
        conn.receiveMessage { [weak self] _, _, _, error in
            if error != nil { conn.cancel(); return }
            self?.receiveWSMessage(conn)
        }
    }

    // MARK: - Broadcasting

    private func startBroadcasting() {
        broadcastTimer?.invalidate()
        broadcastTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.broadcastCurrentState()
        }
    }

    private func broadcastCurrentState() {
        guard contentActive, !wsConnections.isEmpty else { return }

        let mode = NotchSettings.shared.listeningMode
        let charCount = currentCharCount()

        let effective = min(charCount, totalCharCount)
        let rawDone = totalCharCount > 0 && effective >= totalCharCount
        // In classic/silence-paused modes on the last page, suppress Done so the
        // browser keeps showing the prompter text (speaker may still be talking).
        let isDone = rawDone && (mode == .wordTracking || hasNextPage)

        let highlightWords = mode == .wordTracking

        let state = BrowserState(
            words: words,
            highlightedCharCount: effective,
            totalCharCount: totalCharCount,
            audioLevels: (speechRecognizer?.audioLevels ?? []).map { Double($0) },
            isListening: speechRecognizer?.isListening ?? false,
            isDone: isDone,
            fontColor: NotchSettings.shared.fontColorPreset.cssColor,
            cueColor: NotchSettings.shared.cueColorPreset.cssColor,
            hasNextPage: hasNextPage,
            isActive: true,
            highlightWords: highlightWords,
            lastSpokenText: speechRecognizer?.lastSpokenText ?? ""
        )
        broadcast(state)
    }

    /// What clients show when no session runs: the waiting screen.
    private static let inactiveState = BrowserState(
        words: [], highlightedCharCount: 0, totalCharCount: 0,
        audioLevels: [], isListening: false, isDone: false,
        fontColor: "#ffffff", cueColor: "#ffffff", hasNextPage: false, isActive: false,
        highlightWords: true, lastSpokenText: ""
    )

    private func broadcastInactive() {
        broadcast(Self.inactiveState)
    }

    private func broadcast(_ state: BrowserState) {
        send(state, to: wsConnections)
    }

    /// Sends the state as one WebSocket text message to each connection.
    private func send(_ state: BrowserState, to conns: [NWConnection]) {
        guard !conns.isEmpty, let data = try? JSONEncoder().encode(state) else { return }
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let ctx = NWConnection.ContentContext(identifier: "ws", metadata: [meta])
        for conn in conns {
            conn.send(content: data, contentContext: ctx, completion: .idempotent)
        }
    }

    // MARK: - Helpers

    /// The char count the next broadcast sends, from the stored session
    /// state and the current listening mode. Internal so a test can call it.
    func currentCharCount() -> Int {
        Self.phoneCharCount(
            isWordTracking: NotchSettings.shared.listeningMode == .wordTracking,
            recognizedCharCount: speechRecognizer?.recognizedCharCount ?? 0,
            sharedWordProgress: scrollProgress?.wordProgress ?? 0,
            words: words,
            totalCharCount: totalCharCount
        )
    }

    /// The highlighted char count that the phone page shows. Word Tracking
    /// follows the mic. Classic and Voice-Activated show the Mac's shared
    /// reading position, so the page stops on Pause, follows taps and scrolls
    /// on any Mac screen, and a phone that connects late opens on the
    /// current word. The page has no clock of its own.
    static func phoneCharCount(
        isWordTracking: Bool,
        recognizedCharCount: Int,
        sharedWordProgress: Double,
        words: [String],
        totalCharCount: Int
    ) -> Int {
        if isWordTracking { return recognizedCharCount }
        return ScrollProgressMath.charOffset(
            forWordProgress: sharedWordProgress,
            words: words,
            totalCharCount: totalCharCount
        )
    }

    static func localIPAddress() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var preferred: String?
        var fallback: String?

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let addr = ptr.pointee
            guard addr.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: addr.ifa_name)

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                addr.ifa_addr, socklen_t(addr.ifa_addr.pointee.sa_len),
                &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST
            ) == 0 else { continue }
            let ip = String(cString: hostname)
            guard ip != "127.0.0.1" else { continue }

            if name == "en0" || name == "en1" {
                preferred = ip
            } else if fallback == nil {
                fallback = ip
            }
        }
        return preferred ?? fallback
    }

    // MARK: - HTML Template

    static func generateHTML(wsPort: UInt16) -> String {
        """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1,user-scalable=no,viewport-fit=cover">
        <meta name="apple-mobile-web-app-capable" content="yes">
        <meta name="mobile-web-app-capable" content="yes">
        <meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
        <meta name="apple-mobile-web-app-title" content="Textream">
        <link rel="apple-touch-icon" href="/apple-touch-icon.png">
        <meta name="theme-color" content="#000000">
        <title>Textream</title>
        <style>
        *{margin:0;padding:0;box-sizing:border-box}
        html,body{height:100%;overflow:hidden;background:#000;color:#fff;
          font-family:-apple-system,BlinkMacSystemFont,'SF Pro Display','Helvetica Neue',system-ui,sans-serif}
        body{display:flex;flex-direction:column}

        /* Waiting */
        #waiting{flex:1;display:flex;flex-direction:column;align-items:center;
          justify-content:center;gap:16px}
        #waiting .icon{font-size:48px}
        #waiting .title{font-size:20px;font-weight:600;color:rgba(255,255,255,.6);
          animation:pulse 2s ease-in-out infinite}
        #waiting .sub{font-size:14px;color:rgba(255,255,255,.3);text-align:center;
          max-width:320px;line-height:1.5}
        #waiting .url{font-size:12px;color:rgba(255,255,255,.15);margin-top:8px;
          font-family:ui-monospace,monospace}
        @keyframes pulse{0%,100%{opacity:.6}50%{opacity:1}}

        /* Main */
        #main{display:none;flex-direction:column;height:100%}

        /* Prompter with fade mask */
        #prompter-wrap{flex:1;position:relative;overflow:hidden}
        #prompter-wrap::before,#prompter-wrap::after{
          content:'';position:absolute;left:0;right:0;z-index:2;pointer-events:none}
        #prompter-wrap::before{top:0;height:8%;
          background:linear-gradient(to bottom,#000,transparent)}
        #prompter-wrap::after{bottom:0;height:8%;
          background:linear-gradient(to top,#000,transparent)}
        /* The top padding keeps the first lines below the status bar and the controls. */
        #prompter{height:100%;overflow-y:auto;
          padding:calc(env(safe-area-inset-top) + 60px) max(40px,8%) 20px;
          -webkit-overflow-scrolling:touch;scroll-behavior:smooth}
        #prompter::-webkit-scrollbar{display:none}

        /* Text: match ExternalDisplayView font sizing: max(48, min(96, width/14)).
           The column is at least 9em wide (a word of about 16 letters) when
           the screen has space for it. */
        #text-container{
          font-size:calc(clamp(48px,calc(100vw / 14),96px) * var(--size,1));
          font-weight:600;line-height:1.4;word-wrap:break-word;
          max-width:max(var(--col,100%),9em);margin:0 auto}
        .w{display:inline;transition:color .12s ease}
        .w.ann{font-style:italic}

        /* Bottom bar — matches ExternalDisplayView layout */
        #bar{flex-shrink:0;padding:12px max(40px,8%) max(40px,env(safe-area-inset-bottom));
          display:flex;align-items:center;gap:16px}
        #waveform{width:240px;height:32px;display:flex;align-items:center;gap:1.5px}
        .wf{width:3px;background:rgba(255,255,255,.15);border-radius:1.5px;
          min-height:3px;transition:height .08s ease,background .12s ease;align-self:center}
        #spoken{font-size:18px;font-weight:500;color:rgba(255,255,255,.5);
          flex:1;overflow:hidden;white-space:nowrap;text-overflow:ellipsis;
          direction:rtl;text-align:left}
        #mic-btn{width:40px;height:40px;border-radius:50%;
          background:rgba(255,255,255,.15);display:flex;align-items:center;
          justify-content:center;flex-shrink:0}
        #mic-dot{width:10px;height:10px;border-radius:50%;
          background:#facc15;opacity:0;transition:opacity .2s}
        #mic-dot.on{opacity:1}

        /* Controls — sit above every screen so the rig can be set up before the
           prompter starts, and stay unflipped when mirroring. */
        #controls{position:fixed;z-index:10;display:flex;gap:8px;
          top:calc(12px + env(safe-area-inset-top));
          right:calc(12px + env(safe-area-inset-right))}
        #controls button{
          height:36px;padding:0 12px;border-radius:18px;border:0;
          background:rgba(255,255,255,.12);color:rgba(255,255,255,.55);
          display:flex;align-items:center;justify-content:center;gap:6px;
          font:inherit;font-size:12px;font-weight:600;line-height:1;
          cursor:pointer;-webkit-tap-highlight-color:transparent;
          backdrop-filter:blur(8px);
          transition:background .2s ease,color .2s ease}
        #controls .glyph{font-size:14px}
        #controls button.on{background:rgba(250,204,21,.22);color:#facc15}

        /* Flip the reading surface for teleprompter glass. */
        body.mirrored #waiting,body.mirrored #main,body.mirrored #done{
          transform:scaleX(-1)}

        /* Done */
        #done{display:none;flex-direction:column;align-items:center;
          justify-content:center;height:100%;gap:12px}
        #done .check{width:64px;height:64px;border-radius:50%;background:#22c55e;
          display:flex;align-items:center;justify-content:center;
          font-size:32px;color:#fff;animation:pop .4s ease}
        #done .label{font-size:32px;font-weight:700;color:#fff;
          animation:fadeUp .4s ease .1s both}
        @keyframes pop{0%{transform:scale(0);opacity:0}
          60%{transform:scale(1.15)}100%{transform:scale(1);opacity:1}}
        @keyframes fadeUp{0%{opacity:0;transform:translateY(8px)}
          100%{opacity:1;transform:translateY(0)}}

        @media(max-width:768px){
          #prompter{padding:calc(env(safe-area-inset-top) + 56px) 5% 16px}
          #bar{padding:10px 5% max(20px,env(safe-area-inset-bottom))}
          #waveform{width:160px;height:28px}
          #text-container{
            font-size:calc(clamp(28px,calc(100vw / 10),60px) * var(--size,1))}
          #controls{top:calc(10px + env(safe-area-inset-top));
            right:calc(10px + env(safe-area-inset-right))}
          #controls button{padding:0 10px}
          #mirror-btn .label{display:none}
        }

        /* The column width is for a wide landscape screen. In portrait the
           text uses the full width, so the width control is hidden. */
        @media(orientation:portrait){
          #text-container{max-width:none}
          #controls #width-btn{display:none}
        }
        </style>
        </head>
        <body>

        <div id="controls">
          <button id="size-btn" type="button" title="Text size">
            <span class="glyph" aria-hidden="true">A</span>
            <span id="size-label">S</span>
          </button>
          <button id="width-btn" type="button" title="Column width">
            <span class="glyph" aria-hidden="true">↔</span>
            <span id="width-label">50%</span>
          </button>
          <button id="mirror-btn" type="button" aria-pressed="false"
            title="Mirror for teleprompter glass">
            <span class="glyph" aria-hidden="true">⇄</span>
            <span class="label">Mirror</span>
          </button>
        </div>

        <div id="waiting">
          <div class="icon">📡</div>
          <div class="title">Waiting for Textream…</div>
          <div class="sub">Start reading in the app to see your teleprompter here</div>
          <div class="url" id="conn-status">Connecting…</div>
        </div>

        <div id="main">
          <div id="prompter-wrap">
            <div id="prompter"><div id="text-container"></div></div>
          </div>
          <div id="bar">
            <div id="waveform"></div>
            <div id="spoken"></div>
            <div id="mic-btn"><div id="mic-dot"></div></div>
          </div>
        </div>

        <div id="done">
          <div class="check">✓</div>
          <div class="label">Done!</div>
        </div>

        <script>
        const WSP=\(wsPort),host=location.hostname;
        const MIRROR_KEY='textream.remote.mirror';
        const WIDTH_KEY='textream.remote.width';
        const SIZE_KEY='textream.remote.size';
        const SIZES=[['XS',.6],['S',.8],['M',1],['L',1.25],['XL',1.5]];
        // A wide landscape phone gives long lines and a lot of eye movement.
        const WIDTHS=[100,80,65,50,35];
        const DEF_SIZE=1,DEF_WIDTH=3;   // defaults: S text, 50% column
        let ws,rt,staleT,prevWordKey='',prevHcc=0,scrollTgt=null,mirrored=false,
            widthIdx=DEF_WIDTH,sizeIdx=DEF_SIZE,setSession=()=>{};

        /* ---- helpers ---- */

        // Parse a CSS color into [r,g,b]
        function parseColor(c){
          if(c.startsWith('#')){
            const v=c.length===4
              ?[c[1]+c[1],c[2]+c[2],c[3]+c[3]]
              :[c.slice(1,3),c.slice(3,5),c.slice(5,7)];
            return v.map(h=>parseInt(h,16));
          }
          const m=c.match(/(\\d+)/g);
          return m?m.slice(0,3).map(Number):[255,255,255];
        }
        function rgba(rgb,a){return 'rgba('+rgb[0]+','+rgb[1]+','+rgb[2]+','+a+')';}

        /* ---- text size ---- */

        function applySize(){
          const [label,scale]=SIZES[sizeIdx];
          document.documentElement.style.setProperty('--size',scale);
          document.getElementById('size-label').textContent=label;
          document.getElementById('size-btn').classList.toggle('on',sizeIdx!==DEF_SIZE);
        }

        // A valid ?size= value is used and saved, like ?mirror=. Otherwise the
        // saved value is used, then the default.
        function initSize(){
          const q=(new URLSearchParams(location.search).get('size')||'').toUpperCase();
          const qi=SIZES.findIndex(x=>x[0]===q);
          let stored='';
          try{
            if(qi>=0)localStorage.setItem(SIZE_KEY,SIZES[qi][0]);
            stored=(localStorage.getItem(SIZE_KEY)||'').toUpperCase();
          }catch(e){}
          const si=SIZES.findIndex(x=>x[0]===stored);
          sizeIdx=qi>=0?qi:(si>=0?si:DEF_SIZE);
          document.getElementById('size-btn').addEventListener('click',()=>{
            sizeIdx=(sizeIdx+1)%SIZES.length;
            try{localStorage.setItem(SIZE_KEY,SIZES[sizeIdx][0])}catch(e){}
            applySize();
          });
          applySize();
        }

        /* ---- column width ---- */

        function applyWidth(){
          const w=WIDTHS[widthIdx];
          document.documentElement.style.setProperty('--col',w+'%');
          document.getElementById('width-label').textContent=w+'%';
          document.getElementById('width-btn')
            .classList.toggle('on',widthIdx!==DEF_WIDTH);
        }

        // Same rule as initSize. The width applies only in landscape (see CSS).
        function initWidth(){
          const qi=WIDTHS.indexOf(parseInt(new URLSearchParams(location.search).get('width'),10));
          let si=-1;
          try{
            if(qi>=0)localStorage.setItem(WIDTH_KEY,WIDTHS[qi]);
            si=WIDTHS.indexOf(parseInt(localStorage.getItem(WIDTH_KEY),10));
          }catch(e){}
          widthIdx=qi>=0?qi:(si>=0?si:DEF_WIDTH);
          document.getElementById('width-btn').addEventListener('click',()=>{
            widthIdx=(widthIdx+1)%WIDTHS.length;
            try{localStorage.setItem(WIDTH_KEY,WIDTHS[widthIdx])}catch(e){}
            applyWidth();
          });
          applyWidth();
        }

        /* ---- mirror ---- */

        // ?mirror=1 / ?mirror=0 lets a QR code or bookmark preset a device.
        function mirrorOverride(){
          const raw=new URLSearchParams(location.search).get('mirror');
          if(raw===null)return null;
          const v=raw.toLowerCase();
          if(v==='1'||v==='true'||v==='on'||v==='yes')return true;
          if(v==='0'||v==='false'||v==='off'||v==='no')return false;
          return null;
        }

        function applyMirror(){
          document.body.classList.toggle('mirrored',mirrored);
          const b=document.getElementById('mirror-btn');
          b.classList.toggle('on',mirrored);
          b.setAttribute('aria-pressed',mirrored?'true':'false');
        }

        function initMirror(){
          const o=mirrorOverride();
          try{
            if(o!==null)localStorage.setItem(MIRROR_KEY,o?'1':'0');
            mirrored=o!==null?o:localStorage.getItem(MIRROR_KEY)==='1';
          }catch(e){mirrored=o===true}
          document.getElementById('mirror-btn').addEventListener('click',()=>{
            mirrored=!mirrored;
            try{localStorage.setItem(MIRROR_KEY,mirrored?'1':'0')}catch(e){}
            applyMirror();
          });
          applyMirror();
        }

        // Detect annotation words: [bracket] or emoji-only (no letters/digits)
        function isAnnotation(w){
          if(w.startsWith('[')&&w.endsWith(']'))return true;
          return!/[a-zA-Z0-9\\u00C0-\\u024F\\u0400-\\u04FF\\u3000-\\u9FFF\\uAC00-\\uD7AF]/.test(w);
        }

        // Count letters+digits in a word
        function letterCount(w){
          let n=0;for(const ch of w)if(/[a-zA-Z0-9\\u00C0-\\u024F\\u0400-\\u04FF\\u3000-\\u9FFF\\uAC00-\\uD7AF]/.test(ch))n++;
          return Math.max(1,n);
        }

        /* ---- connection ---- */

        // During a session the Mac sends a state every 0.1 s. If no state comes
        // for 5 s, the Mac is gone (for example, its lid is closed), but the
        // socket can stay open with no close event. Then stale() drops the
        // socket and connects again, so the session ends on this page too.
        const STALE_MS=5000;
        function connect(){
          ws=new WebSocket('ws://'+host+':'+WSP);
          ws.onopen=()=>{clearTimeout(rt);
            document.getElementById('conn-status').textContent='Connected';};
          ws.onmessage=e=>{try{render(JSON.parse(e.data))}catch(x){console.error(x)}};
          ws.onclose=lost;
          ws.onerror=()=>{ws.close()};
        }
        function lost(){
          clearTimeout(staleT);
          setSession(false);
          document.getElementById('conn-status').textContent='Reconnecting…';
          rt=setTimeout(connect,1500);
        }
        function stale(){
          ws.onopen=ws.onmessage=ws.onclose=ws.onerror=null;
          ws.close();
          lost();
        }

        /* ---- render ---- */

        function render(s){
          setSession(!!s.isActive);   // Done screens count: the session goes on
          clearTimeout(staleT);
          if(s.isActive)staleT=setTimeout(stale,STALE_MS);
          const wEl=document.getElementById('waiting'),
                mEl=document.getElementById('main'),
                dEl=document.getElementById('done');

          if(!s.isActive){wEl.style.display='flex';mEl.style.display='none';
            dEl.style.display='none';return}
          if(s.isDone){wEl.style.display='none';mEl.style.display='none';
            dEl.style.display='flex';return}
          wEl.style.display='none';mEl.style.display='flex';dEl.style.display='none';

          const c=document.getElementById('text-container'),
                words=s.words||[],
                fc=s.fontColor||'#ffffff',
                cc=s.cueColor||fc,
                rgb=parseColor(fc),
                crgb=parseColor(cc),
                hlWords=s.highlightWords!==false,
                hcc=s.highlightedCharCount||0;

          // Rebuild spans only when words change
          const wordKey=words.length+'|'+(words[0]||'')+'|'+(words[words.length-1]||'');
          if(wordKey!==prevWordKey){
            c.innerHTML='';
            let cp=0;
            for(let i=0;i<words.length;i++){
              const wd=words[i],ann=isAnnotation(wd);
              const sp=document.createElement('span');
              sp.className=ann?'w ann':'w';
              sp.dataset.s=cp;
              sp.dataset.l=wd.length;
              sp.dataset.lc=letterCount(wd);
              sp.dataset.a=ann?'1':'0';
              sp.textContent=wd+' ';
              c.appendChild(sp);
              cp+=wd.length+1;
            }
            prevWordKey=wordKey;
            prevHcc=0;
          }

          // Find the next-word index (first non-fully-lit non-annotation)
          let nextIdx=-1;
          if(hlWords){
            const spans=c.children;
            for(let i=0;i<spans.length;i++){
              const d=spans[i].dataset;
              if(d.a==='1')continue;
              const charOff=parseInt(d.s),wLen=parseInt(d.l),lc=parseInt(d.lc);
              const litCount=Math.max(0,Math.min(wLen,hcc-charOff));
              if(litCount<lc){nextIdx=i;break}
            }
          }

          // Color each word to match native WordFlowLayout
          scrollTgt=null;
          const spans=c.children;
          for(let i=0;i<spans.length;i++){
            const sp=spans[i],d=sp.dataset;
            const charOff=parseInt(d.s),wLen=parseInt(d.l),lc=parseInt(d.lc);
            const ann=d.a==='1';
            const litCount=Math.max(0,Math.min(wLen,hcc-charOff));
            const isFullyLit=litCount>=lc;
            const charsInto=hcc-charOff;
            const isCurrent=(i===nextIdx)||(charsInto>=0&&!isFullyLit&&!ann);

            let color,underline=false;

            if(!hlWords){
              // Classic / silence-paused: uniform color, no per-word highlight
              color=ann?rgba(crgb,0.4):fc;
            } else if(ann){
              // Annotation: cue color with varying opacity
              color=isFullyLit?rgba(crgb,0.5):rgba(crgb,0.2);
            } else if(isFullyLit){
              // Already read: dimmed
              color=rgba(rgb,0.3);
            } else if(isCurrent){
              // Current / next word: medium + underline
              color=rgba(rgb,0.6);
              underline=true;
            } else {
              // Unread: full brightness
              color=fc;
            }

            sp.style.color=color;
            sp.style.textDecoration=underline?'underline':'none';
            sp.style.textDecorationColor=underline?color:'';
            sp.style.textUnderlineOffset=underline?'4px':'';

            // Track the active word for scrolling
            if(isCurrent||(!scrollTgt&&isFullyLit)){
              scrollTgt=sp;
            }
          }

          // Auto-scroll: keep active word centered. Also follow a backward move
          // (a re-read, or a tap on the Mac) to a line above the centre band.
          if(scrollTgt){
            const p=document.getElementById('prompter'),
                  r=scrollTgt.getBoundingClientRect(),
                  pr=p.getBoundingClientRect(),
                  mid=pr.top+pr.height*0.4,
                  back=hcc<prevHcc;
            if(r.top>mid+40||r.bottom<pr.top||(back&&r.top<mid-r.height))
              scrollTgt.scrollIntoView({behavior:'smooth',block:'center'});
          }
          prevHcc=hcc;

          // Waveform with progress coloring (matches native AudioWaveformProgressView)
          const wf=document.getElementById('waveform'),
                lv=s.audioLevels||[],
                pct=s.totalCharCount>0?s.highlightedCharCount/s.totalCharCount:0;
          while(wf.children.length<lv.length){
            const b=document.createElement('div');b.className='wf';wf.appendChild(b)}
          const barCount=wf.children.length;
          for(let i=0;i<barCount;i++){
            const l=i<lv.length?lv[i]:0;
            const barProgress=barCount>1?i/(barCount-1):0;
            const isLit=barProgress<=pct;
            wf.children[i].style.height=Math.max(3,l*32)+'px';
            wf.children[i].style.background=isLit
              ?'rgba(250,204,21,0.9)':'rgba(255,255,255,0.15)';
          }

          // Last spoken text (word-tracking mode only)
          const spokenEl=document.getElementById('spoken');
          if(hlWords&&s.lastSpokenText){
            const tail=s.lastSpokenText.split(' ').slice(-5).join(' ');
            spokenEl.textContent=tail;
          } else {
            spokenEl.textContent='';
          }

          // Mic indicator
          document.getElementById('mic-dot').classList.toggle('on',!!s.isListening);
        }

        // Init waveform bars
        const wfInit=document.getElementById('waveform');
        for(let i=0;i<30;i++){const b=document.createElement('div');
          b.className='wf';b.style.height='2px';wfInit.appendChild(b)}

        // Keep the screen awake while a session runs, and for 10 minutes after
        // the page opens, after each tap, and after a session stops or its
        // socket closes or goes silent. A rig phone then stays ready between
        // takes, and an idle page does not hold the screen on.
        // WakeLock needs a secure context, which a LAN http:// page is not, so
        // the fallback plays a hidden video. WebKit keeps the screen on only for
        // a video that has an audio track, is not muted and does not loop, so
        // the clip has a silent track and seeks back before its end. Do not set
        // muted, loop or a volume of 0. Side effects while it plays: other audio
        // on the phone stops, iOS can show the page in Now Playing, and
        // headphones that switch on their own can move to the phone.
        const AWAKE_GRACE_MS=10*60*1000;
        function initWakeLock(){
          const native='wakeLock' in navigator;
          let want=false,session=false,grace=false,graceT=null,
              lock=null,pending=false,v=null;
          function grab(){
            if(!native||pending||(lock&&!lock.released)||
               document.visibilityState!=='visible')return;
            pending=true;
            navigator.wakeLock.request('screen').then(l=>{
              pending=false;lock=l;
              if(!want){l.release().catch(()=>{});lock=null}
            },()=>{pending=false});
          }
          function play(){if(v&&v.paused)v.play().catch(()=>{})}
          function update(){
            const on=session||grace;
            if(on===want)return;
            want=on;
            if(on){grab();play();return}
            if(lock){lock.release().catch(()=>{});lock=null}
            if(v)v.pause();
          }
          function restartGrace(){
            grace=true;clearTimeout(graceT);
            graceT=setTimeout(()=>{grace=false;update()},AWAKE_GRACE_MS);
            update();
          }
          if(!native){
            v=document.createElement('video');
            v.setAttribute('playsinline','');
            v.style.cssText='position:fixed;width:1px;height:1px;opacity:0;pointer-events:none';
            v.src='data:video/mp4;base64,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';
            v.addEventListener('timeupdate',()=>{if(v.currentTime>0.5)v.currentTime=Math.random()});
            document.body.appendChild(v);
          }
          // iOS starts the clip only from a tap (touchend or click, not
          // touchstart). After that first start, play() works without a tap.
          const tap=()=>{restartGrace();grab();play()};
          document.addEventListener('touchend',tap,{passive:true});
          document.addEventListener('click',tap);
          document.addEventListener('visibilitychange',()=>{
            if(document.visibilityState==='visible'&&want){grab();play()}
          });
          restartGrace();
          // Called with state.isActive, and with false when the socket closes
          // or goes silent. When a session stops, the grace period starts again.
          return active=>{
            if(active===session)return;
            session=active;
            if(active)update();else restartGrace();
          };
        }

        setSession=initWakeLock();
        initSize();
        initWidth();
        initMirror();
        connect();
        </script>
        </body>
        </html>
        """
    }
}
