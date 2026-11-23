/// A sandbox authorization that returns normally even after cancellation,
/// so the native clean path must retain ownership of any resources it creates.
actor CancellationAuthorizationGate {
    private var entered = false
    private var finished = false
    private var entry: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?

    func suspend() async {
        entered = true
        entry?.resume()
        entry = nil
        await withCheckedContinuation { release = $0 }
    }

    func waitUntilEntered() async -> Bool {
        if !entered && !finished { await withCheckedContinuation { entry = $0 } }
        return entered
    }

    func finish() {
        finished = true
        entry?.resume()
        entry = nil
    }

    func resume() {
        release?.resume()
        release = nil
    }
}
