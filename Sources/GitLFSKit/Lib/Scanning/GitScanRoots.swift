/// Rev-list roots by kind once tags are peeled: trees and blobs in the order
/// given, and the commits whose history is walked. Each object appears once.
struct GitScanRoots {
    enum Root {
        case tree(String)
        case blob(String)
    }

    var roots: [Root] = []
    var commits: [String] = []
}
