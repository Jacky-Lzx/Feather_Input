#include "feather_ime.h"

static FeatherStatus create_session(FeatherIme **ime, FeatherError **error) {
    return feather_ime_new(ime, error);
}

static FeatherStatus activate_session(FeatherIme *ime,
                                      FeatherResponse **response,
                                      FeatherError **error) {
    return feather_ime_activate(ime, response, error);
}

int main(void) {
    FeatherIme *ime = NULL;
    FeatherError *error = NULL;
    FeatherResponse *response = NULL;
    FeatherStatus status = create_session(&ime, &error);

    if (status == FEATHER_STATUS_OK) {
        status = activate_session(ime, &response, &error);
    }
    FeatherCandidateSlice *slice = NULL;
    if (status == FEATHER_STATUS_OK) {
        status = feather_ime_candidate_slice(ime, response->revision, 0, 8,
                                             &slice, &error);
    }
    feather_ime_candidate_slice_free(slice);
    feather_ime_response_free(response);
    feather_error_free(error);
    (void)feather_ime_close(ime, NULL);
    feather_ime_free(ime);
    return status == FEATHER_STATUS_OK ? 0 : 1;
}
