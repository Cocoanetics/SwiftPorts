import Foundation

/// `variable_type` of a pipeline variable in `POST /projects/:id/pipeline`.
public enum PipelineVariableType: String, Codable, Sendable {
    case envVar = "env_var"
    case file
}
