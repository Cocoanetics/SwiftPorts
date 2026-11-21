#include "CLFSCurl.h"
#include <stdlib.h>
#include <string.h>

#if defined(_WIN32)
// Swift 6.4's SDK provides static libcurl.lib (Schannel) but not public curl
// development headers. These declarations use libcurl's stable public C ABI.
// No runtime symbol lookup, second TLS backend, or vendored curl is involved.
extern int curl_global_init(long);
extern void *curl_easy_init(void);
extern int curl_easy_setopt(void *, int, ...);
extern int curl_easy_perform(void *);
extern void curl_easy_cleanup(void *);
extern void *curl_slist_append(void *, const char *);
extern void curl_slist_free_all(void *);
extern const char *curl_easy_strerror(int);

int sp_lfs_curl_initialize(void) { return curl_global_init(3L); }
const char *sp_lfs_curl_error_string(int code) { return curl_easy_strerror(code); }

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
    int64_t connect_timeout_ms, int64_t resource_timeout_ms,
    const char *proxy, const char *no_proxy, int use_cookies, void *context,
    sp_lfs_read read, sp_lfs_receive receive, sp_lfs_receive header,
    sp_lfs_seek seek, sp_lfs_progress progress, char *error, size_t error_capacity
) {
    if (progress(context, 0, 0)) return 42; // CURLE_ABORTED_BY_CALLBACK
    void *handle = curl_easy_init();
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
        void *next = curl_slist_append(list, copy);
        free(copy);
        if (!next) { result = 27; goto done; }
        list = next;
        if (!end) break;
        line = end + 2;
    }
#define SET(option, value) do { result = curl_easy_setopt(handle, option, value); if (result) goto done; } while (0)
    SET(10002, url);                 // CURLOPT_URL
    // CURLOPT_UPLOAD already selects PUT; leaving CUSTOMREQUEST unset lets
    // curl change a 303 to GET, like URLSession, while preserving 307/308 PUTs.
    (void)method;
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
    if (proxy) SET(10004, proxy);    // CURLOPT_PROXY (nil inherits curl environment)
    if (no_proxy) SET(10177, no_proxy); // CURLOPT_NOPROXY
    if (use_cookies) SET(10031, ""); // CURLOPT_COOKIEFILE: cookies during redirects
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
    result = curl_easy_perform(handle);
#undef SET
done:
    if (result && error && error_capacity) {
        const char *message = detail[0] ? detail : curl_easy_strerror(result);
        size_t count = strlen(message);
        if (count >= error_capacity) count = error_capacity - 1;
        memcpy(error, message, count);
        error[count] = 0;
    }
    curl_easy_cleanup(handle);
    curl_slist_free_all(list);
    return result;
}

#endif
