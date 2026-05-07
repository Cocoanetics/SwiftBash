import Foundation

#if canImport(JavaScriptCore)

import JavaScriptCore

/// Mutable holder for the resolve/reject handles of a Promise, used
/// so the URLSession callback (non-isolated) can post the JSValues
/// back to the main thread without capturing them in its closure.
/// JSValue is not Sendable; PromiseHandles is `@unchecked` because
/// access is fenced by the main-queue hop.
private final class PromiseHandles: @unchecked Sendable {
    var resolve: JSValue?
    var reject: JSValue?
}

extension JSRuntime {

    /// Wires up a Node/web-style `fetch(url, init?) → Promise<Response>`
    /// backed by URLSession.
    ///
    /// Each in-flight request is counted as pending work alongside
    /// timers, so `JSRuntime.run` won't return until all fetches
    /// resolve. We piggy-back on the same `pendingTimers` drain
    /// loop by registering a sentinel timer that we cancel when the
    /// last network request completes — simpler than threading a
    /// second counter through.
    func installFetch() {
        // The JS-callable entry point. Returns a Promise.
        let fetchImpl: @convention(block) (JSValue, JSValue?) -> JSValue? = { [weak self] urlVal, initVal in
            guard let self else { return nil }
            return self.makeFetchPromise(urlVal: urlVal, initVal: initVal)
        }
        setGlobal("fetch", block(fetchImpl as AnyObject))

        // Headers, Response, Request — minimal JS shims so the
        // returned object behaves the way a script expects.
        let shim = #"""
        (() => {
          class Headers {
            constructor(init) {
              this._m = new Map();
              if (init) {
                if (init instanceof Headers) {
                  for (const [k, v] of init._m) this._m.set(k.toLowerCase(), v);
                } else if (Array.isArray(init)) {
                  for (const [k, v] of init) this._m.set(String(k).toLowerCase(), String(v));
                } else {
                  for (const k of Object.keys(init)) this._m.set(k.toLowerCase(), String(init[k]));
                }
              }
            }
            get(name) { return this._m.get(name.toLowerCase()) ?? null; }
            has(name) { return this._m.has(name.toLowerCase()); }
            set(name, value) { this._m.set(name.toLowerCase(), String(value)); }
            forEach(fn) { for (const [k, v] of this._m) fn(v, k, this); }
            entries() { return this._m.entries(); }
            keys()    { return this._m.keys(); }
            values()  { return this._m.values(); }
            [Symbol.iterator]() { return this._m.entries(); }
          }
          globalThis.Headers = Headers;
        })();
        """#
        context.evaluateScript(shim)
    }

    private func makeFetchPromise(urlVal: JSValue, initVal: JSValue?) -> JSValue? {
        // Build a Promise we control via Swift-side resolve/reject.
        // The resolve/reject handles are stashed in a Box so the
        // (non-isolated) URLSession callback can post them back to
        // the main thread without capturing them directly — JSValue
        // is not Sendable.
        let ctx = context
        let box = PromiseHandles()

        let handler: @convention(block) (JSValue, JSValue) -> Void = { resolve, reject in
            box.resolve = resolve
            box.reject = reject
        }
        let handlerJS = JSValue(object: block(handler as AnyObject), in: ctx)!
        let promiseClass = ctx.objectForKeyedSubscript("Promise")!
        let promise = promiseClass.construct(withArguments: [handlerJS])!

        // Parse arguments.
        let urlString = urlVal.toString() ?? ""
        guard let url = URL(string: urlString) else {
            box.reject?.call(withArguments: [
                JSValue(newErrorFromMessage: "Invalid URL: \(urlString)", in: ctx)!
            ])
            return promise
        }

        var request = URLRequest(url: url)
        var abortSignal: JSValue?
        if let initVal, initVal.isObject {
            if let m = initVal.objectForKeyedSubscript("method"), m.isString {
                request.httpMethod = m.toString()
            }
            if let h = initVal.objectForKeyedSubscript("headers"), h.isObject {
                if let dict = h.toDictionary() as? [String: Any] {
                    for (k, v) in dict {
                        request.setValue(String(describing: v), forHTTPHeaderField: k)
                    }
                }
            }
            if let b = initVal.objectForKeyedSubscript("body"), !b.isUndefined, !b.isNull {
                if b.isString {
                    request.httpBody = (b.toString() ?? "").data(using: .utf8)
                } else if let bytes = b.toArray() as? [NSNumber] {
                    request.httpBody = Data(bytes.map { $0.uint8Value })
                }
            }
            if let s = initVal.objectForKeyedSubscript("signal"), s.isObject {
                abortSignal = s
                // Already-aborted? Reject synchronously.
                if s.objectForKeyedSubscript("aborted").toBool() {
                    let reason = s.objectForKeyedSubscript("reason")
                    let err = (reason?.isObject == true)
                        ? reason!
                        : JSValue(newErrorFromMessage: "The operation was aborted.", in: ctx)!
                    box.reject?.call(withArguments: [err])
                    return promise
                }
            }
        }

        // Add a sentinel timer so `drainPendingWorkIfNeeded` keeps
        // the runloop alive while the request is in flight.
        let sentinelID = nextTimerID
        nextTimerID += 1
        let sentinel = DispatchSource.makeTimerSource(queue: .main)
        sentinel.schedule(deadline: .distantFuture)
        sentinel.setEventHandler {}
        pendingTimers[sentinelID] = sentinel
        sentinel.resume()

        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            _ = abortSignal // capture so it stays alive across the call
            // We're on URLSession's queue. Hop to main where JSValue
            // is safe to touch.
            let bytes = Array(data ?? Data())
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let headers = (response as? HTTPURLResponse)?.allHeaderFields ?? [:]
            let respondedURL = response?.url?.absoluteString ?? urlString
            let errorDesc = error?.localizedDescription
            DispatchQueue.main.async {
                guard let self else { return }
                if let s = self.pendingTimers.removeValue(forKey: sentinelID) {
                    s.cancel()
                }
                if let errorDesc {
                    box.reject?.call(withArguments: [
                        JSValue(newErrorFromMessage: errorDesc, in: self.context)!
                    ])
                    return
                }
                let respObj = self.makeResponseObject(
                    bytes: bytes, status: status,
                    headers: headers, url: respondedURL
                )
                box.resolve?.call(withArguments: [respObj])
            }
        }
        task.resume()

        // Wire up cancellation: when the JS AbortSignal fires, cancel
        // the URLSessionDataTask. We do this by registering a JS
        // listener that calls a Swift bridge.
        if let signal = abortSignal {
            let cancel: @convention(block) () -> Void = { [weak task] in
                task?.cancel()
            }
            let cancelJS = JSValue(object: block(cancel as AnyObject), in: ctx)!
            // signal.addEventListener("abort", cancelJS)
            _ = signal.invokeMethod("addEventListener",
                                    withArguments: ["abort", cancelJS])
        }

        return promise
    }

    private func makeResponseObject(
        bytes: [UInt8],
        status: Int,
        headers: [AnyHashable: Any],
        url: String
    ) -> JSValue {
        // Build a Response-shaped object in JS so methods on it (.text(),
        // .json(), .arrayBuffer()) return Promises and capture the
        // bytes by closure.
        let ctx = context
        let bytesValue = JSValue(object: bytes, in: ctx)!
        let headersDict = JSValue(newObjectIn: ctx)!
        for (k, v) in headers {
            headersDict.setObject(String(describing: v),
                                  forKeyedSubscript: String(describing: k) as NSString)
        }

        let factory = ctx.evaluateScript(#"""
        (function (bytes, status, headersDict, url) {
          const headers = new Headers(headersDict);
          const buf = Buffer.from(Array.from(bytes));
          return {
            ok: status >= 200 && status < 300,
            status,
            statusText: "",
            url,
            headers,
            redirected: false,
            type: "basic",
            body: buf,
            bodyUsed: false,
            text() { return Promise.resolve(buf.toString("utf-8")); },
            json() { return Promise.resolve(JSON.parse(buf.toString("utf-8"))); },
            arrayBuffer() {
              return Promise.resolve(buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.byteLength));
            },
            bytes() { return Promise.resolve(buf); },
            clone() { return this; },
          };
        })
        """#)!
        return factory.call(withArguments: [bytesValue, status, headersDict, url])!
    }
}
#endif
