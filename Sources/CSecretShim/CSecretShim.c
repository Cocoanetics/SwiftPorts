#include "CSecretShim.h"
#include <libsecret/secret.h>

// One schema for all SwiftPorts secrets, keyed by (service, account).
// `SECRET_SCHEMA_NONE` keeps the schema name as a match attribute so our
// items don't collide with other apps'. The trailing `{NULL, 0}`
// terminates the fixed 32-slot attribute array (remaining slots are
// zero-filled by static initialization).
static const SecretSchema *swiftports_secret_schema(void) {
    static const SecretSchema schema = {
        "org.swiftports.Secret", SECRET_SCHEMA_NONE,
        {
            { "service", SECRET_SCHEMA_ATTRIBUTE_STRING },
            { "account", SECRET_SCHEMA_ATTRIBUTE_STRING },
            { NULL, 0 },
        }
    };
    return &schema;
}

int swiftports_secret_store(const char *service, const char *account,
                            const char *label, const char *secret) {
    GError *error = NULL;
    gboolean ok = secret_password_store_sync(
        swiftports_secret_schema(),
        SECRET_COLLECTION_DEFAULT,
        label ? label : "SwiftPorts credential",
        secret,
        NULL,            // not cancellable
        &error,
        "service", service,
        "account", account,
        NULL);
    if (error != NULL) {
        g_error_free(error);
        return -1;
    }
    return ok ? 0 : -1;
}

char *swiftports_secret_lookup(const char *service, const char *account,
                               int *out_status) {
    GError *error = NULL;
    gchar *password = secret_password_lookup_sync(
        swiftports_secret_schema(),
        NULL,            // not cancellable
        &error,
        "service", service,
        "account", account,
        NULL);
    if (error != NULL) {
        g_error_free(error);
        if (password != NULL) {
            secret_password_free(password);
        }
        if (out_status != NULL) *out_status = -1;   // real error
        return NULL;
    }
    if (password == NULL) {
        if (out_status != NULL) *out_status = 0;    // not found
        return NULL;
    }
    if (out_status != NULL) *out_status = 1;        // found
    return password;
}

int swiftports_secret_clear(const char *service, const char *account) {
    GError *error = NULL;
    secret_password_clear_sync(
        swiftports_secret_schema(),
        NULL,            // not cancellable
        &error,
        "service", service,
        "account", account,
        NULL);
    if (error != NULL) {
        g_error_free(error);
        return -1;
    }
    return 0;
}

void swiftports_secret_free(char *value) {
    if (value != NULL) {
        secret_password_free(value);
    }
}

int swiftports_secret_available(void) {
    GError *error = NULL;
    SecretService *service = secret_service_get_sync(SECRET_SERVICE_NONE, NULL, &error);
    if (error != NULL) {
        g_error_free(error);
        return 0;
    }
    if (service == NULL) {
        return 0;
    }
    g_object_unref(service);
    return 1;
}
