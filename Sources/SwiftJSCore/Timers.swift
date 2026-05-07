import Foundation

#if canImport(JavaScriptCore)

import JavaScriptCore

extension JSRuntime {

    /// Wires up setTimeout/setInterval/clearTimeout/clearInterval +
    /// setImmediate. All callbacks are dispatched onto the main queue
    /// so they're picked up by the runloop drain in `JSRuntime.run`.
    func installTimers() {
        let setTimeoutImpl: @convention(block) (JSValue, Double) -> Int = { [weak self] cb, ms in
            guard let self else { return 0 }
            return self.scheduleTimer(callback: cb, delayMs: ms, repeating: false)
        }
        setGlobal("setTimeout", block(setTimeoutImpl as AnyObject))

        let setIntervalImpl: @convention(block) (JSValue, Double) -> Int = { [weak self] cb, ms in
            guard let self else { return 0 }
            return self.scheduleTimer(callback: cb, delayMs: ms, repeating: true)
        }
        setGlobal("setInterval", block(setIntervalImpl as AnyObject))

        let clearImpl: @convention(block) (Int) -> Void = { [weak self] id in
            guard let self else { return }
            if let timer = self.pendingTimers.removeValue(forKey: id) {
                timer.cancel()
            }
        }
        setGlobal("clearTimeout", block(clearImpl as AnyObject))
        setGlobal("clearInterval", block(clearImpl as AnyObject))

        // setImmediate ≈ setTimeout(fn, 0) for our purposes.
        let setImmediateImpl: @convention(block) (JSValue) -> Int = { [weak self] cb in
            guard let self else { return 0 }
            return self.scheduleTimer(callback: cb, delayMs: 0, repeating: false)
        }
        setGlobal("setImmediate", block(setImmediateImpl as AnyObject))
        setGlobal("clearImmediate", block(clearImpl as AnyObject))
    }

    private func scheduleTimer(callback: JSValue, delayMs: Double, repeating: Bool) -> Int {
        let id = nextTimerID
        nextTimerID += 1

        let timer = DispatchSource.makeTimerSource(queue: .main)
        let leeway = DispatchTimeInterval.milliseconds(1)
        if repeating {
            timer.schedule(deadline: .now() + .milliseconds(Int(max(0, delayMs))),
                           repeating: .milliseconds(Int(max(1, delayMs))),
                           leeway: leeway)
        } else {
            timer.schedule(deadline: .now() + .milliseconds(Int(max(0, delayMs))),
                           leeway: leeway)
        }
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            // Don't run the callback if it was cleared between
            // scheduling and firing.
            guard self.pendingTimers[id] != nil else { return }
            if !repeating {
                self.pendingTimers.removeValue(forKey: id)
                timer.cancel()
            }
            // Re-enter JS. JSC drains microtasks at the end of this
            // call automatically.
            callback.call(withArguments: [])
        }

        pendingTimers[id] = timer
        timer.resume()
        return id
    }
}
#endif
