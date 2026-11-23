import ArgumentParser

struct ReleaseCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "release",
        abstract: "Manage releases.",
        subcommands: [
            ReleaseList.self,
            ReleaseView.self,
            ReleaseDownload.self,
            ReleaseCreate.self,
            ReleaseEdit.self,
            ReleaseDelete.self,
        ]
    )
}
