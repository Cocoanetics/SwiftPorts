/// What a sandboxed shell may reach beyond its root, set by the embedder.
public enum GitSandboxPolicy {
    /// Whether git commands in a sandbox read the host's system gitconfig
    /// (`/etc/gitconfig`, or what `GIT_CONFIG_SYSTEM` names). Off by default;
    /// `GIT_CONFIG_NOSYSTEM=1` still leaves it out. Bind it around the
    /// commands that should read it. No effect without a sandbox.
    @TaskLocal public static var allowsHostSystemConfig = false
}
