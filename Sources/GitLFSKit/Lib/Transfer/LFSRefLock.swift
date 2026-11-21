/// One locked path and its owners across the verified remote refs (`commands.refLock`).
struct LFSRefLock {
    var ownersByRef: [String: String] = [:]

    func owners(verifiedRefs: Set<String>) -> String {
        let grouped = Dictionary(grouping: ownersByRef.keys) { ownersByRef[$0] ?? "" }
        return grouped.map { owner, refs in
            let names = refs.map(LFSClient.refName).sorted()
            // Match refLock.Owners, including its Name lookup into the Refspec-keyed set.
            if names.filter({ verifiedRefs.contains($0) }).count == verifiedRefs.count { return owner }
            return owner + " (refs: " + names.joined(separator: ", ") + ")"
        }.sorted().joined(separator: ", ")
    }
}
