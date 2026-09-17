#define _POSIX_C_SOURCE 200809L
#include <rime_api.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

static RimeApi *api = NULL;

int feather_rime_initialize(const char *shared, const char *user) {
  if (api != NULL || shared == NULL || user == NULL) return 0;
  api = rime_get_api();
  if (api == NULL) return 0;

  RIME_STRUCT(RimeTraits, traits);
  traits.shared_data_dir = shared;
  traits.user_data_dir = user;
  traits.distribution_name = "Feather Input Rust";
  traits.distribution_code_name = "feather-rust";
  traits.distribution_version = "0.1.0";
  traits.app_name = "rime.feather-rust";
  traits.min_log_level = 2;
  api->setup(&traits);
  api->initialize(&traits);
  if (api->start_maintenance(False)) api->join_maintenance_thread();
  return 1;
}

void feather_rime_finalize(void) {
  if (api != NULL) api->finalize();
  api = NULL;
}

uintptr_t feather_rime_create_session(const char *schema) {
  if (api == NULL || schema == NULL) return 0;
  uintptr_t session = api->create_session();
  if (session == 0) return 0;
  if (!api->select_schema(session, schema)) {
    api->destroy_session(session);
    return 0;
  }
  api->set_option(session, "simplification", True);
  return session;
}

int feather_rime_select_schema(uintptr_t session, const char *schema) {
  if (api == NULL || session == 0 || schema == NULL) return 0;
  if (!api->select_schema(session, schema)) return 0;
  api->clear_composition(session);
  api->set_option(session, "simplification", True);
  return 1;
}

void feather_rime_destroy_session(uintptr_t session) {
  if (api != NULL && session != 0) api->destroy_session(session);
}

int feather_rime_process_key(uintptr_t session, int key, int modifiers) {
  return api != NULL && session != 0 && api->process_key(session, key, modifiers);
}

void feather_rime_clear(uintptr_t session) {
  if (api != NULL && session != 0) api->clear_composition(session);
}

char *feather_rime_take_commit(uintptr_t session) {
  if (api == NULL || session == 0) return NULL;
  RIME_STRUCT(RimeCommit, commit);
  if (!api->get_commit(session, &commit)) return NULL;
  char *text = commit.text != NULL ? strdup(commit.text) : NULL;
  api->free_commit(&commit);
  return text;
}

char *feather_rime_preedit(uintptr_t session, size_t *cursor) {
  if (api == NULL || session == 0 || cursor == NULL) return NULL;
  RIME_STRUCT(RimeContext, context);
  if (!api->get_context(session, &context)) return NULL;
  *cursor = context.composition.cursor_pos;
  char *text = context.composition.preedit != NULL
                   ? strdup(context.composition.preedit)
                   : NULL;
  api->free_context(&context);
  return text;
}

int feather_rime_candidates(uintptr_t session, char **texts, char **comments,
                            uint64_t *ids, int capacity, int *highlight) {
  if (api == NULL || session == 0 || texts == NULL || comments == NULL ||
      ids == NULL || capacity <= 0 || highlight == NULL) return -1;
  RIME_STRUCT(RimeContext, context);
  if (!api->get_context(session, &context)) return -1;

  int count = context.menu.num_candidates < capacity
                  ? context.menu.num_candidates
                  : capacity;
  int offset = context.menu.page_no * context.menu.page_size;
  *highlight = context.menu.highlighted_candidate_index;
  for (int index = 0; index < count; ++index) {
    RimeCandidate *candidate = &context.menu.candidates[index];
    texts[index] = strdup(candidate->text != NULL ? candidate->text : "");
    comments[index] = candidate->comment != NULL ? strdup(candidate->comment) : NULL;
    ids[index] = (uint64_t)(offset + index);
  }
  api->free_context(&context);
  return count;
}

int feather_rime_candidate_slice(uintptr_t session, size_t offset, char **texts,
                                 char **comments, uint64_t *ids, int capacity,
                                 int *has_more) {
  if (api == NULL || session == 0 || texts == NULL || comments == NULL ||
      ids == NULL || capacity <= 0 || has_more == NULL ||
      !RIME_PROVIDED(api, candidate_list_begin)) return -1;

  RimeCandidateListIterator iterator = {0};
  Bool initialized = False;
  if (RIME_PROVIDED(api, candidate_list_from_index) && offset <= INT32_MAX) {
    initialized = api->candidate_list_from_index(session, &iterator, (int)offset);
  } else {
    initialized = api->candidate_list_begin(session, &iterator);
    for (size_t index = 0; initialized && index < offset; ++index) {
      initialized = api->candidate_list_next(&iterator);
    }
  }

  Bool has_candidate =
      initialized ? api->candidate_list_next(&iterator) : False;
  int count = 0;
  while (has_candidate && count < capacity) {
    RimeCandidate *candidate = &iterator.candidate;
    texts[count] = strdup(candidate->text != NULL ? candidate->text : "");
    comments[count] = candidate->comment != NULL ? strdup(candidate->comment) : NULL;
    ids[count] = (uint64_t)iterator.index;
    ++count;
    has_candidate = api->candidate_list_next(&iterator);
  }
  *has_more = has_candidate ? 1 : 0;
  api->candidate_list_end(&iterator);
  return count;
}

int feather_rime_select_candidate(uintptr_t session, uint64_t index) {
  if (api == NULL || session == 0 || !RIME_PROVIDED(api, select_candidate)) return 0;
  return api->select_candidate(session, (size_t)index);
}

void feather_rime_free_string(char *text) { free(text); }
