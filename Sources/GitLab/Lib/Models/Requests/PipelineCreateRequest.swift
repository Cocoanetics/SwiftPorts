import Foundation

/// Body for `POST /projects/:id/pipeline`.
public struct PipelineCreateRequest: Codable, Sendable {
    public struct Variable: Codable, Sendable, Equatable {
        public var key: String
        public var value: String

        public init(key: String, value: String) {
            self.key = key
            self.value = value
        }
    }

    public var ref: String
    public var variables: [Variable]?

    /// An empty `variables` list is omitted from the encoded body.
    public init(ref: String, variables: [Variable] = []) {
        self.ref = ref
        self.variables = variables.isEmpty ? nil : variables
    }
}
