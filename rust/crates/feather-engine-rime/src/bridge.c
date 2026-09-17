#define _POSIX_C_SOURCE 200809L
#include <rime_api.h>
#include <stdint.h>
#include <stdio.h>
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

int feather_rime_set_page_size(uintptr_t session, const char *schema,
                               int page_size) {
  if (api == NULL || session == 0 || schema == NULL || page_size < 1 ||
      page_size > 9 || !RIME_PROVIDED(api, config_set_int))
    return 0;
  RimeConfig config = {0};
  if (!api->schema_open(schema, &config)) return 0;
  int configured = api->config_set_int(&config, "menu/page_size", page_size);
  api->config_close(&config);
  if (!configured || !api->select_schema(session, schema)) return 0;
  api->clear_composition(session);
  api->set_option(session, "simplification", True);
  return 1;
}

uintptr_t feather_rime_set_english_candidate_minimum(uintptr_t session,
                                                     const char *schema,
                                                     int minimum) {
  if (api == NULL || session == 0 || schema == NULL || minimum < 1 ||
      minimum > 12 || !RIME_PROVIDED(api, config_get_string) ||
      !RIME_PROVIDED(api, config_set_string) ||
      !RIME_PROVIDED(api, config_set_double) ||
      !RIME_PROVIDED(api, user_config_open))
    return 0;
  char pattern[32];
  int length = snprintf(pattern, sizeof(pattern), "^[A-Za-z]{%d,}$", minimum);
  if (length < 0 || (size_t)length >= sizeof(pattern)) return 0;

  RimeConfig deployed = {0};
  if (!api->schema_open(schema, &deployed)) return 0;
  char current_pattern[32] = {0};
  int already_configured = api->config_get_string(
      &deployed, "recognizer/patterns/feather_english", current_pattern,
      sizeof(current_pattern));
  api->config_close(&deployed);
  if (!already_configured || strcmp(current_pattern, pattern) != 0) {
    char custom_id[128];
    length = snprintf(custom_id, sizeof(custom_id), "%s.custom", schema);
    if (length < 0 || (size_t)length >= sizeof(custom_id)) return 0;
    RimeConfig custom = {0};
    if (!api->user_config_open(custom_id, &custom)) return 0;
    int configured =
        api->config_set_string(&custom, "patch/schema/dependencies/@next",
                               "feather_english") &&
        api->config_set_string(
            &custom, "patch/engine/translators/@next",
            "table_translator@feather_english") &&
        api->config_set_string(
            &custom, "patch/feather_english/__include",
            "feather_english.schema:/translator") &&
        api->config_set_double(&custom,
                               "patch/feather_english/initial_quality",
                               -1.0) &&
        api->config_set_string(
            &custom, "patch/recognizer/patterns/feather_english", pattern) &&
        api->config_set_string(&custom,
                               "patch/recognizer/patterns/uppercase", "") &&
        api->config_set_string(
            &custom, "patch/speller/alphabet",
            "zyxwvutsrqponmlkjihgfedcbaZYXWVUTSRQPONMLKJIHGFEDCBA");
    api->config_close(&custom);
    if (!configured) return 0;
    if (api->start_maintenance(False)) api->join_maintenance_thread();
  }

  RimeConfig live = {0};
  if (!api->schema_open(schema, &live)) return 0;
  int live_configured = api->config_set_string(
      &live, "recognizer/patterns/feather_english", pattern);
  api->config_close(&live);
  if (!live_configured) return 0;

  uintptr_t replacement = api->create_session();
  if (replacement == 0) return 0;
  if (!api->select_schema(replacement, schema)) {
    api->destroy_session(replacement);
    return 0;
  }
  api->set_option(replacement, "simplification", True);
  api->destroy_session(session);
  return replacement;
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
