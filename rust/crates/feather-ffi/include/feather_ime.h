#ifndef FEATHER_IME_H
#define FEATHER_IME_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define FEATHER_IME_ABI_VERSION 2u

typedef struct FeatherIme FeatherIme;
typedef struct FeatherError FeatherError;
typedef struct FeatherResponse FeatherResponse;
typedef struct FeatherCandidateSlice FeatherCandidateSlice;
typedef uint32_t FeatherStatus;

enum FeatherStatusCode {
    FEATHER_STATUS_OK = 0,
    FEATHER_STATUS_INVALID_ARGUMENT = 1,
    FEATHER_STATUS_INVALID_UTF8 = 2,
    FEATHER_STATUS_INVALID_KEY = 3,
    FEATHER_STATUS_ABI_MISMATCH = 4,
    FEATHER_STATUS_SESSION_CLOSED = 5,
    FEATHER_STATUS_WRONG_THREAD = 6,
    FEATHER_STATUS_ENGINE_INITIALIZATION_FAILED = 7,
    FEATHER_STATUS_ENGINE_OPERATION_FAILED = 8,
    FEATHER_STATUS_SNAPSHOT_FAILED = 9,
    FEATHER_STATUS_INTERNAL_ERROR = 10,
    FEATHER_STATUS_STALE_REVISION = 11
};

enum FeatherCapability {
    FEATHER_CAP_RIME_ENGINE = UINT64_C(1) << 0,
    FEATHER_CAP_OPAQUE_CANDIDATE_ID = UINT64_C(1) << 1,
    FEATHER_CAP_EXPLICIT_CLOSE = UINT64_C(1) << 2,
    FEATHER_CAP_STRUCTURED_ERROR = UINT64_C(1) << 3,
    FEATHER_CAP_MULTI_SESSION = UINT64_C(1) << 4,
    FEATHER_CAP_CANDIDATE_SLICES = UINT64_C(1) << 5
};

struct FeatherError {
    uint32_t code;
    const char *message;
    void *_storage;
};

typedef struct {
    uint64_t revision;
    uint64_t value;
    const char *text;
} FeatherCandidate;

struct FeatherResponse {
    uint8_t handled;
    uint8_t active;
    uint8_t mode;
    const char *commit;
    const char *preedit;
    size_t cursor_utf8;
    uint64_t revision;
    const FeatherCandidate *candidates;
    size_t candidate_count;
    ptrdiff_t highlighted;
    void *_storage;
};

struct FeatherCandidateSlice {
    uint64_t revision;
    size_t offset;
    const FeatherCandidate *candidates;
    size_t candidate_count;
    uint8_t has_more;
    void *_storage;
};

enum FeatherKeyKind {
    FEATHER_KEY_TEXT = 1,
    FEATHER_KEY_BACKSPACE,
    FEATHER_KEY_DELETE,
    FEATHER_KEY_SPACE,
    FEATHER_KEY_ENTER,
    FEATHER_KEY_ESCAPE,
    FEATHER_KEY_LEFT,
    FEATHER_KEY_RIGHT,
    FEATHER_KEY_UP,
    FEATHER_KEY_DOWN,
    FEATHER_KEY_PAGE_UP,
    FEATHER_KEY_PAGE_DOWN,
    FEATHER_KEY_TOGGLE_MODE
};

uint32_t feather_ime_abi_version(void);
uint64_t feather_ime_capabilities(void);

/* On failure, out values are cleared. A nonnull out_error receives an owned error. */
FeatherStatus feather_ime_new(FeatherIme **out_ime,
                              FeatherError **out_error);
FeatherStatus feather_ime_new_rime(const char *shared_data,
                                   const char *user_data,
                                   const char *schema,
                                   FeatherIme **out_ime,
                                   FeatherError **out_error);

FeatherStatus feather_ime_close(FeatherIme *ime,
                                FeatherError **out_error);
/* Free must run on the session's owner thread after close. */
void feather_ime_free(FeatherIme *ime);

FeatherStatus feather_ime_activate(FeatherIme *ime,
                                   FeatherResponse **out_response,
                                   FeatherError **out_error);
FeatherStatus feather_ime_deactivate(FeatherIme *ime,
                                     FeatherResponse **out_response,
                                     FeatherError **out_error);
FeatherStatus feather_ime_set_mode(FeatherIme *ime,
                                   uint8_t mode,
                                   FeatherResponse **out_response,
                                   FeatherError **out_error);
FeatherStatus feather_ime_set_schema(FeatherIme *ime,
                                     const char *schema,
                                     FeatherResponse **out_response,
                                     FeatherError **out_error);
FeatherStatus feather_ime_key(FeatherIme *ime,
                              uint32_t kind,
                              const uint8_t *text,
                              size_t text_length,
                              FeatherResponse **out_response,
                              FeatherError **out_error);
FeatherStatus feather_ime_select_candidate(FeatherIme *ime,
                                           uint64_t revision,
                                           uint64_t value,
                                           FeatherResponse **out_response,
                                           FeatherError **out_error);
FeatherStatus feather_ime_candidate_slice(FeatherIme *ime,
                                          uint64_t revision,
                                          size_t offset,
                                          size_t limit,
                                          FeatherCandidateSlice **out_slice,
                                          FeatherError **out_error);

void feather_error_free(FeatherError *error);
void feather_ime_response_free(FeatherResponse *response);
void feather_ime_candidate_slice_free(FeatherCandidateSlice *slice);

#ifdef __cplusplus
}
#endif

#endif
