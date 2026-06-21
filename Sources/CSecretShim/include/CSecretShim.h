#ifndef SWIFTPORTS_CSECRET_SHIM_H
#define SWIFTPORTS_CSECRET_SHIM_H

/// Non-variadic, Swift-friendly wrappers around libsecret's "simple
/// password API" (`secret_password_*_sync`).
///
/// libsecret's API is C-variadic (`…, "attr", value, …, NULL`) and uses
/// a fixed 32-slot `SecretSchema` attribute array — both hostile from
/// Swift (the importer refuses C variadics; the array imports as a
/// 32-tuple). This shim sits on the C side of the boundary, where the
/// `va_arg` ABI is correct and the schema is a plain static, and exposes
/// fixed-arity functions keyed by `(service, account)`.
///
/// All secrets are stored under one schema (`org.swiftports.Secret`)
/// with two string attributes: `service` and `account`.

/// Store `secret` under `(service, account)` in the default collection.
/// `label` is the human-readable name shown in keyring UIs (may be NULL).
/// Returns 0 on success, negative on failure.
int swiftports_secret_store(const char *service, const char *account,
                            const char *label, const char *secret);

/// Look up the secret for `(service, account)`.
///
/// Returns a newly-allocated string the caller must release with
/// ``swiftports_secret_free``, or NULL. `*out_status` disambiguates a
/// NULL return:
///   -  1: found (non-NULL return)
///   -  0: no such entry (NULL return, not an error)
///   - -1: backend error (NULL return)
char *swiftports_secret_lookup(const char *service, const char *account,
                               int *out_status);

/// Remove the secret for `(service, account)`. Returns 0 on success
/// (including when there was nothing to remove), negative on error.
int swiftports_secret_clear(const char *service, const char *account);

/// Release a string returned by ``swiftports_secret_lookup``.
void swiftports_secret_free(char *value);

/// 1 if the Secret Service (D-Bus `org.freedesktop.secrets`) is
/// reachable, 0 otherwise. Lets the caller fall back to a file store on
/// headless boxes without a running keyring daemon.
int swiftports_secret_available(void);

#endif /* SWIFTPORTS_CSECRET_SHIM_H */
