#include "CLFSCurl.h"
#include <stdlib.h>
#include <string.h>

#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#else
#include <dlfcn.h>
#include <pthread.h>
#endif

// libcurl's public C ABI (https://curl.se/libcurl/c/). Resolve the already
// loaded Windows toolchain DLL, not a second curl with a different TLS backend.
// The option numbers/types are stable across supported curl versions. Resolving
// them here avoids requiring curl development headers in a Windows Swift SDK.
typedef struct {
    int (*global_init)(long);
    void *(*easy_init)(void);
    int (*setopt)(void *, int, ...);
    int (*perform)(void *);
    void (*cleanup)(void *);
    void *(*append)(void *, const char *);
    void (*free_headers)(void *);
    const char *(*error_string)(int);
    int available;
} sp_curl_api;

static sp_curl_api api;

static void load_curl(void) {
#if defined(_WIN32)
    HMODULE library = GetModuleHandleW(L"libcurl.dll");
    if (!library) library = GetModuleHandleW(L"curl.dll");
#define SYMBOL(name) ((void *)GetProcAddress(library, name))
#elif defined(__APPLE__)
    void *library = dlopen("/usr/lib/libcurl.dylib", RTLD_NOW | RTLD_LOCAL);
#define SYMBOL(name) dlsym(library, name)
#else
    void *library = dlopen("libcurl.so.4", RTLD_NOW | RTLD_LOCAL);
#define SYMBOL(name) dlsym(library, name)
#endif
    if (!library) return;
    api.global_init = SYMBOL("curl_global_init");
    api.easy_init = SYMBOL("curl_easy_init");
    api.setopt = SYMBOL("curl_easy_setopt");
    api.perform = SYMBOL("curl_easy_perform");
    api.cleanup = SYMBOL("curl_easy_cleanup");
    api.append = SYMBOL("curl_slist_append");
    api.free_headers = SYMBOL("curl_slist_free_all");
    api.error_string = SYMBOL("curl_easy_strerror");
#undef SYMBOL
    if (!api.global_init || !api.easy_init || !api.setopt || !api.perform ||
        !api.cleanup || !api.append || !api.free_headers || !api.error_string) return;
    api.available = api.global_init(3L) == 0;
}

#if defined(_WIN32)
static INIT_ONCE once = INIT_ONCE_STATIC_INIT;
static BOOL CALLBACK initialize(PINIT_ONCE token, PVOID parameter, PVOID *context) {
    (void)token; (void)parameter; (void)context;
    load_curl();
    return TRUE;
}
#else
static pthread_once_t once = PTHREAD_ONCE_INIT;
#endif

typedef struct {
    void *context;
    sp_lfs_read read;
    sp_lfs_receive receive;
    sp_lfs_receive header;
    sp_lfs_seek seek;
    sp_lfs_progress progress;
} sp_curl_callbacks;

static size_t read_body(char *bytes, size_t size, size_t count, void *opaque) {
    sp_curl_callbacks *callbacks = opaque;
    return callbacks->read(callbacks->context, (unsigned char *)bytes, size * count);
}

static size_t receive_body(char *bytes, size_t size, size_t count, void *opaque) {
    sp_curl_callbacks *callbacks = opaque;
    return callbacks->receive(callbacks->context, (unsigned char *)bytes, size * count);
}

static size_t receive_header(char *bytes, size_t size, size_t count, void *opaque) {
    sp_curl_callbacks *callbacks = opaque;
    return callbacks->header(callbacks->context, (unsigned char *)bytes, size * count);
}

static int seek_body(void *opaque, int64_t offset, int origin) {
    sp_curl_callbacks *callbacks = opaque;
    return callbacks->seek(callbacks->context, offset, origin);
}

static int transfer_progress(void *opaque, int64_t download_total, int64_t downloaded,
                             int64_t upload_total, int64_t uploaded) {
    (void)download_total; (void)upload_total;
    sp_curl_callbacks *callbacks = opaque;
    return callbacks->progress(callbacks->context, uploaded, downloaded);
}

