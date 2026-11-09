// extract: Textream/Textream/BrowserServer.swift BrowserServer generateHTML isTouchIconRequest
// Regression tests for the Remote page (BrowserServer.swift). When node is
// installed, the page script also runs against a small fake DOM.
import Foundation

var fails = 0
func check(_ name: String, _ ok: Bool) {
    print(ok ? "  pass" : "  FAIL", name)
    if !ok { fails += 1 }
}
func between(_ s: String, _ a: String, _ b: String) -> String? {
    guard let r = s.range(of: a), let e = s.range(of: b, range: r.upperBound..<s.endIndex) else { return nil }
    return String(s[r.upperBound..<e.lowerBound])
}

// Home Screen icon route: only the icon names get the PNG, everything else the page.
let icon = BrowserServer.isTouchIconRequest
check("icon: /apple-touch-icon.png", icon("GET /apple-touch-icon.png HTTP/1.1\r\nHost: mac:7373\r\n\r\n"))
check("icon: precomposed name", icon("GET /apple-touch-icon-precomposed.png HTTP/1.1\r\n\r\n"))
check("icon: name with a size", icon("GET /apple-touch-icon-180x180.png HTTP/1.1\r\n\r\n"))
check("icon: query is ignored", icon("GET /apple-touch-icon.png?v=2 HTTP/1.1\r\n\r\n"))
check("page: /", !icon("GET / HTTP/1.1\r\n\r\n"))
check("page: / with presets", !icon("GET /?size=L&width=65 HTTP/1.1\r\n\r\n"))
check("page: icon name only in the query", !icon("GET /?x=/apple-touch-icon.png HTTP/1.1\r\n\r\n"))
check("page: icon name only in a header", !icon("GET / HTTP/1.1\r\nReferer: http://mac/apple-touch-icon.png\r\n\r\n"))
check("page: favicon", !icon("GET /favicon.ico HTTP/1.1\r\n\r\n"))
check("page: empty or cut request", !icon("") && !icon("GET /apple-touch-ic"))

