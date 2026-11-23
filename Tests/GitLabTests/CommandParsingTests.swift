#if !os(Android)  // argv-parsing test; ArgumentParser trips the Android explicit-module scanner
import ArgumentParser
import Foundation
import Testing
@testable import GlabCommand

/// Argv-only parsing tests for the issue + auth surface. No network.
@Suite struct CommandParsingTests {
    @Test func issueListAcceptsRepoFlag() throws {
        let cmd = try IssueList.parse(["--repo", "group/sub/repo"])
        #expect(cmd.repo?.pathSegments == ["group", "sub", "repo"])
    }

    @Test func issueListDefaultsToOpened() throws {
        let cmd = try IssueList.parse([])
        #expect(cmd.all == false)
        #expect(cmd.closed == false)
    }

    @Test func issueListLabelsRepeatable() throws {
        let cmd = try IssueList.parse(["-l", "bug", "-l", "needs-review"])
        #expect(cmd.labels == ["bug", "needs-review"])
    }

    @Test func issueListConfidentialAndJSON() throws {
        let cmd = try IssueList.parse(["-C", "--json"])
        #expect(cmd.confidential == true)
        #expect(cmd.json == true)
    }

    @Test func issueViewAcceptsURLArgument() throws {
        let cmd = try IssueView.parse([
            "https://gitlab.com/foo/bar/-/issues/9",
        ])
        #expect(cmd.issue == "https://gitlab.com/foo/bar/-/issues/9")
    }