int sp_lfs_curl_upload(
    const char *url, const char *method, const char *headers, int64_t length,
    int64_t connect_timeout_ms, int64_t resource_timeout_ms, void *context,
    sp_lfs_read read, sp_lfs_receive receive, sp_lfs_receive header,
    sp_lfs_seek seek, sp_lfs_progress progress, char *error, size_t error_capacity
) {
#if defined(_WIN32)
    InitOnceExecuteOnce(&once, initialize, NULL, NULL);
#else
    pthread_once(&once, load_curl);
#endif
    if (!api.available) return -1;
    if (progress(context, 0, 0)) return 42; // CURLE_ABORTED_BY_CALLBACK
    void *handle = api.easy_init();
    if (!handle) return 2; // CURLE_FAILED_INIT
    void *list = NULL;
    int result = 0;
    char detail[256] = {0}; // CURL_ERROR_SIZE
    sp_curl_callbacks callbacks = {context, read, receive, header, seek, progress};
    const char *line = headers;
    while (*line) {
        const char *end = strstr(line, "\r\n");
        size_t size = end ? (size_t)(end - line) : strlen(line);
        char *copy = malloc(size + 1);
        if (!copy) { result = 27; goto done; }
        memcpy(copy, line, size);
        copy[size] = 0;
        void *next = api.append(list, copy);
        free(copy);
        if (!next) { result = 27; goto done; }
        list = next;
        if (!end) break;
        line = end + 2;
    }
#define SET(option, value) do { result = api.setopt(handle, option, value); if (result) goto done; } while (0)
    SET(10002, url);                 // CURLOPT_URL
    SET(10036, method);              // CURLOPT_CUSTOMREQUEST
    SET(10023, list);                // CURLOPT_HTTPHEADER
    SET(10010, detail);              // CURLOPT_ERRORBUFFER
    SET(46, 1L);                    // CURLOPT_UPLOAD
    SET(30115, length);              // CURLOPT_INFILESIZE_LARGE (-1 for chunked)
    SET(99, 1L);                    // CURLOPT_NOSIGNAL
    SET(181, 3L);                   // CURLOPT_PROTOCOLS: HTTP | HTTPS
    SET(182, 3L);                   // CURLOPT_REDIR_PROTOCOLS
    SET(52, 1L);                    // CURLOPT_FOLLOWLOCATION
    SET(68, 20L);                   // CURLOPT_MAXREDIRS
    SET(265, 1L);                   // CURLOPT_SUPPRESS_CONNECT_HEADERS
    SET(10102, "");                 // CURLOPT_ACCEPT_ENCODING
    SET(156, (long)connect_timeout_ms);  // CURLOPT_CONNECTTIMEOUT_MS
    SET(155, (long)resource_timeout_ms); // CURLOPT_TIMEOUT_MS
    SET(20012, read_body);           // CURLOPT_READFUNCTION
    SET(10009, &callbacks);          // CURLOPT_READDATA
    SET(20011, receive_body);        // CURLOPT_WRITEFUNCTION
    SET(10001, &callbacks);          // CURLOPT_WRITEDATA
    SET(20079, receive_header);      // CURLOPT_HEADERFUNCTION
    SET(10029, &callbacks);          // CURLOPT_HEADERDATA
    SET(20167, seek_body);           // CURLOPT_SEEKFUNCTION
    SET(10168, &callbacks);          // CURLOPT_SEEKDATA
    SET(43, 0L);                    // CURLOPT_NOPROGRESS
    SET(20219, transfer_progress);   // CURLOPT_XFERINFOFUNCTION
    SET(10057, &callbacks);          // CURLOPT_XFERINFODATA
    result = api.perform(handle);
#undef SET
done:
    if (result && error && error_capacity) {
        const char *message = detail[0] ? detail : api.error_string(result);
        size_t count = strlen(message);
        if (count >= error_capacity) count = error_capacity - 1;
        memcpy(error, message, count);
        error[count] = 0;
    }
    api.cleanup(handle);
    api.free_headers(list);
    return result;
}
