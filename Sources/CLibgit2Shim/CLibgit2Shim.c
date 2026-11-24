#include "CLibgit2Shim.h"
#include <git2/common.h>
#include <git2/buffer.h>
#include <git2/errors.h>
#include <string.h>

int swiftports_libgit2_set_search_path(int level, const char *path) {
    return git_libgit2_opts(GIT_OPT_SET_SEARCH_PATH, level, path);
}

int swiftports_libgit2_set_homedir(const char *path) {
    return git_libgit2_opts(GIT_OPT_SET_HOMEDIR, path);
}

/// Copies `buffer` into `out` when `result` is success; `GIT_EBUFS` when it
/// does not fit. Disposes of `buffer`.
static int swiftports_copy_buffer(int result, git_buf *buffer, char *out, size_t length) {
    if (result == 0) {
        size_t size = buffer->ptr ? strlen(buffer->ptr) : 0;
        if (size + 1 > length) {
            result = GIT_EBUFS;
        } else {
            if (size) memcpy(out, buffer->ptr, size);
            out[size] = '\0';
        }
    }
    git_buf_dispose(buffer);
    return result;
}

int swiftports_libgit2_get_search_path(int level, char *out, size_t length) {
    git_buf buffer = GIT_BUF_INIT;
    int result = git_libgit2_opts(GIT_OPT_GET_SEARCH_PATH, level, &buffer);
    return swiftports_copy_buffer(result, &buffer, out, length);
}

int swiftports_libgit2_get_homedir(char *out, size_t length) {
    git_buf buffer = GIT_BUF_INIT;
    int result = git_libgit2_opts(GIT_OPT_GET_HOMEDIR, &buffer);
    return swiftports_copy_buffer(result, &buffer, out, length);
}
