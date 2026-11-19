// git-lfs 3.7.1's root usage text (git-lfs/git-lfs, MIT license).
// Kept verbatim, including its command inventory, for output compatibility.
//
// Copyright (c) 2014- GitHub, Inc. and Git LFS contributors
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
public enum LFSHelp {
    public static let text = """
        git lfs <command> [<args>]

        Git LFS is a system for managing and versioning large files in
        association with a Git repository. Instead of storing the large files
        within the Git repository as blobs, Git LFS stores special "pointer
        files" in the repository, while storing the actual file contents on a
        Git LFS server. The contents of the large file are downloaded
        automatically when needed, for example when a Git branch containing the
        large file is checked out.

        Git LFS works by using a "smudge" filter to look up the large file
        contents based on the pointer file, and a "clean" filter to create a new
        version of the pointer file when the large file's contents change. It
        also uses a pre-push hook to upload the large file contents to the Git
        LFS server whenever a commit containing a new large file version is
        about to be pushed to the corresponding Git server.

        Commands
        --------

        Like Git, Git LFS commands are separated into high level ("porcelain")
        commands and low level ("plumbing") commands.

        High level porcelain commands
        ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

        git lfs checkout:
          Populate working copy with real content from Git LFS files.
        git lfs completion:
          Generate shell scripts for command-line tab-completion of Git LFS commands.
        git lfs dedup:
          De-duplicate Git LFS files.
        git lfs env:
          Display the Git LFS environment.
        git lfs ext:
          Display Git LFS extension details.
        git lfs fetch:
          Download Git LFS files from a remote.
        git lfs fsck:
          Check Git LFS files for consistency.
        git lfs install:
          Install Git LFS configuration.
        git lfs lock:
          Set a file as "locked" on the Git LFS server.
        git lfs locks:
          List currently "locked" files from the Git LFS server.
        git lfs logs:
          Show errors from the Git LFS command.
        git lfs ls-files:
          Show information about Git LFS files in the index
          and working tree.
        git lfs migrate:
          Migrate history to or from Git LFS
        git lfs prune:
          Delete old Git LFS files from local storage
        git lfs pull:
          Fetch Git LFS changes from the remote & checkout any required working tree
          files.
        git lfs push:
          Push queued large files to the Git LFS endpoint.
        git lfs status:
          Show the status of Git LFS files in the working
          tree.
        git lfs track:
          View or add Git LFS paths to Git attributes.
        git lfs uninstall:
          Uninstall Git LFS by removing hooks and smudge/clean filter configuration.
        git lfs unlock:
          Remove "locked" setting for a file on the Git LFS server.
        git lfs untrack:
          Remove Git LFS paths from Git Attributes.
        git lfs update:
          Update Git hooks for the current Git repository.
        git lfs version:
          Report the version number.

        Low level plumbing commands
        ~~~~~~~~~~~~~~~~~~~~~~~~~~~

        git lfs clean:
          Git clean filter that converts large files to pointers.
        git lfs filter-process:
          Git process filter that converts between large files and pointers.
        git lfs merge-driver:
          Merge text-based LFS files
        git lfs pointer:
          Build and compare pointers.
        git lfs post-checkout:
          Git post-checkout hook implementation.
        git lfs post-commit:
          Git post-commit hook implementation.
        git lfs post-merge:
          Git post-merge hook implementation.
        git lfs pre-push:
          Git pre-push hook implementation.
        git lfs smudge:
          Git smudge filter that converts pointer in blobs to the actual content.
        git lfs standalone-file:
          Git LFS standalone transfer adapter for file URLs (local paths).

        Examples
        --------

        To get started with Git LFS, the following commands can be used.

        . Setup Git LFS on your system. You only have to do this once per user
        account:
        +

        git lfs install

        . Choose the type of files you want to track, for examples all ISO
        images, with git lfs track:
        +

        git lfs track "*.iso"

        . The above stores this information in gitattributes(5) files, so that
        file needs to be added to the repository:
        +

        git add .gitattributes

        . Commit, push and work with the files normally:
        +

        git add file.iso
        git commit -m "Add disk image"
        git push\n
        """
}