    @Test func issueCreateRequiresTitle() {
        #expect(throws: (any Error).self) {
            _ = try IssueCreate.parse([])
        }
    }

    @Test func issueCreateLabelsAndAssignees() throws {
        let cmd = try IssueCreate.parse([
            "--title", "Bug",
            "-l", "ui", "-l", "ux",
            "-a", "alice", "-a", "bob",
        ])
        #expect(cmd.title == "Bug")
        #expect(cmd.labels == ["ui", "ux"])
        #expect(cmd.assignees == ["alice", "bob"])
    }

    @Test func issueUpdateAccepts() throws {
        let cmd = try IssueUpdate.parse([
            "12",
            "--title", "Better title",
            "-l", "needs-review",
            "-u", "bug",
            "-C",
            "--lock-discussion",
        ])
        #expect(cmd.title == "Better title")
        #expect(cmd.addLabels == ["needs-review"])
        #expect(cmd.removeLabels == ["bug"])
        #expect(cmd.confidential == true)
        #expect(cmd.lockDiscussion == true)
    }

    @Test func issueNoteRequiresMessage() {
        #expect(throws: (any Error).self) {
            _ = try IssueNote.parse(["1"])
        }
    }

    @Test func issueNoteAccepts() throws {
        let cmd = try IssueNote.parse(["1", "-m", "looking into it"])
        #expect(cmd.issue == "1")
        #expect(cmd.message == "looking into it")
    }

    @Test func issueCloseAccepts() throws {
        let cmd = try IssueClose.parse(["#42"])
        #expect(cmd.issue == "#42")
    }

    @Test func issueDeleteAccepts() throws {
        let cmd = try IssueDelete.parse(["7"])
        #expect(cmd.issue == "7")
    }

    @Test func authStatusHostnameOptional() throws {
        let withFlag = try AuthStatus.parse(["-h", "self.example.com"])
        #expect(withFlag.hostname == "self.example.com")
        let bare = try AuthStatus.parse([])
        #expect(bare.hostname == nil)
    }

    @Test func authLoginWithTokenFlag() throws {
        let cmd = try AuthLogin.parse(["--with-token"])
        #expect(cmd.withToken == true)
    }

    @Test func ciListAcceptsFilters() throws {
        let cmd = try CiList.parse([
            "-R", "labs/AgentCorp",
            "-s", "failed",
            "--ref", "main",
            "--source", "push",
            "-P", "10",
        ])
        #expect(cmd.repo?.fullPath == "labs/AgentCorp")
        #expect(cmd.status == "failed")
        #expect(cmd.ref == "main")
        #expect(cmd.source == "push")
        #expect(cmd.perPage == 10)
    }

    @Test func ciViewPipelineIDOptional() throws {
        let bare = try CiView.parse([])
        #expect(bare.pipelineId == nil)
        let withId = try CiView.parse(["1234"])
        #expect(withId.pipelineId == 1234)
    }

    @Test func ciTraceRequiresJob() {
        #expect(throws: (any Error).self) {
            _ = try CiTrace.parse([])
        }
    }

    @Test func ciTraceAcceptsJobNameOrID() throws {
        let byID = try CiTrace.parse(["123456"])
        #expect(byID.job == "123456")
        let byName = try CiTrace.parse(["lint"])
        #expect(byName.job == "lint")
    }

    @Test func ciStatusFlags() throws {
        let cmd = try CiStatus.parse(["--once", "-b", "main", "--poll-interval", "5"])
        #expect(cmd.once == true)
        #expect(cmd.branch == "main")
        #expect(cmd.pollInterval == 5)
    }

    @Test func ciRunVariablesRepeatable() throws {
        let cmd = try CiRun.parse([
            "-v", "FOO=bar",
            "-v", "BAZ=qux",
            "-b", "main",
        ])
        #expect(cmd.variables == ["FOO=bar", "BAZ=qux"])
        #expect(cmd.branch == "main")
    }

    @Test func ciRetryAndCancelAcceptID() throws {
        let r = try CiRetry.parse(["1234"])
        #expect(r.pipelineId == 1234)
        let c = try CiCancel.parse(["1234"])
        #expect(c.pipelineId == 1234)
    }

    // MARK: MR

    @Test func mrListAcceptsFilters() throws {
        let cmd = try MrList.parse([
            "-R", "labs/sandbox",
            "-l", "bug", "-l", "needs-review",
            "--source-branch", "feature/x",
            "--target-branch", "main",
            "--merged",
        ])
        #expect(cmd.repo?.fullPath == "labs/sandbox")
        #expect(cmd.labels == ["bug", "needs-review"])
        #expect(cmd.sourceBranch == "feature/x")
        #expect(cmd.targetBranch == "main")
        #expect(cmd.merged == true)
    }

    @Test func mrCreateRequiresTitle() {
        #expect(throws: (any Error).self) {
            _ = try MrCreate.parse([])
        }
    }

    @Test func mrCreateAccepts() throws {
        let cmd = try MrCreate.parse([
            "-t", "Add HELLO.md",
            "-d", "test body",
            "-s", "feature/hello",
            "-b", "main",
            "-l", "smoke",
            "--draft",
        ])
        #expect(cmd.title == "Add HELLO.md")
        #expect(cmd.sourceBranch == "feature/hello")
        #expect(cmd.targetBranch == "main")
        #expect(cmd.draft == true)
    }

    @Test func mrUpdateAcceptsDraftAndReady() throws {
        let d = try MrUpdate.parse(["1", "--draft"])
        #expect(d.draft == true)
        let r = try MrUpdate.parse(["1", "--ready"])
        #expect(r.ready == true)
    }

    @Test func mrMergeFlags() throws {
        let cmd = try MrMerge.parse([
            "1", "--squash", "--remove-source-branch",
            "--merge-commit-message", "merge msg",
        ])
        #expect(cmd.squash == true)
        #expect(cmd.removeSourceBranch == true)
        #expect(cmd.mergeCommitMessage == "merge msg")
    }

    @Test func mrCheckoutDefaults() throws {
        let cmd = try MrCheckout.parse(["1"])
        #expect(cmd.remote == "origin")
    }

    @Test func mrDiffWebFlag() throws {
        let cmd = try MrDiff.parse(["1", "-w"])
        #expect(cmd.web == true)
    }

    // MARK: Repo

    @Test func repoCreateAccepts() throws {
        let cmd = try RepoCreate.parse([
            "test-thing",
            "-h", "git.cocoanetics.com",
            "-g", "labs",
            "--visibility", "private",
            "--initialize-with-readme",
        ])
        #expect(cmd.name == "test-thing")
        #expect(cmd.hostname == "git.cocoanetics.com")
        #expect(cmd.group == "labs")
        #expect(cmd.visibility == "private")
        #expect(cmd.initializeWithReadme == true)
    }

    @Test func repoListGroupAndOwnedFlags() throws {
        let cmd = try RepoList.parse([
            "-g", "labs", "--owned", "-P", "50",
        ])
        #expect(cmd.group == "labs")
        #expect(cmd.owned == true)
        #expect(cmd.perPage == 50)
    }

    @Test func repoCloneArgsAndFlag() throws {
        let cmd = try RepoClone.parse(["labs/glab-sandbox", "/tmp/dest", "--https"])
        #expect(cmd.project.fullPath == "labs/glab-sandbox")
        #expect(cmd.directory == "/tmp/dest")
        #expect(cmd.https == true)
    }

    @Test func repoForkOptional() throws {
        let cmd = try RepoFork.parse(["src/repo", "-g", "labs"])
        #expect(cmd.project.fullPath == "src/repo")
        #expect(cmd.namespace == "labs")
    }

    @Test func repoDeleteRequiresYesOrConfirm() throws {
        let cmd = try RepoDelete.parse(["-R", "labs/x", "-y"])
        #expect(cmd.yes == true)
    }

    // MARK: Board

    @Test func boardListAccepts() throws {
        let cmd = try IssueBoardList.parse(["-R", "labs/x", "-P", "10"])
        #expect(cmd.repo?.fullPath == "labs/x")
        #expect(cmd.perPage == 10)
    }

    @Test func boardCreatePositionalName() throws {
        let cmd = try IssueBoardCreate.parse(["My Board"])
        #expect(cmd.positionalName == "My Board")
        #expect(cmd.name == nil)
    }

    @Test func boardCreateNameFlag() throws {
        let cmd = try IssueBoardCreate.parse(["-n", "My Board"])
        #expect(cmd.positionalName == nil)
        #expect(cmd.name == "My Board")
    }

    @Test func boardViewIdOptional() throws {
        let bare = try IssueBoardView.parse([])
        #expect(bare.boardId == nil)
        let withId = try IssueBoardView.parse(["28"])
        #expect(withId.boardId == 28)
    }

    @Test func boardViewWebFlag() throws {
        let cmd = try IssueBoardView.parse(["28", "-w"])
        #expect(cmd.web == true)
    }

    @Test func boardDeleteRequiresIdAndYes() throws {
        let cmd = try IssueBoardDelete.parse(["28", "-y"])
        #expect(cmd.boardId == 28)
        #expect(cmd.yes == true)
    }

    // MARK: Release

    @Test func releaseListLimitFlag() throws {
        let cmd = try ReleaseList.parse(["-R", "g/r", "-l", "5"])
        #expect(cmd.repo?.fullPath == "g/r")
        #expect(cmd.limit == 5)
    }

    @Test func releaseViewRequiresTag() {
        #expect(throws: (any Error).self) {
            _ = try ReleaseView.parse([])
        }
    }

    @Test func releaseCreateRequiresTagAndAcceptsFlags() throws {
        let cmd = try ReleaseCreate.parse(Array(GlabCommand.preprocess([
            "release", "create",
            "v1.0.0",
            "-n", "First Stable",
            "-N", "Body of the release notes",
            "-r", "main",
            "--no-update"
        ]).dropFirst(2)))
        #expect(cmd.tagName == "v1.0.0")
        #expect(cmd.name == "First Stable")
        #expect(cmd.notes == "Body of the release notes")
        #expect(cmd.ref == "main")
        #expect(cmd.noUpdate)
    }

    @Test func releaseDeleteRequiresTag() throws {
        let cmd = try ReleaseDelete.parse(["v1.0.0"])
        #expect(cmd.tagName == "v1.0.0")
    }

    @Test func releaseDownloadRequiresTagAndAcceptsFlags() throws {
        let cmd = try ReleaseDownload.parse([
            "v1.2.0",
            "-p", "*.zip",
            "-p", "*.dmg",
            "-D", "/tmp/out",
            "--sources",
        ])
        #expect(cmd.tagName == "v1.2.0")
        #expect(cmd.patterns == ["*.zip", "*.dmg"])
        #expect(cmd.directory == "/tmp/out")
        #expect(cmd.sources == true)
    }

    // MARK: Tag

    @Test func tagListSearchAndLimit() throws {
        let cmd = try TagList.parse(["-s", "rc", "-l", "10"])
        #expect(cmd.search == "rc")
        #expect(cmd.limit == 10)
    }

    @Test func tagCreateAnnotated() throws {
        let cmd = try TagCreate.parse([
            "v0.1.0",
            "main",
            "-m", "first dev tag",
        ])
        #expect(cmd.tagName == "v0.1.0")
        #expect(cmd.ref == "main")
        #expect(cmd.message == "first dev tag")
    }

    @Test func tagCreateLightweight() throws {
        let cmd = try TagCreate.parse(["v0.0.1"])
        #expect(cmd.tagName == "v0.0.1")
        #expect(cmd.ref == nil)
        #expect(cmd.message == nil)
    }

    @Test func tagDeleteRequiresName() throws {
        let cmd = try TagDelete.parse(["v0.1.0"])
        #expect(cmd.tagName == "v0.1.0")
    }

    // MARK: Variable

    @Test func variableListShowValuesFlag() throws {
        let cmd = try VariableList.parse(["--show-values"])
        #expect(cmd.showValues == true)
    }

    @Test func variableSetRequiresKeyAndValue() {
        #expect(throws: (any Error).self) {
            _ = try VariableSet.parse(["KEY"])
        }
    }

    @Test func variableSetWithFlags() throws {
        let cmd = try VariableSet.parse([
            "API_TOKEN", "secret",
            "-p", "-m",
            "--scope", "production",
        ])
        #expect(cmd.key == "API_TOKEN")
        #expect(cmd.value == "secret")
        #expect(cmd.protected == true)
        #expect(cmd.masked == true)
        #expect(cmd.scope == "production")
    }

    @Test func variableSetRawAndType() throws {
        let cmd = try VariableSet.parse([
            "DEPLOY_KEY", "key-contents",
            "--raw",
            "-t", "file",
        ])
        #expect(cmd.raw == true)
        #expect(cmd.variableType == "file")
    }

    @Test func variableUnsetRequiresKey() throws {
        let cmd = try VariableUnset.parse(["API_TOKEN"])
        #expect(cmd.key == "API_TOKEN")
    }

    // MARK: CI lint

    @Test func ciLintDefaultsToProjectRoot() throws {
        let cmd = try CiLint.parse([])
        #expect(cmd.path == ".gitlab-ci.yml")
    }

    @Test func ciLintAcceptsExplicitPath() throws {
        let cmd = try CiLint.parse(["custom-ci.yml"])
        #expect(cmd.path == "custom-ci.yml")
    }

    @Test func ciLintAcceptsStdinSentinel() throws {
        let cmd = try CiLint.parse(["-"])
        #expect(cmd.path == "-")
    }

    // MARK: Repo edit

    @Test func repoEditDescriptionAndDefaultBranch() throws {
        let cmd = try RepoEdit.parse([
            "-R", "g/r",
            "--description", "new desc",
            "--default-branch", "develop",
            "--visibility", "internal",
        ])
        #expect(cmd.repo?.fullPath == "g/r")
        #expect(cmd.description == "new desc")
        #expect(cmd.defaultBranch == "develop")
        #expect(cmd.visibility == "internal")
    }

    @Test func repoEditFeatureToggles() throws {
        let cmd = try RepoEdit.parse([
            "--enable-issues",
            "--disable-wiki",
            "--enable-mrs",
        ])
        #expect(cmd.enableIssues == true)
        #expect(cmd.disableWiki == true)
        #expect(cmd.enableMRs == true)
        #expect(cmd.disableIssues == false)
    }

    // MARK: api

    @Test func apiAcceptsBareEndpoint() throws {
        let cmd = try ApiCommand.parse(["projects/123"])
        #expect(cmd.endpoint == "projects/123")
        #expect(cmd.method == "GET")
        #expect(cmd.fields.isEmpty)
        #expect(cmd.rawFields.isEmpty)
    }

    @Test func apiPostWithFields() throws {
        let cmd = try ApiCommand.parse([
            "-X", "POST", "projects/1/issues",
            "-f", "title=Bug",
            "-F", "labels=ui,bug",
        ])
        #expect(cmd.method == "POST")
        #expect(cmd.endpoint == "projects/1/issues")
        #expect(cmd.rawFields == ["title=Bug"])
        #expect(cmd.fields == ["labels=ui,bug"])
    }

    @Test func apiHostnameOverride() throws {
        let cmd = try ApiCommand.parse([
            "/user",
            "--hostname", "gitlab.example.com",
        ])
        #expect(cmd.hostname == "gitlab.example.com")
    }

    @Test func apiIncludeHeadersFlag() throws {
        let cmd = try ApiCommand.parse(["projects/1", "-i"])
        #expect(cmd.includeHeaders == true)
    }

    @Test func apiParsesJqShortAndLongFlags() throws {
        let short = try ApiCommand.parse(["projects/26", "-q", ".name"])
        #expect(short.jqFilter == ".name")
        let long = try ApiCommand.parse(["projects/26", "--jq", ".path"])
        #expect(long.jqFilter == ".path")
    }

    // MARK: Label

    @Test func labelListLimit() throws {
        let cmd = try LabelList.parse(["-R", "g/r", "-l", "20"])
        #expect(cmd.repo?.fullPath == "g/r")
        #expect(cmd.limit == 20)
    }

    @Test func labelCreateRequiresName() throws {
        let cmd = try LabelCreate.parse([
            "bug",
            "-c", "ff0000",
            "-d", "Something is broken",
        ])
        #expect(cmd.name == "bug")
        #expect(cmd.color == "ff0000")
        #expect(cmd.labelDescription == "Something is broken")
    }

    @Test func labelDeleteSkipsPromptWithYes() throws {
        let cmd = try LabelDelete.parse(["bug", "-y"])
        #expect(cmd.name == "bug")
        #expect(cmd.skipPrompt == true)
    }
}

#endif  // !os(Android)
