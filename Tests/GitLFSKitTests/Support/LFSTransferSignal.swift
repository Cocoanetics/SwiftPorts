actor LFSTransferSignal {
    private var signalled = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if signalled { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func signal() {
        signalled = true
        let waiting = continuations
        continuations.removeAll()
        for continuation in waiting { continuation.resume() }
    }
}
