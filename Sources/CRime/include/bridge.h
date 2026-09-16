#include <stdint.h>
int feather_start(const char *library, const char *shared, const char *user);
void feather_stop(void);
uintptr_t feather_session(const char *schema);
void feather_destroy(uintptr_t session);
int feather_key(uintptr_t session, int key, int modifiers);
void feather_clear(uintptr_t session);
void feather_commit(uintptr_t session);
char *feather_take_commit(uintptr_t session);
char *feather_input(uintptr_t session);
char *feather_preedit(uintptr_t session, int *cursor);
int feather_candidates(uintptr_t session, char **texts, int capacity, int *highlight);
int feather_select(uintptr_t session, const char *schema);
void feather_ascii(uintptr_t session, int enabled);
void feather_free(char *text);
int feather_select_candidate(uintptr_t session, int index);

int feather_page_size(const char *schema, int count);
int feather_english_min_length(const char *schema, int count);
int feather_candidate_slice(uintptr_t session, int offset, char **texts, int capacity);
int feather_select_global(uintptr_t session, int index);
int feather_candidate_page_offset(uintptr_t session);
