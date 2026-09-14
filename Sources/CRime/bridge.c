#include "bridge.h"
#include "rime_api.h"
#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>
static RimeApi *api;
static void *handle;
int feather_start(const char *library, const char *shared, const char *user) {
  handle = dlopen(library, RTLD_NOW | RTLD_LOCAL);
  if (!handle) return 0;
  RimeApi *(*get_api)(void) = dlsym(handle, "rime_get_api");
  if (!get_api) { dlclose(handle); handle = NULL; return 0; }
  api = get_api();
  RIME_STRUCT(RimeTraits, traits);
  traits.shared_data_dir = shared; traits.user_data_dir = user;
  traits.distribution_name = "FeatherInput";
  traits.distribution_code_name = "feather";
  traits.distribution_version = "0.1.0";
  traits.app_name = "rime.feather"; traits.min_log_level = 2;
  api->setup(&traits); api->initialize(&traits);
  if (api->start_maintenance(False)) api->join_maintenance_thread();
  return 1;
}
void feather_stop(void) { if (api) api->finalize(); api = NULL; /* Keep module code loaded until process exit. */ }
uintptr_t feather_session(const char *schema) {
  if (!api) return 0;
  uintptr_t s = api->create_session();
  if (!api->select_schema(s, schema)) { api->destroy_session(s); return 0; }
  api->set_option(s, "simplification", True); return s;
}
void feather_destroy(uintptr_t s) { if(api && s) api->destroy_session(s); }
int feather_key(uintptr_t s, int k, int m) { return api->process_key(s,k,m); }
void feather_clear(uintptr_t s) { api->clear_composition(s); }
void feather_commit(uintptr_t s) { api->commit_composition(s); }
int feather_select(uintptr_t s,const char *schema) { int ok=api->select_schema(s,schema); api->set_option(s,"simplification",True); return ok; }
void feather_ascii(uintptr_t s,int enabled) { api->set_option(s,"ascii_mode",enabled); }
char *feather_take_commit(uintptr_t s) {
  RIME_STRUCT(RimeCommit, c); if (!api->get_commit(s,&c)) return NULL;
  char *v=c.text ? strdup(c.text) : NULL; api->free_commit(&c); return v;
}
char *feather_preedit(uintptr_t s,int *cursor) {
  RIME_STRUCT(RimeContext,c); if(!api->get_context(s,&c)) return NULL;
  *cursor=c.composition.cursor_pos;
  char *v=c.composition.preedit ? strdup(c.composition.preedit) : NULL;
  api->free_context(&c); return v;
}
int feather_candidates(uintptr_t s,char **texts,int capacity,int *highlight) {
  RIME_STRUCT(RimeContext,c); if(!api->get_context(s,&c)) return 0;
  int n=c.menu.num_candidates < capacity ? c.menu.num_candidates : capacity;
  *highlight=c.menu.highlighted_candidate_index;
  for(int i=0;i<n;i++) texts[i]=strdup(c.menu.candidates[i].text);
  api->free_context(&c); return n;
}
void feather_free(char *text) { free(text); }
int feather_select_candidate(uintptr_t s, int index) {
  if (index < 0 || !RIME_PROVIDED(api, select_candidate_on_current_page)) return 0;
  return api->select_candidate_on_current_page(s, (size_t)index);
}

int feather_page_size(const char *schema, int count) {
  if (!api || count < 1 || count > 9 || !RIME_PROVIDED(api, config_set_int)) return 0;
  RimeConfig config = {0};
  if (!api->schema_open(schema, &config)) return 0;
  int ok = api->config_set_int(&config, "menu/page_size", count);
  api->config_close(&config);
  return ok;
}

int feather_candidate_slice(uintptr_t s, int offset, char **texts, int capacity) {
  if (offset < 0 || capacity <= 0 || !RIME_PROVIDED(api, candidate_list_from_index)) return 0;
  RimeCandidateListIterator it = {0};
  if (!api->candidate_list_from_index(s, &it, offset)) return 0;
  int n = 0;
  while (n < capacity && api->candidate_list_next(&it)) {
    texts[n++] = strdup(it.candidate.text ? it.candidate.text : "");
  }
  api->candidate_list_end(&it);
  return n;
}
int feather_select_global(uintptr_t s, int index) {
  if (index < 0 || !RIME_PROVIDED(api, select_candidate)) return 0;
  return api->select_candidate(s, (size_t)index);
}
int feather_candidate_page_offset(uintptr_t s) {
  RIME_STRUCT(RimeContext, context);
  if (!api->get_context(s, &context)) return 0;
  int offset = context.menu.page_no * context.menu.page_size;
  api->free_context(&context);
  return offset;
}
