import Testing
import GitLFSKit

@Suite("FilepathFilter")
struct FilepathFilterTests {
    @Test("includes are a union, then exclusions take precedence")
    func includeExclude() {
        #expect(FilepathFilter().allows("any/path"))
        let filter = FilepathFilter(include: ["*.dat", "images/**"], exclude: ["private", "*.tmp.dat"])
        #expect(filter.allows("nested/file.dat"))
        #expect(filter.allows("images/a/b.png"))
        #expect(!filter.allows("file.txt"))
        #expect(!filter.allows("images/private/file.dat"))
        #expect(!filter.allows("nested/file.tmp.dat"))
        #expect(!FilepathFilter(exclude: ["*.dat"]).allows("nested/file.dat"))
        #expect(FilepathFilter(exclude: ["*.dat"]).allows("nested/file.txt"))
    }

    // git-lfs 3.7.1 filepathfilter uses wildmatch v2.0.1 with Contents.
    @Test("GitIgnore wildmatch paths", arguments: [
        ("*", "a/b/c", true),
        ("*.dat", "a/b/file.dat", true),
        ("*.dat", "a.dat/child", true),
        ("*.dat", "a/b/file.txt", false),
        ("sub/*.dat", "sub/file.dat", true),
        ("sub/*.dat", "sub/deeper/file.dat", false),
        ("sub/*.dat", "top/sub/file.dat", false),
        ("/file.dat", "file.dat", true),
        ("/file.dat", "sub/file.dat", false),
        ("sub/", "top/sub/file.dat", true),
        ("/sub/", "sub/file.dat", true),
        ("/sub/", "top/sub/file.dat", false),
        ("sub", "top/sub/file.dat", true),
        ("sub", "submarine/file.dat", false),
        ("**/file.dat", "file.dat", true),
        ("**/file.dat", "a/b/file.dat", true),
        ("a/**/file.dat", "a/file.dat", true),
        ("a/**/file.dat", "a/b/c/file.dat", true),
        ("a/**/file.dat", "z/a/file.dat", false),
        ("**/a/b", "a/c/a/b", true),
        ("**/a/b", "a/b/a/c", false),
        ("a/**", "a/b/c", true),
        ("a**b/file.dat", "axxb/file.dat", true),
        ("a**b/file.dat", "a/x/b/file.dat", false),
        ("a/?/file.dat", "a/x/file.dat", true),
        ("a/?/file.dat", "a/xx/file.dat", false),
        ("a?b", "a/b", false),
        ("file[0-9].dat", "sub/file2.dat", true),
        ("file[!0-9].dat", "sub/filex.dat", true),
        ("file[!0-9].dat", "sub/file2.dat", false),
        ("file[[:digit:]].dat", "sub/file2.dat", true),
        ("file[[:digit:]].dat", "sub/filex.dat", false),
        (#"file\*.dat"#, "sub/file*.dat", true),
        (#"file\*.dat"#, "sub/filex.dat", false),
        (#"file[\]].dat"#, "sub/file].dat", true),
        (#"sub\file.dat"#, "sub/file.dat", true),
        ("!file.dat", "file.dat", false),
        ("!file.dat", "!file.dat", true),
        ("#file.dat", "#file.dat", true),
        ("*.dat", "sub/a\nb.dat", true)
    ])
    func wildmatch(_ sample: (String, String, Bool)) {
        #expect(FilepathFilter(include: [sample.0]).allows(sample.1) == sample.2)
        #expect(FilepathFilter(exclude: [sample.0]).allows(sample.1) != sample.2)
    }

    @Test("SystemCase follows the upstream platform rule")
    func systemCase() {
        #if os(Windows) || canImport(Darwin)
        #expect(FilepathFilter(include: ["*.DAT"]).allows("file.dat"))
        #else
        #expect(!FilepathFilter(include: ["*.DAT"]).allows("file.dat"))
        #endif
    }
}
