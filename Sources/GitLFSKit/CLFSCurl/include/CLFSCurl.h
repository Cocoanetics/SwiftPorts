#ifndef SWIFTPORTS_LFS_CURL_H
#define SWIFTPORTS_LFS_CURL_H

#include <stddef.h>
#include <stdint.h>

typedef size_t (*sp_lfs_read)(void *, unsigned char *, size_t);
typedef size_t (*sp_lfs_receive)(void *, const unsigned char *, size_t);
typedef int (*sp_lfs_seek)(void *, int64_t, int);
typedef int (*sp_lfs_progress)(void *, int64_t, int64_t);

// Returns a CURLcode, or -1 when the platform's libcurl is unavailable.
// All callbacks run serially on the calling thread. No callback survives return.
int sp_lfs_curl_upload(
    const char *url, const char *method, const char *headers, int64_t length,
    int64_t connect_timeout_ms, int64_t resource_timeout_ms, void *context,
    sp_lfs_read read, sp_lfs_receive receive, sp_lfs_receive header,
    sp_lfs_seek seek, sp_lfs_progress progress, char *error, size_t error_capacity);

#endif
