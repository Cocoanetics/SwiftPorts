import Foundation

/// GitLab's detailed mergeability state for a merge request.
///
/// Modelled as `RawRepresentable` with an `.unknown` fallback so newer
/// GitLab instances don't break decoding.
public enum DetailedMergeStatus: RawRepresentable, Codable, Sendable, Hashable {
    case approvalsSyncing
    case checking
    case ciMustPass
    case ciStillRunning
    case commitsStatus
    case conflict
    case discussionsNotResolved
    case draftStatus
    case jiraAssociationMissing
    case mergeable
    case mergeRequestBlocked
    case mergeTime
    case needRebase
    case notApproved
    case notOpen
    case preparing
    case requestedChanges
    case securityPolicyPipelineCheck
    case securityPolicyViolations
    case statusChecksMustPass
    case unchecked
    case lockedPaths
    case lockedLfsFiles
    case titleRegex
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "approvals_syncing": self = .approvalsSyncing
        case "checking": self = .checking
        case "ci_must_pass": self = .ciMustPass
        case "ci_still_running": self = .ciStillRunning
        case "commits_status": self = .commitsStatus
        case "conflict": self = .conflict
        case "discussions_not_resolved": self = .discussionsNotResolved
        case "draft_status": self = .draftStatus
        case "jira_association_missing": self = .jiraAssociationMissing
        case "mergeable": self = .mergeable
        case "merge_request_blocked": self = .mergeRequestBlocked
        case "merge_time": self = .mergeTime
        case "need_rebase": self = .needRebase
        case "not_approved": self = .notApproved
        case "not_open": self = .notOpen
        case "preparing": self = .preparing
        case "requested_changes": self = .requestedChanges
        case "security_policy_pipeline_check": self = .securityPolicyPipelineCheck
        case "security_policy_violations": self = .securityPolicyViolations
        case "status_checks_must_pass": self = .statusChecksMustPass
        case "unchecked": self = .unchecked
        case "locked_paths": self = .lockedPaths
        case "locked_lfs_files": self = .lockedLfsFiles
        case "title_regex": self = .titleRegex
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .approvalsSyncing: return "approvals_syncing"
        case .checking: return "checking"
        case .ciMustPass: return "ci_must_pass"
        case .ciStillRunning: return "ci_still_running"
        case .commitsStatus: return "commits_status"
        case .conflict: return "conflict"
        case .discussionsNotResolved: return "discussions_not_resolved"
        case .draftStatus: return "draft_status"
        case .jiraAssociationMissing: return "jira_association_missing"
        case .mergeable: return "mergeable"
        case .mergeRequestBlocked: return "merge_request_blocked"
        case .mergeTime: return "merge_time"
        case .needRebase: return "need_rebase"
        case .notApproved: return "not_approved"
        case .notOpen: return "not_open"
        case .preparing: return "preparing"
        case .requestedChanges: return "requested_changes"
        case .securityPolicyPipelineCheck: return "security_policy_pipeline_check"
        case .securityPolicyViolations: return "security_policy_violations"
        case .statusChecksMustPass: return "status_checks_must_pass"
        case .unchecked: return "unchecked"
        case .lockedPaths: return "locked_paths"
        case .lockedLfsFiles: return "locked_lfs_files"
        case .titleRegex: return "title_regex"
        case .unknown(let s): return s
        }
    }

    /// `true` when GitLab reports the merge request can merge cleanly now.
    public var isMergeable: Bool {
        self == .mergeable
    }

    /// `true` while GitLab is still computing mergeability or waiting on
    /// in-flight checks that can settle without changing the merge request.
    public var isTransient: Bool {
        switch self {
        case .approvalsSyncing, .checking, .ciStillRunning, .preparing, .unchecked:
            return true
        default:
            return false
        }
    }
}
