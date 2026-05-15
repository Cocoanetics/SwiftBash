#if !os(Windows)

import Foundation
// swift-corelibs-foundation splits URLSession / URLRequest /
// HTTPURLResponse out into a separate module. Apple platforms
// have these in plain Foundation, so the conditional import is
// a no-op there.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import BashInterpreter

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
        let fetchImpl = block { [weak self] args in
            guard let self, let urlVal = args.first else { return nil }
            let initVal: JSValue? = args.count >= 2 ? args[1] : nil
            return self.makeFetchPromise(urlVal: urlVal, initVal: initVal)
        }
        setGlobal("fetch", fetchImpl)

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

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func makeFetchPromise(urlVal: JSValue, initVal: JSValue?) -> JSValue? {
        // Build a Promise we control via Swift-side resolve/reject.
        // The resolve/reject handles are stashed in a Box so the
        // (non-isolated) URLSession callback can post them back to
        // the main thread without capturing them directly — JSValue
        // is not Sendable.
        let ctx = context
        let box = PromiseHandles()

        let handlerJS = block { args in
            if args.count >= 2 {
                box.resolve = args[0]
                box.reject = args[1]
            }
            return nil
        }
        let promiseClass = ctx.objectForKeyedSubscript("Promise")!
        let promise = promiseClass.construct(withArguments: [handlerJS])!

        // Parse arguments.
        let urlString = urlVal.toString() ?? ""
        guard let url = URL(string: urlString) else {
            box.reject?.call(withArguments: [
                makeJSError(
                    "Invalid URL: \(urlString)",
                    in: ctx,
                    code: "ERR_INVALID_URL",
                    extras: ["input": urlString]
                )
            ])
            return promise
        }

        var request = URLRequest(url: url)
        var abortSignal: JSValue?
        var method = "GET"
        if let initVal, initVal.isObject {
            if let methodVal = initVal.objectForKeyedSubscript("method"), methodVal.isString {
                request.httpMethod = methodVal.toString()
                method = methodVal.toString() ?? "GET"
            }
            if let headersVal = initVal.objectForKeyedSubscript("headers"), headersVal.isObject {
                // `toDictionary()` already returns `[String: Any]?`,
                // so the `as? [String: Any]` was a no-op cast that
                // tripped a "conditional downcast does nothing"
                // warning under Swift 6.
                if let dict = headersVal.toDictionary() {
                    for (key, value) in dict {
                        request.setValue(String(describing: value),
                                         forHTTPHeaderField: key)
                    }
                }
            }
            if let bodyVal = initVal.objectForKeyedSubscript("body"),
               !bodyVal.isUndefined, !bodyVal.isNull {
                if bodyVal.isString {
                    request.httpBody = (bodyVal.toString() ?? "").data(using: .utf8)
                } else if let bytes = bodyVal.toArray() as? [NSNumber] {
                    request.httpBody = Data(bytes.map { $0.uint8Value })
                }
            }
            if let signalVal = initVal.objectForKeyedSubscript("signal"), signalVal.isObject {
                abortSignal = signalVal
                // Already-aborted? Reject synchronously.
                if signalVal.objectForKeyedSubscript("aborted").toBool() {
                    let reason = signalVal.objectForKeyedSubscript("reason")
                    let err = (reason?.isObject == true)
                        ? reason!
                        : makeJSError(
                            "The operation was aborted.",
                            in: ctx,
                            code: "ABORT_ERR"
                        )
                    box.reject?.call(withArguments: [err])
                    return promise
                }
            }
        }

        // Sandbox + network-allow-list gate. Run the async gate
        // synchronously so a denial rejects the Promise before we
        // open a socket. The gate is pure policy (URL allow-list +
        // method gate), no DNS, no TLS — sub-millisecond — so
        // blocking the JSC thread for it is fine.
        let gateMethod = method
        do {
            try awaitSync {
                try await authorizeURL(url, method: gateMethod)
            }
        } catch {
            box.reject?.call(withArguments: [
                makeNetworkDenialError(error, in: ctx, url: urlString)
            ])
            return promise
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

        // Bind `var abortSignal` into a local `let` so the
        // URLSession callback below can keep it alive without
        // capturing a `var` directly (Swift 6 strict concurrency
        // rejects that across the @Sendable boundary).
        let abortSignalRef = abortSignal
        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            _ = abortSignalRef // capture so it stays alive across the call
            // We're on URLSession's queue. Hop to main where JSValue
            // is safe to touch.
            let bytes = Array(data ?? Data())
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            // `[AnyHashable: Any]` from `allHeaderFields` is not
            // Sendable, so flatten to `[String: String]` here on
            // URLSession's queue before crossing the dispatch hop.
            let headers: [String: String] = {
                guard let http = response as? HTTPURLResponse
                else { return [:] }
                var out: [String: String] = [:]
                for (key, value) in http.allHeaderFields {
                    out[String(describing: key)] = String(describing: value)
                }
                return out
            }()
            let respondedURL = response?.url?.absoluteString ?? urlString
            let errorDesc = error?.localizedDescription
            let errorCode = Self.fetchErrorCode(error)
            let errnoText: Int? = {
                guard let urlError = error as? URLError else { return nil }
                return urlError.errorCode
            }()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let sentinel = self.pendingTimers.removeValue(forKey: sentinelID) {
                    sentinel.cancel()
                }
                if let errorDesc {
                    var extras: [String: Any] = [
                        "url": urlString
                    ]
                    if let errnoText { extras["errno"] = errnoText }
                    let isAbort = (errorCode == "ABORT_ERR")
                    let err = self.makeJSError(
                        isAbort ? "The operation was aborted." : errorDesc,
                        in: self.context,
                        code: errorCode,
                        extras: extras
                    )
                    if isAbort {
                        err.setObject("AbortError",
                                      forKeyedSubscript: "name" as NSString)
                    }
                    box.reject?.call(withArguments: [err])
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
            let cancelJS = block { [weak task] _ in
                task?.cancel()
                return nil
            }
            // signal.addEventListener("abort", cancelJS)
            _ = signal.invokeMethod("addEventListener",
                                    withArguments: ["abort", cancelJS])
        }

        return promise
    }

    // Map a URLError to the closest Node-style symbolic code so JS
    // `catch (e) { if (e.code === 'ENOTFOUND') ... }` matches the
    // shape user code expects. Falls back to `ERR_NETWORK` for
    // anything we don't have a more specific mapping for.
    // swiftlint:disable:next cyclomatic_complexity
    fileprivate static func fetchErrorCode(_ error: Error?) -> String? {
        guard let error else { return nil }
        guard let urlError = error as? URLError else { return "ERR_NETWORK" }
        switch urlError.code {
        case .cancelled:               return "ABORT_ERR"
        case .timedOut:                return "ETIMEDOUT"
        case .cannotFindHost:          return "ENOTFOUND"
        case .cannotConnectToHost:     return "ECONNREFUSED"
        case .networkConnectionLost:   return "ECONNRESET"
        case .notConnectedToInternet:  return "ENETDOWN"
        case .dnsLookupFailed:         return "EAI_AGAIN"
        case .badURL:                  return "ERR_INVALID_URL"
        case .unsupportedURL:          return "ERR_INVALID_URL"
        case .secureConnectionFailed:  return "ERR_TLS"
        case .serverCertificateUntrusted,
             .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid:
            return "CERT_HAS_EXPIRED"
        default:
            return "ERR_NETWORK"
        }
    }

    private func makeResponseObject(
        bytes: [UInt8],
        status: Int,
        headers: [String: String],
        url: String
    ) -> JSValue {
        // Build a Response-shaped object in JS so methods on it (.text(),
        // .json(), .arrayBuffer()) return Promises and capture the
        // bytes by closure.
        let ctx = context
        let bytesValue = JSValue(object: bytes, in: ctx)!
        let headersDict = JSValue(newObjectIn: ctx)!
        for (key, value) in headers {
            headersDict.setObject(value, forKeyedSubscript: key)
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
#endif  // !os(Windows)
