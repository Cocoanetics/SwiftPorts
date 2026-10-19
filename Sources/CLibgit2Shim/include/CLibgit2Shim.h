#ifndef SWIFTPORTS_CLIBGIT2_SHIM_H
#define SWIFTPORTS_CLIBGIT2_SHIM_H

/// Typed wrappers around the small subset of `git_libgit2_opts(int, ...)`
/// that the `Sandbox` ↔ libgit2 bridge needs.
///
/// libgit2's options API is variadic in C: `int git_libgit2_opts(int option, ...)`.
/// Swift's importer refuses C variadic functions, and calling them via
/// `dlsym` + a non-variadic function-pointer cast silently mismatches
/// the variadic ABI on arm64 — args land in the wrong slots, libgit2's
/// switch-on-option-enum reads garbage, no error is returned, and the
/// option SET silently no-ops. Verified during the issue #18 design
/// discussion.
///
/// This shim sits at the C side of the boundary and dispatches the
/// variadic call from C, where the va_arg ABI is correct.
///
/// All functions return libgit2's standard `int` rc: `0` on success,
/// negative on failure.

/// `git_libgit2_opts(GIT_OPT_SET_SEARCH_PATH, level, path)`.
///
/// `level` must be one of:
///   - `GIT_CONFIG_LEVEL_SYSTEM` (2)
///   - `GIT_CONFIG_LEVEL_XDG` (3)
///   - `GIT_CONFIG_LEVEL_GLOBAL` (4)
///   - `GIT_CONFIG_LEVEL_PROGRAMDATA` (1)
///
/// `path` is the new search directory at that level. Empty string
/// disables that level entirely. `NULL` resets to libgit2's default.
int swiftports_libgit2_set_search_path(int level, const char *path);

/// `git_libgit2_opts(GIT_OPT_SET_HOMEDIR, path)`.
///
/// Overrides the directory libgit2 considers the current user's home
/// for non-config lookups (netrc, hook discovery, `~user` expansion in
/// remote URLs, etc.). Pass `NULL` to reset to libgit2's default
/// (which is `getenv("HOME")` / `getenv("USERPROFILE")` at init time).
int swiftports_libgit2_set_homedir(const char *path);

/// `git_libgit2_opts(GIT_OPT_GET_SEARCH_PATH, level, &buf)`, copied into
/// `out` (`length` bytes, NUL-terminated). Returns `0` on success, a
/// negative libgit2 code on failure, and `-1` when the path does not fit.
/// A level that is disabled (`SET_SEARCH_PATH` with `""`) gives an empty string.
int swiftports_libgit2_get_search_path(int level, char *out, unsigned long length);

#endif
