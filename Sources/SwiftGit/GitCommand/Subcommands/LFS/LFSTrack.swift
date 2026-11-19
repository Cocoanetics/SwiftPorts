import ArgumentParser
import GitLFSKit

struct LFSTrack: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "track", abstract: "View or add Git LFS paths.")
    @Flag(name: [.customShort("l"), .long]) var lockable = false
    @Flag(name: .customLong("not-lockable")) var notLockable = false
    @Flag(name: [.customShort("d"), .customLong("dry-run")]) var dryRun = false
    @Flag(name: [.customShort("v"), .long]) var verbose = false
    @Flag var json = false
    @Flag(name: .customLong("no-excluded")) var noExcluded = false
    @Flag var filename = false
    @Flag(name: .customLong("no-modify-attrs")) var noModifyAttrs = false
    @Argument var patterns: [String] = []

    func run() async throws {
        var options = TrackOptions()
        options.lockable = lockable
        options.notLockable = notLockable
        options.dryRun = dryRun
        options.verbose = verbose
        options.json = json
        options.noExcluded = noExcluded
        options.filename = filename
        options.noModifyAttrs = noModifyAttrs
        try LFSCommand.emit(try await options.track(patterns, client: CommandContext.gitClient()))
    }
}