let html = BrowserServer.generateHTML(wsPort: 7374)
let script = between(html, "<script>", "</script>") ?? ""
check("page links the touch icon", html.contains(#"<link rel="apple-touch-icon" href="/apple-touch-icon.png">"#))

// Keep-awake clip: WebKit keeps the screen on only for an unmuted, non-looping video with audio.
let clip = between(script, "data:video/mp4;base64,", "'").flatMap { Data(base64Encoded: $0) } ?? Data()
func at(_ tag: String) -> Int? { clip.range(of: Data(tag.utf8))?.lowerBound }
check("clip has a video track", at("avc1") != nil)
check("clip has an audio track", at("mp4a") != nil)
check("clip index is before its data", (at("moov") ?? .max) < (at("mdat") ?? -1))
for bad in [".muted", ".loop", ".autoplay", ".volume", "'muted'", "'loop'", "'autoplay'", "'touchstart'"] {
    check("keep-awake script does not use \(bad)", !script.contains(bad))
}

// Defaults and layout.
check("size placeholder is the default S", html.contains(#"<span id="size-label">S</span>"#))
check("width placeholder is the default 50%", html.contains(#"<span id="width-label">50%</span>"#))
check("the column is never narrower than 9em", html.contains("max-width:max(var(--col,100%),9em)"))
check("portrait uses the full width and hides the width control",
      html.contains("@media(orientation:portrait)") && html.contains("#text-container{max-width:none}")
        && html.contains("#controls #width-btn{display:none}"))
check("first lines start below the status bar and the controls",
      html.contains("calc(env(safe-area-inset-top) + 60px)") && html.contains("calc(env(safe-area-inset-top) + 56px)"))

// Page script behaviour in node (skipped when node is not installed).
let dir = FileManager.default.temporaryDirectory.appendingPathComponent("textream-remote-\(getpid())")
try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
let pageJS = dir.appendingPathComponent("page.js"), harnessJS = dir.appendingPathComponent("harness.js")
try! script.write(to: pageJS, atomically: true, encoding: .utf8)
try! harnessSource().write(to: harnessJS, atomically: true, encoding: .utf8)
func node(_ args: [String]) -> Int32 {
    fflush(stdout)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = ["node"] + args
    do { try p.run() } catch { return 127 }
    p.waitUntilExit()
    return p.terminationStatus
}
let syntax = node(["--check", pageJS.path])
if syntax == 127 {
    print("  skip page script checks (node not found)")
} else {
    check("page script parses (node --check)", syntax == 0)
    check("page script behaviour (node harness)", node([harnessJS.path, pageJS.path]) == 0)
}
try? FileManager.default.removeItem(at: dir)

if fails > 0 { print("\(fails) failed"); exit(1) }

// The node harness. It runs the page script with fake timers, media and storage.
func harnessSource() -> String {
    #"""
// Behaviour checks for the Remote page script. Usage: node harness.js page.js
// Runs the real script against a small fake DOM, fake timers and fake media.
const fs = require('fs'), vm = require('vm');
const src = fs.readFileSync(process.argv[2], 'utf8');
let fails = 0;
function check(name, ok) { console.log((ok ? '  pass ' : '  FAIL ') + name); if (!ok) fails++; }
const flush = () => new Promise(r => setImmediate(r));

function makePage(opts = {}) {
  let now = 0, timers = [], tid = 0, gesture = false;
  const setT = (fn, ms) => { const id = ++tid; timers.push({ id, at: now + ms, fn }); return id; };
  const clearT = id => { timers = timers.filter(t => t.id !== id); };
  const docListeners = {};
  const page = { scrolls: [], playLog: [] };
  class El {
    constructor(tag, id) {
      this.tagName = tag; this.id = id || ''; this.children = []; this.dataset = {};
      this.style = { setProperty() {} }; this.listeners = {}; this.cls = new Set(); this.textContent = '';
      const self = this;
      this.classList = { toggle(c, on) { if (on) self.cls.add(c); else self.cls.delete(c); }, contains: c => self.cls.has(c) };
    }
    set innerHTML(v) { this.children = []; }
    appendChild(c) { this.children.push(c); c.parent = this; return c; }
    addEventListener(t, fn) { (this.listeners[t] = this.listeners[t] || []).push(fn); }
    dispatch(t) { (this.listeners[t] || []).forEach(fn => fn({})); }
    setAttribute(k, v) { this[k] = v === '' ? true : v; }
    getBoundingClientRect() { return opts.rect ? opts.rect(this) : { top: 0, bottom: 0, height: 0 }; }
    scrollIntoView() { page.scrolls.push(this); }
  }
  // Media that acts like WebKit: play() needs a tap until one play() ran in a tap.
  class Video extends El {
    constructor() { super('video'); this.paused = true; this.currentTime = 0; this.unlocked = false; }
    play() {
      page.playLog.push(gesture);
      if (gesture) this.unlocked = true;
      if (!this.unlocked) return Promise.reject(new Error('NotAllowedError'));
      this.paused = false; return Promise.resolve();
    }
    pause() { this.paused = true; }
  }
  const els = {};
  const document = {
    visibilityState: 'visible', body: new El('body'), documentElement: new El('html'),
    getElementById: id => els[id] || (els[id] = new El('div', id)),
    createElement: t => (t === 'video' ? new Video() : new El(t)),
    addEventListener(t, fn) { (docListeners[t] = docListeners[t] || []).push(fn); },
  };
  const store = new Map(Object.entries(opts.stored || {}));
  const localStorage = opts.noStorage
    ? { getItem() { throw new Error('denied'); }, setItem() { throw new Error('denied'); } }
    : { getItem: k => (store.has(k) ? store.get(k) : null), setItem: (k, v) => store.set(k, String(v)) };
  const sockets = [];
  class WebSocket { constructor(u) { this.url = u; sockets.push(this); } close() { this.closed = true; if (this.onclose) this.onclose(); } }
  const ctx = {
    document, localStorage, WebSocket, console, URLSearchParams,
    location: { search: opts.search || '', hostname: 'mac.local' },
    navigator: opts.navigator || {}, setTimeout: setT, clearTimeout: clearT,
  };
  vm.createContext(ctx);
  vm.runInContext(src + '\n;globalThis.__t={render,get sizeIdx(){return sizeIdx},get widthIdx(){return widthIdx}};', ctx);
  Object.assign(page, {
    els, document, store, sockets, t: ctx.__t,
    get video() { return document.body.children.find(c => c instanceof Video); },
    advance(ms) {
      const end = now + ms;
      for (;;) {
        timers.sort((a, b) => a.at - b.at);
        const t = timers[0];
        if (!t || t.at > end) break;
        timers.shift(); now = t.at; t.fn();
      }
      now = end;
    },
    tap() {
      gesture = true;
      try { for (const t of ['touchend', 'click']) (docListeners[t] || []).forEach(fn => fn({})); }
      finally { gesture = false; }
    },
    fire(t) { (docListeners[t] || []).forEach(fn => fn({})); },
    // A tap on plain text: iOS can send touchend with no click.
    touch() { gesture = true; try { (docListeners.touchend || []).forEach(fn => fn({})); } finally { gesture = false; } },
  });
  return page;
}

const MIN = 60 * 1000;
const words = Array.from({ length: 40 }, () => 'abc');   // word k starts at 4k
const active = (hcc, extra = {}) => Object.assign({ isActive: true, isDone: false, words, highlightedCharCount: hcc,
  totalCharCount: 159, audioLevels: [], fontColor: '#ffffff', cueColor: '#ffffff', highlightWords: true }, extra);
const inactive = { isActive: false, isDone: false, words: [], highlightedCharCount: 0, totalCharCount: 0, audioLevels: [] };
// States at 10 Hz for ms, as the Mac sends them during a session.
function frames(p, ms, state) { for (let i = 0; i * 100 < ms; i++) { p.t.render(state(i)); p.advance(100); } }

(async () => {
  // ---- Text size and column width presets ----
  let p = makePage();
  check('defaults are S and 50%', p.t.sizeIdx === 1 && p.t.widthIdx === 3);
  check('labels show S and 50%', p.els['size-label'].textContent === 'S' && p.els['width-label'].textContent === '50%');
  check('no "on" highlight at the defaults', !p.els['size-btn'].cls.has('on') && !p.els['width-btn'].cls.has('on'));
  check('defaults are not saved', p.store.size === 0);

  p = makePage({ search: '?size=l&width=65' });
  check('valid presets are used', p.t.sizeIdx === 3 && p.t.widthIdx === 2);
  check('valid presets are saved', p.store.get('textream.remote.size') === 'L' && p.store.get('textream.remote.width') === '65');
  check('"on" highlight away from the defaults', p.els['size-btn'].cls.has('on') && p.els['width-btn'].cls.has('on'));

  const saved = { 'textream.remote.size': 'XL', 'textream.remote.width': '35' };
  p = makePage({ search: '?size=XXL&width=60', stored: saved });
  check('invalid presets use the saved values', p.t.sizeIdx === 4 && p.t.widthIdx === 4);
  check('invalid presets are not saved', p.store.get('textream.remote.size') === 'XL' && p.store.get('textream.remote.width') === '35');
  p = makePage({ search: '?size=XXL&width=60' });
  check('invalid presets with nothing saved use the defaults', p.t.sizeIdx === 1 && p.t.widthIdx === 3);
  p = makePage({ stored: saved });
  check('saved values are used with no preset', p.t.sizeIdx === 4 && p.t.widthIdx === 4);
  p = makePage({ search: '?size=L&width=80', noStorage: true });
  check('presets work without storage', p.t.sizeIdx === 3 && p.t.widthIdx === 1);
  p = makePage({ noStorage: true });
  check('defaults without storage', p.t.sizeIdx === 1 && p.t.widthIdx === 3);
  p = makePage();
  p.els['size-btn'].dispatch('click'); p.els['width-btn'].dispatch('click');
  check('a tap steps and saves size', p.t.sizeIdx === 2 && p.store.get('textream.remote.size') === 'M');
  check('a tap steps and saves width', p.t.widthIdx === 4 && p.store.get('textream.remote.width') === '35');
  check('M and 35% are "on" (not the defaults)', p.els['size-btn'].cls.has('on') && p.els['width-btn'].cls.has('on'));

  // ---- Keep-awake: video fallback (no navigator.wakeLock) ----
  p = makePage();
  let v = p.video;
  check('video is in the body', !!v && v.parent === p.document.body);
  check('video is not muted, not looped, no autoplay', !v.muted && !v.loop && !v.autoplay && v.volume === undefined);
  check('video plays inline', v.playsinline === true);
  check('video is a data MP4', String(v.src).startsWith('data:video/mp4;base64,'));
  const clip = Buffer.from(String(v.src).split(',')[1], 'base64');
  check('clip has a video and an audio track', clip.includes('avc1') && clip.includes('mp4a'));
  check('no play() at load succeeds without a tap', v.paused === true);
  p.tap();
  check('first tap calls play() inside the tap', p.playLog[p.playLog.length - 1] === true && !v.paused);
  v.currentTime = 1.2; v.dispatch('timeupdate');
  check('timeupdate seeks back before the end', v.currentTime < 1);
  p.advance(9 * MIN);
  check('awake during the 10 minute grace period', !v.paused);
  p.advance(1 * MIN + 1);
  check('released after 10 minutes with no session', v.paused);
  p.t.render(active(0));
  check('session start plays again with no tap', !v.paused && p.playLog[p.playLog.length - 1] === false);
  const plays = p.playLog.length;
  frames(p, 30 * MIN, i => active(4 * (i % 30)));
  check('10 Hz renders do not call play() again', p.playLog.length === plays);
  check('awake for a long session', !v.paused);
  frames(p, 30 * MIN, () => active(159, { isDone: true }));
  check('awake on the Done screen (session goes on)', !v.paused);
  p.t.render(inactive);
  p.advance(9 * MIN);
  check('awake 9 minutes after the session stops', !v.paused);
  p.advance(1 * MIN + 1);
  check('released 10 minutes after the session stops', v.paused);
  p.t.render(active(0));
  p.sockets[p.sockets.length - 1].close();
  p.advance(9 * MIN);
  check('socket loss in a session keeps the screen awake', !v.paused);
  p.advance(1 * MIN + 1);
  check('released 10 minutes after the socket loss', v.paused);
  p.t.render(active(0));
  v.pause();   // iOS paused it, for example another app took the audio
  p.tap();
  check('a tap restarts a clip that iOS paused', !v.paused && p.playLog[p.playLog.length - 1] === true);
  v.pause();
  p.fire('visibilitychange');
  check('returning to the page restarts the clip', !v.paused);
  p = makePage();
  p.touch();
  check('a touchend alone starts the clip', !p.video.paused && p.playLog[p.playLog.length - 1] === true);

  // ---- A Mac that goes silent in a session (lid closed, network lost) ----
  const sock = () => p.sockets[p.sockets.length - 1];
  const send = s => sock().onmessage({ data: JSON.stringify(s) });
  p = makePage();
  p.tap();
  for (let i = 0; i < 600; i++) { send(active(4 * (i % 30))); p.advance(100); }
  const first = sock();
  check('states through the socket keep one connection', p.sockets.length === 1 && !first.closed);
  p.advance(4800);   // 4.9 s since the last state
  check('4.9 s of silence keeps the socket', !first.closed && first.onmessage !== null);
  p.advance(200);
  check('5 s of silence closes the socket and ignores its events',
    first.closed === true && first.onmessage === null && first.onclose === null && first.onerror === null);
  p.advance(1500);
  check('then the page connects again', p.sockets.length === 2);
  p.advance(9 * MIN);
  check('awake 9 minutes after the Mac goes silent', !p.video.paused);
  p.advance(1 * MIN);
  check('released 10 minutes after the Mac goes silent', p.video.paused);
  send(active(8));
  check('a state on the new socket starts the session again', !p.video.paused);
  send(inactive);
  p.advance(60 * MIN);
  check('silence while the Mac is idle does not reconnect', p.sockets.length === 2 && p.video.paused);
  p = makePage();
  send(active(0));
  sock().close();   // a normal close in a session
  p.advance(1500);
  check('a closed socket connects again once', p.sockets.length === 2);
  p.advance(10 * 1000);
  check('a close stops the silence timer', p.sockets.length === 2 && !sock().closed);

  // ---- Keep-awake: native Screen Wake Lock ----
  function fakeWakeLock() {
    const wl = { requests: 0, releases: 0, hold: false, waiting: [] };
    wl.request = () => {
      wl.requests++;
      const s = { released: false, release() { wl.releases++; s.released = true; return Promise.resolve(); } };
      wl.last = s;
      return new Promise(res => { if (wl.hold) wl.waiting.push(() => res(s)); else res(s); });
    };
    return wl;
  }
  let wl = fakeWakeLock();
  p = makePage({ navigator: { wakeLock: wl } });
  await flush();
  check('no video when WakeLock exists', !p.video);
  check('one lock request at load', wl.requests === 1);
  p.t.render(active(0));
  for (let i = 0; i < 50; i++) p.t.render(active(4 * (i % 30)));
  await flush();
  check('renders do not request again', wl.requests === 1 && wl.releases === 0);
  p.t.render(inactive);
  p.advance(10 * MIN + 1);
  await flush();
  check('lock released when the grace period ends', wl.releases === 1);
  p.t.render(active(0));
  await flush();
  check('lock taken again when a session starts', wl.requests === 2);
  p.t.render(inactive);
  p.advance(10 * MIN + 1);
  await flush();
  wl.hold = true;
  p.t.render(active(0));            // request pending
  p.t.render(inactive);
  p.advance(10 * MIN + 1);          // want goes off while the request waits
  const late = wl.waiting.shift();
  if (late) late();
  await flush();
  check('a late lock is released at once', wl.requests === 3 && wl.releases === 3);
  wl.hold = false;
  wl = fakeWakeLock();
  p = makePage({ navigator: { wakeLock: wl } });
  await flush();
  if (wl.last) wl.last.released = true;   // the browser drops the lock when the page is hidden
  p.document.visibilityState = 'hidden';
  p.fire('visibilitychange');
  await flush();
  check('no request while hidden', wl.requests === 1);
  p.document.visibilityState = 'visible';
  p.fire('visibilitychange');
  await flush();
  check('lock taken again when the page shows', wl.requests === 2);
  p.t.render(active(0));
  p.tap();
  await flush();
  check('a live lock is not requested again', wl.requests === 2);
  p.t.render(inactive);
  p.advance(10 * MIN + 1);
  await flush();
  p.tap();
  await flush();
  check('a tap takes the lock again after the grace period', wl.requests === 3 && wl.releases === 1);
  wl = fakeWakeLock();
  p = makePage({ navigator: { wakeLock: wl } });
  await flush();
  send(active(0));
  p.advance(5000 + 10 * MIN - 1);
  await flush();
  check('native: lock held until 10 minutes after the Mac goes silent', wl.releases === 0);
  p.advance(1);
  await flush();
  check('native: lock released 10 minutes after the Mac goes silent', wl.requests === 1 && wl.releases === 1);

  // ---- Backward scroll ----
  const rects = new Map();
  const prompterRect = { top: 0, bottom: 309, height: 309 };   // mid = 123.6
  p = makePage({ rect: el => (el.id === 'prompter' ? prompterRect
    : rects.get(el.parent ? el.parent.children.indexOf(el) : -1) || { top: 150, bottom: 218, height: 68 }) });
  p.t.render(active(4 * 20));
  const n0 = p.scrolls.length;
  rects.set(20, { top: 150, bottom: 218, height: 68 });
  p.t.render(active(4 * 20 + 1));
  check('forward reading in the band does not scroll', p.scrolls.length === n0);
  rects.set(12, { top: -16, bottom: 52, height: 68 });
  p.t.render(active(4 * 12));
  check('backward move to a line under the top edge scrolls', p.scrolls.length === n0 + 1);
  p.t.render(active(4 * 12));
  check('no repeat scroll on the next frame', p.scrolls.length === n0 + 1);
  rects.set(11, { top: 100, bottom: 168, height: 68 });
  p.t.render(active(4 * 11));
  check('small backward move near the centre does not scroll', p.scrolls.length === n0 + 1);
  const other = Array.from({ length: 41 }, () => 'xyz');
  rects.set(0, { top: 20, bottom: 88, height: 68 });
  p.t.render(active(0, { words: other, totalCharCount: 163 }));
  check('new page does not count as a backward move', p.scrolls.length === n0 + 1);

  // ---- The inactive state (the server sends it to each new client) ----
  p = makePage();
  p.t.render(active(8));
  p.t.render(inactive);
  check('inactive state shows the waiting screen', p.els['waiting'].style.display === 'flex' && p.els['main'].style.display === 'none');

  if (fails) { console.log(fails + ' failed'); process.exit(1); }
})().catch(e => { console.log('  FAIL harness error: ' + (e && e.stack || e)); process.exit(1); });
"""#
}
