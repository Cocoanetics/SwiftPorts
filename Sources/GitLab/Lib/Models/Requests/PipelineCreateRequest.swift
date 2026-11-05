import Foundation

/// Body for `POST /projects/:id/pipeline`.
public struct PipelineCreateRequest: Codable, Sendable {
    public struct Variable: Codable, Sendable, Equatable {
        public enum VariableType: String, Codable, Sendable {
            case envVar = "env_var"
            case file
        }

        public var key: String
        public var value: String
        public var variableType: VariableType?

        public init(key: String, value: String, variableType: VariableType? = nil) {
            self.key = key
            self.value = value
            self.variableType = variableType
        }
    }

    public var ref: String
    public var variables: [Variable]?
    public var inputs: [String: PipelineInputValue]?

    /// Empty `variables` / `inputs` are omitted from the encoded body.
    public init(
        ref: String,
        variables: [Variable] = [],
        inputs: [String: PipelineInputValue] = [:]
    ) {
        self.ref = ref
        self.variables = variables.isEmpty ? nil : variables
        self.inputs = inputs.isEmpty ? nil : inputs
    }
}
