/// The lock fields consumed by `commands.lockVerifier` (git-lfs 3.7.1).
struct LFSVerifiedLock: Decodable {
    let path: String
    let owner: LFSLockOwner?
}
