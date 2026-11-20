struct LFSTransferSettings: Sendable {
    let concurrency: Int
    let maxRetries: Int
    let maxRetryDelay: Int
    let batchSize: Int
    let maxVerifies: Int
    let rewrite: Bool

    init(_ config: LFSConfiguration) {
        func positive(_ key: String, _ fallback: Int) -> Int {
            let value = config.int(key, fallback: fallback)
            return value < 1 ? fallback : value
        }
        concurrency = positive("lfs.concurrenttransfers", 8)
        maxRetries = positive("lfs.transfer.maxretries", 8)
        maxRetryDelay = positive("lfs.transfer.maxretrydelay", 10)
        batchSize = positive("lfs.transfer.batchSize", 100)
        maxVerifies = max(3, config.int("lfs.transfer.maxverifies", fallback: 3))
        rewrite = LFSConfiguration.bool(config.get("lfs.transfer.enablehrefrewrite"), fallback: false)
    }
}
