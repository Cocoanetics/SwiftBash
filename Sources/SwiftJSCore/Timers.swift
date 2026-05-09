#if !os(Windows)

import Foundation

extension JSRuntime {

    /// Wires up setTimeout/setInterval/clearTimeout/clearInterval +
    /// setImmediate. All callbacks are dispatched onto the main queue
    /// so they're picked up by the runloop drain in `JSRuntime.run`.
    func installTimers() {
        let setTimeoutImpl = block { [weak self] args in
            guard let self, args.count >= 1 else { return 0 }
            let ms = args.count >= 2 ? args[1].toNumber() : 0
            return self.scheduleTimer(callback: args[0], delayMs: ms,
                                      repeating: false)
        }
        setGlobal("setTimeout", setTimeoutImpl)

        let setIntervalImpl = block { [weak self] args in
            guard let self, args.count >= 1 else { return 0 }
            let ms = args.count >= 2 ? args[1].toNumber() : 0
            return self.scheduleTimer(callback: args[0], delayMs: ms,
                                      repeating: true)
        }
        setGlobal("setInterval", setIntervalImpl)

        let clearImpl = block { [weak self] args in
            guard let self, let id = args.first.map({ Int($0.toInt32()) })
            else { return Optional<Any>.none as Any }
            if let timer = self.pendingTimers.removeValue(forKey: id) {
                timer.cancel()
            }
            return nil
        }
        setGlobal("clearTimeout", clearImpl)
        setGlobal("clearInterval", clearImpl)

        // setImmediate ≈ setTimeout(fn, 0) for our purposes.
        let setImmediateImpl = block { [weak self] args in
            guard let self, args.count >= 1 else { return 0 }
            return self.scheduleTimer(callback: args[0], delayMs: 0,
                                      repeating: false)
        }
        setGlobal("setImmediate", setImmediateImpl)
        setGlobal("clearImmediate", clearImpl)
    }

    private func scheduleTimer(callback: JSValue, delayMs: Double,
                               repeating: Bool) -> Int {
        let id = nextTimerID
        nextTimerID += 1

        let timer = DispatchSource.makeTimerSource(queue: .main)
        let leeway = DispatchTimeInterval.milliseconds(1)
        if repeating {
            timer.schedule(
                deadline: .now() + .milliseconds(Int(max(0, delayMs))),
                repeating: .milliseconds(Int(max(1, delayMs))),
                leeway: leeway)
        } else {
            timer.schedule(
                deadline: .now() + .milliseconds(Int(max(0, delayMs))),
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
#endif  // !os(Windows)
