// CS Mix audio engine — C API consumed from Dart through FFI.
#pragma once
#include <stdint.h>

#if defined(_WIN32)
#define CSA_API __declspec(dllexport)
#else
#define CSA_API __attribute__((visibility("default"))) __attribute__((used))
#endif

#ifdef __cplusplus
extern "C" {
#endif

// Transition types.
#define CSA_FX_FADE 0
#define CSA_FX_REVERSE 1
#define CSA_FX_BRAKE 2
#define CSA_FX_CUT 3

// Deck load states.
#define CSA_DECK_EMPTY 0
#define CSA_DECK_LOADING 1
#define CSA_DECK_READY 2
#define CSA_DECK_ERROR -1

typedef struct {
  int32_t state;     // CSA_DECK_*
  int32_t playing;   // 1 while the deck advances
  int32_t ended;     // set once the deck reached the end of the track
  int32_t pfl;       // 1 when sent to the cue (pre-listen) output
  double position;   // seconds
  double duration;   // seconds
  float rate;        // effective playback rate (negative while reversing)
  float level;       // peak of the last audio block, 0..1
} CsaDeckInfo;

typedef struct {
  double duration;   // seconds
  float bpm;         // 0 when no tempo was found
  float gain_db;     // suggested gain to level tracks against each other
  float intro_sec;   // first strong hit after the intro
  float loud_db;     // loudness of the loud parts (dBFS RMS)
  int32_t key;       // 0..11 major (C..B), 12..23 minor (Cm..Bm), -1 unknown
  float key_conf;    // correlation of the best key profile, 0..1
  float onset_rate;  // detected hits per second
  float pulse;       // how clear the beat is, 0..1
  float brightness;  // spectral centroid of the loud parts, 0..1 (0 Hz .. 5.5 kHz)
} CsaAnalysis;

// Lifecycle.
CSA_API int32_t csa_init(void);
CSA_API void csa_shutdown(void);
CSA_API int32_t csa_last_error(char* buf, int32_t len);

// Output devices (desktop enumeration; Android passes AudioDeviceInfo ids instead).
CSA_API int32_t csa_device_count(void);
CSA_API int32_t csa_device_name(int32_t index, char* buf, int32_t len);  // returns 1 if default
// index -1 = system default. android_id > 0 overrides index (AAudio device id).
CSA_API int32_t csa_open_master(int32_t index, int32_t android_id);
CSA_API int32_t csa_open_cue(int32_t index, int32_t android_id);
CSA_API void csa_close_cue(void);
CSA_API int32_t csa_cue_open(void);
// 0 closed, 1 playing on its own device, 2 muted because the system moved it.
CSA_API int32_t csa_cue_status(void);
// Bit 1: master was rerouted, bit 2: cue was rerouted. Clears the bits.
CSA_API int32_t csa_take_route_events(void);

// Decks (0 = A, 1 = B).
CSA_API int32_t csa_deck_load(int32_t deck, const char* path_utf8, double start_sec);
CSA_API void csa_deck_unload(int32_t deck);
CSA_API void csa_deck_info(int32_t deck, CsaDeckInfo* out);
CSA_API void csa_deck_play(int32_t deck, int32_t play);
CSA_API void csa_deck_seek(int32_t deck, double sec);
CSA_API void csa_deck_set_pitch(int32_t deck, float delta);  // 0.015 = +1.5 %
CSA_API void csa_deck_set_gain_db(int32_t deck, float db);
CSA_API void csa_deck_set_pfl(int32_t deck, int32_t on);

// Mixer.
CSA_API void csa_set_crossfader(float x);  // 0 = A, 1 = B
CSA_API float csa_get_crossfader(void);
CSA_API void csa_set_curve(int32_t curve);  // 0 linear, 1 constant power
CSA_API void csa_transition(int32_t to_deck, int32_t type, float seconds);
CSA_API int32_t csa_transition_active(void);
CSA_API void csa_set_eq(int32_t band, float db);  // bands 0..4: 60, 230, 910, 3600, 14000 Hz
CSA_API void csa_set_master_volume(float v);
CSA_API void csa_set_cue_delay_ms(float ms);
CSA_API void csa_set_cue_mix(float m);  // 0 = only pre-listen decks, 1 = master
CSA_API void csa_test_tone(int32_t on);  // click on both outputs, for latency calibration

// Offline analysis (blocking: call from a background isolate).
// peaks receives 30 values per second (up to max_peaks); returns the count written, <0 on error.
CSA_API int32_t csa_analyze(const char* path_utf8, CsaAnalysis* out, float* peaks, int32_t max_peaks);

// Chromaprint fingerprint of the first 120 s (for AcoustID). Writes a NUL-terminated
// base64 string into out; returns its length, <0 on error. duration_sec gets the track length.
CSA_API int32_t csa_fingerprint(const char* path_utf8, char* out, int32_t len, int32_t* duration_sec);

// Renders master output without a device (tests).
CSA_API void csa_render_offline(float* out, int32_t frames, float* cue_out);

#ifdef __cplusplus
}
#endif
