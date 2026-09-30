import AppKit
import WebKit
import CryptoKit
import BobbCore

/// A local WebKit computer with a separate cookie store for each Bobb.
/// DOM work happens in an isolated JavaScript world and never posts CGEvents.
@MainActor
final class WebComputer: NSObject, TaskDriver, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    var boundaries: () -> BoundaryConfiguration
    private let world = WKContentWorld.world(name: "app.bobb.driver")
    private var window: NSWindow?
    private var expected: [Int: String] = [:]
    private var lastError = ""

    init(agentId: String, boundaries: @escaping () -> BoundaryConfiguration) {
        self.boundaries = boundaries
        let hash = SHA256.hash(data: Data(agentId.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        let chars = Array(hash)
        let uuid = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { String(chars[$0]) }.joined(separator: "-")
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: UUID(uuidString: uuid)!)
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 850), configuration: configuration)
        super.init()
        webView.navigationDelegate = self; webView.uiDelegate = self
    }

    func open(_ url: URL) -> Bool {
        guard permits(url) else { lastError = "Connect this website in Boundaries first."; return false }
        lastError = ""; webView.load(URLRequest(url: url)); return true
    }

    private func permits(_ url: URL) -> Bool {
        guard ["https", "http", "about"].contains(url.scheme ?? "") else { return false }
        if url.absoluteString == "about:blank" { return true }
        guard let host = url.host, url.user == nil, url.password == nil else { return false }
        let config = boundaries()
        return config.app(bundleId: "bobb.browser", name: "Bobb Browser") != nil
            || config.app(bundleId: "web:\(host)", name: host) != nil
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, permits(url), !navigationAction.shouldPerformDownload else {
            lastError = "This navigation or download is outside the connected websites."
            decisionHandler(.cancel); return
        }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url, permits(url) { webView.load(URLRequest(url: url)) }
        return nil
    }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) { completionHandler() }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        // A page cannot approve its own confirm dialog in the background.
        lastError = "Open Bobb's browser to review the website confirmation."; completionHandler(false)
    }

    func inspect() {
        if window == nil {
            let w = NSWindow(contentRect: webView.frame, styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "Bobb Browser"; w.isReleasedWhenClosed = false; w.contentView = webView; window = w
        }
        window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func installedApps() -> [String] { [] }
    func offeredKeys(for observation: ScreenObservation) -> [KeyChord] { [.tab, .shiftTab, .returnKey, .escape, .down, .up] }

    private func js(_ script: String) async -> Any? {
        try? await webView.evaluateJavaScript(script, in: nil, in: world)
    }
    private static func quoted(_ string: String) -> String {
        String(decoding: (try? JSONEncoder().encode(string)) ?? Data("\"\"".utf8), as: UTF8.self)
    }

    func observe() async -> ScreenObservation? {
        guard let url = webView.url else {
            return ScreenObservation(app: "Bobb Browser", bundleId: "bobb.browser", window: "", elements: [], screenText: lastError)
        }
        let script = #"""
        (() => {
          const nodes = []; const entries = new Map(); let counter = 0;
          const label = e => (e.getAttribute('aria-label') || (e.labels && [...e.labels].map(l=>l.innerText).join(' ')) || e.getAttribute('placeholder') || e.innerText || e.getAttribute('title') || e.name || e.tagName).trim().slice(0,180);
          const secure = e => e.type === 'password' || /password|one-time-code|cc-number|cc-csc/.test(e.autocomplete || '');
          const signature = e => JSON.stringify([e.tagName,e.type,label(e),e.getAttribute('href'),e.getAttribute('formaction'),e.disabled]);
          function walk(root) {
            for (const e of root.querySelectorAll('*')) {
              if (e.shadowRoot) walk(e.shadowRoot);
              const r = e.getBoundingClientRect();
              if (r.width < 1 || r.height < 1 || r.bottom < 0 || r.top > innerHeight || getComputedStyle(e).visibility === 'hidden' || secure(e)) continue;
              const text = e.matches('input:not([type=hidden]):not([type=button]):not([type=submit]):not([type=checkbox]):not([type=radio]),textarea,[contenteditable=true],select');
              const press = e.matches('button,a[href],input[type=submit],input[type=button],input[type=checkbox],input[type=radio],[role=button],[role=link],[role=tab],[role=checkbox],summary');
              if (!text && !press) continue;
              if (counter >= 500) break;
              const key = ++counter; entries.set(key,e);
              nodes.push({key,role:text?(e.tagName==='TEXTAREA'||e.isContentEditable?'AXTextArea':'AXTextField'):'AXButton',title:label(e),value:text?(e.value||e.innerText||'').slice(0,1500):'',enabled:!e.disabled,focused:e===document.activeElement,signature:signature(e),kind:text?'text':'press'});
            }
          }
          walk(document); window.__bobb = {entries,signature,secure};
          nodes.push({key:0,role:'AXScrollArea',title:'Page',value:'',enabled:true,focused:false,signature:'page',kind:'scroll'});
          const active = document.activeElement;
          const button = active && active.form && active.form.querySelector('button[type=submit],input[type=submit],button:not([type])');
          return {nodes,text:(document.body?.innerText||'').slice(0,16000),defaultButton:button?label(button):'',title:document.title};
        })()
        """#
        guard let result = await js(script) as? [String: Any], let raw = result["nodes"] as? [[String: Any]] else { return nil }
        expected = [:]
        let elements = raw.compactMap { row -> UIElementSnapshot? in
            guard let key = row["key"] as? Int, let role = row["role"] as? String, let signature = row["signature"] as? String else { return nil }
            expected[key] = signature
            return UIElementSnapshot(key: key, role: role, title: row["title"] as? String ?? "", value: row["value"] as? String ?? "",
                enabled: row["enabled"] as? Bool ?? true, focused: row["focused"] as? Bool ?? false,
                actions: role == "AXScrollArea" ? [] : ["AXPress"], valueSettable: row["kind"] as? String == "text")
        }
        let host = url.host ?? ""
        let specific = boundaries().app(bundleId: "web:\(host)", name: host) != nil
        return ScreenObservation(app: specific ? host : "Bobb Browser", bundleId: specific ? "web:\(host)" : "bobb.browser",
                window: url.absoluteString, elements: elements, screenText: (result["text"] as? String ?? "") + "\n" + lastError,
                defaultButton: result["defaultButton"] as? String ?? "")
    }

    func perform(_ action: DriverAction) async -> DriverResult {
        guard let url = webView.url, permits(url), boundaries().canWork() else { return .failed("boundariesChanged") }
        var script: String
        switch action {
        case .openApp: return .failed("Use the desktop for applications.")
        case .scroll(_, let down): script = "window.scrollBy(0,\(down ? 600 : -600)); 'ok'"
        case .key(let key):
            // All keys stay inside the page. Return submits only an actual
            // form; arbitrary synthetic keyboard handlers are not invoked.
            if key == .returnKey {
                script = "(() => {const e=document.activeElement;if(e?.form){e.form.requestSubmit();return 'ok'}return 'stale'})()"
            } else if key == .tab || key == .shiftTab {
                script = "(() => {const a=[...document.querySelectorAll('input,button,a[href],textarea,select,[tabindex]')].filter(e=>!e.disabled && e.getClientRects().length);const i=a.indexOf(document.activeElement);a[(i+\(key == .tab ? 1 : -1)+a.length)%a.length]?.focus();return 'ok'})()"
            } else if key == .down || key == .up { script = "window.scrollBy(0,\(key == .down ? 120 : -120)); 'ok'" }
            else { return .failed("unsupportedKey") }
        case .press(let key), .open(let key):
            guard let signature = expected[key] else { return .stale }
            script = "(() => {const s=window.__bobb,e=s?.entries.get(\(key));if(!e?.isConnected||e.disabled||s.secure(e)||s.signature(e)!==\(Self.quoted(signature)))return 'stale';e.click();return 'ok'})()"
        case .type(let key, let text, let submit):
            guard let signature = expected[key] else { return .stale }
            script = """
            (() => {const s=window.__bobb,e=s?.entries.get(\(key));if(!e?.isConnected||e.disabled||s.secure(e)||s.signature(e)!==\(Self.quoted(signature)))return 'stale';
            e.focus();const v=\(Self.quoted(text));if(e.isContentEditable)e.textContent=v;else {
              const proto=e.tagName==='TEXTAREA'?HTMLTextAreaElement.prototype:e.tagName==='SELECT'?HTMLSelectElement.prototype:HTMLInputElement.prototype;
              Object.getOwnPropertyDescriptor(proto,'value').set.call(e,v);
            }e.dispatchEvent(new Event('input',{bubbles:true}));e.dispatchEvent(new Event('change',{bubbles:true}));
            if(\(submit ? "true" : "false")){if(!e.form)return 'stale';e.form.requestSubmit();}return 'ok';})()
            """
        }
        guard let result = await js(script) as? String else { return .failed("websiteDidNotRespond") }
        return result == "ok" ? .ok : .stale
    }
    func settle() async {
        for _ in 0..<20 {
            if !webView.isLoading { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        try? await Task.sleep(for: .milliseconds(250))
    }
    func undoLast() async -> Bool {
        if webView.canGoBack { webView.goBack(); return true }
        return false
    }
}
