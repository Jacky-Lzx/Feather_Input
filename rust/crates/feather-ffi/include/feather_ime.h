#ifndef FEATHER_IME_H
#define FEATHER_IME_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct FeatherIme FeatherIme;
typedef struct FeatherResponse FeatherResponse;

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
FeatherIme *feather_ime_new(void);
FeatherIme *feather_ime_new_rime(const char *shared_data,
                                 const char *user_data,
                                 const char *schema);
void feather_ime_free(FeatherIme *ime);
FeatherResponse *feather_ime_activate(FeatherIme *ime);
FeatherResponse *feather_ime_deactivate(FeatherIme *ime);
FeatherResponse *feather_ime_set_mode(FeatherIme *ime, uint8_t mode);
FeatherResponse *feather_ime_key(FeatherIme *ime, uint32_t kind,
                                 const uint8_t *text, size_t text_length);
FeatherResponse *feather_ime_select_candidate(FeatherIme *ime,
                                              uint64_t revision,
                                              uint64_t value);
void feather_ime_response_free(FeatherResponse *response);

#ifdef __cplusplus
}
#endif

#endif
