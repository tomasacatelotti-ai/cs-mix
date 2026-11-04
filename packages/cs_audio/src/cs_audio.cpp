// CS Mix audio engine.
//
// Layout
//   * Two decks. Each deck owns a loader thread that decodes the track in 4 s
//     chunks around the play head (more ahead than behind, following the play
//     direction), so the audio thread can read forwards, backwards and at any
//     speed without ever touching the decoder.
//   * One render pass (driven by the master device) mixes both decks through
//     the crossfader, applies the 5-band EQ and a soft limiter, and at the same
//     time builds the pre-listen (cue) signal, which goes into a ring buffer.
//   * The cue device plays that ring buffer with an adjustable delay, which is
//     how the Bluetooth latency of the master speaker is compensated.
//   * Transitions are automated on the audio thread so they are sample accurate.

#include "cs_audio.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#if defined(_WIN32)
#include <windows.h>
#endif

#include "miniaudio.h"

namespace {

constexpr int kOutSr = 48000;
constexpr double kChunkSec = 4.0;
constexpr double kAheadSec = 40.0;
constexpr double kBehindSec = 12.0;
constexpr double kKeepAheadSec = 90.0;
constexpr double kKeepBehindSec = 60.0;
constexpr int kMaxBlock = 1024;
constexpr double kPi = 3.14159265358979323846;

double nowSec() {
  return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count();
}

std::mutex gErrMutex;
std::string gErr;
void setError(const std::string& e) {
  std::lock_guard<std::mutex> lk(gErrMutex);
  gErr = e;
}

ma_result openDecoder(const char* path, const ma_decoder_config* cfg, ma_decoder* dec) {
#if defined(_WIN32)
  int n = MultiByteToWideChar(CP_UTF8, 0, path, -1, nullptr, 0);
  if (n <= 0) return MA_INVALID_ARGS;
  std::wstring w(static_cast<size_t>(n), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, path, -1, &w[0], n);
  return ma_decoder_init_file_w(w.c_str(), cfg, dec);
#else
  return ma_decoder_init_file(path, cfg, dec);
#endif
}

// ---------------------------------------------------------------------------
// Tracks and chunk cache

struct Chunk {
  std::vector<float> data;  // interleaved stereo
  int64_t frames = 0;
};

struct Track {
  ma_decoder dec{};
  bool decOk = false;
  uint32_t sr = 44100;
  int64_t length = 0;
  int64_t chunkFrames = 0;
  int64_t nChunks = 0;
  int64_t startFrame = 0;
  int64_t decCursor = -1;  // loader thread only
  std::unique_ptr<std::atomic<Chunk*>[]> chunks;

  ~Track() {
    if (chunks) {
      for (int64_t i = 0; i < nChunks; ++i) delete chunks[i].load();
    }
    if (decOk) ma_decoder_uninit(&dec);
  }
};

// Freed objects wait here until the audio thread can no longer hold them.
struct Garbage {
  double t;
  Track* track;
  Chunk* chunk;
};
std::mutex gGarbageMutex;
std::vector<Garbage> gGarbage;

void retire(Track* t, Chunk* c) {
  if (!t && !c) return;
  std::lock_guard<std::mutex> lk(gGarbageMutex);
  gGarbage.push_back({nowSec(), t, c});
}

void collectGarbage(bool all) {
  std::vector<Garbage> dead;
  {
    std::lock_guard<std::mutex> lk(gGarbageMutex);
    double now = nowSec();
    auto it = std::partition(gGarbage.begin(), gGarbage.end(),
                             [&](const Garbage& g) { return !all && now - g.t < 2.0; });
    dead.assign(it, gGarbage.end());
    gGarbage.erase(it, gGarbage.end());
  }
  for (auto& g : dead) {
    delete g.track;
    delete g.chunk;
  }
}

inline void frameAt(const Track* t, int64_t f, float& l, float& r) {
  if (f < 0 || f >= t->length) {
    l = r = 0.f;
    return;
  }
  int64_t ci = f / t->chunkFrames;
  const Chunk* c = t->chunks[ci].load(std::memory_order_acquire);
  if (!c) {
    l = r = 0.f;
    return;
  }
  int64_t o = f - ci * t->chunkFrames;
  if (o >= c->frames) {
    l = r = 0.f;
    return;
  }
  l = c->data[static_cast<size_t>(o * 2)];
  r = c->data[static_cast<size_t>(o * 2 + 1)];
}

inline float hermite(float xm1, float x0, float x1, float x2, float t) {
  float c = (x1 - xm1) * 0.5f;
  float v = x0 - x1;
  float w = c + v;
  float a = w + v + (x2 - x0) * 0.5f;
  float b = w + a;
  return (((a * t) - b) * t + c) * t + x0;
}

// ---------------------------------------------------------------------------
// Decks

struct Deck {
  // Shared with the Dart side / loader.
  std::atomic<Track*> track{nullptr};
  std::atomic<int> state{CSA_DECK_EMPTY};
  std::atomic<bool> playing{false};
  std::atomic<bool> ended{false};
  std::atomic<double> seekReq{-1.0};
  std::atomic<float> pitch{0.f};
  std::atomic<float> gain{1.f};
  std::atomic<bool> pfl{false};
  std::atomic<double> posSec{0.0};
  std::atomic<double> durSec{0.0};
  std::atomic<float> rateOut{0.f};
  std::atomic<float> level{0.f};
  std::atomic<int> dir{1};
  std::atomic<float> fxRate{1.f};  // set by transitions (reverse = -1, brake ramps to 0)

  // Audio thread only.
  Track* cur = nullptr;
  double pos = 0.0;
  float gainCur = 1.f;

  // Loader thread.
  std::thread th;
  std::mutex m;
  std::condition_variable cv;
  std::string pendingPath;
  double pendingStart = 0.0;
  bool hasPending = false;
  bool unload = false;
  bool quit = false;
};

void decodeChunk(Track* t, int64_t idx) {
  int64_t frame0 = idx * t->chunkFrames;
  int64_t n = std::min(t->chunkFrames, t->length - frame0);
  if (n <= 0) return;
  if (t->decCursor != frame0) {
    if (ma_decoder_seek_to_pcm_frame(&t->dec, static_cast<ma_uint64>(frame0)) != MA_SUCCESS) return;
  }
  auto* c = new Chunk();
  c->data.assign(static_cast<size_t>(n * 2), 0.f);
  ma_uint64 got = 0;
  ma_decoder_read_pcm_frames(&t->dec, c->data.data(), static_cast<ma_uint64>(n), &got);
  t->decCursor = frame0 + static_cast<int64_t>(got);
  c->frames = n;
  t->chunks[idx].store(c, std::memory_order_release);
}

bool loaderInterrupted(Deck* d) {
  std::lock_guard<std::mutex> lk(d->m);
  return d->quit || d->hasPending || d->unload;
}

void prefetch(Deck* d, Track* t) {
  double center = d->posSec.load() * t->sr;
  bool fwd = d->dir.load() >= 0;
  double ahead = kAheadSec * t->sr, behind = kBehindSec * t->sr;
  int64_t c0 = static_cast<int64_t>(std::max(0.0, center)) / t->chunkFrames;
  int64_t lo = static_cast<int64_t>(std::max(0.0, center - (fwd ? behind : ahead))) / t->chunkFrames;
  int64_t hi = std::min(t->nChunks - 1, static_cast<int64_t>(std::max(0.0, center + (fwd ? ahead : behind))) / t->chunkFrames);
  c0 = std::min(c0, t->nChunks - 1);

  // Order: current chunk, then outward in the play direction first.
  std::vector<int64_t> order;
  order.push_back(c0);
  int64_t maxSpan = std::max(hi - c0, c0 - lo);
  for (int64_t k = 1; k <= maxSpan; ++k) {
    int64_t a = fwd ? c0 + k : c0 - k;
    int64_t b = fwd ? c0 - k : c0 + k;
    if (a >= lo && a <= hi) order.push_back(a);
    if (b >= lo && b <= hi && k * 3 <= maxSpan * 2) order.push_back(b);
  }
  for (int64_t idx : order) {
    if (idx < 0 || idx >= t->nChunks) continue;
    if (!t->chunks[idx].load(std::memory_order_acquire)) {
      decodeChunk(t, idx);
      if (loaderInterrupted(d)) return;
      // Re-center if the play head jumped (seek, hot cue).
      double nc = d->posSec.load() * t->sr;
      if (std::fabs(nc - center) > t->chunkFrames * 2.0) return;
    }
  }
  // Evict what is far from the play head.
  double keepLo = center - (fwd ? kKeepBehindSec : kKeepAheadSec) * t->sr;
  double keepHi = center + (fwd ? kKeepAheadSec : kKeepBehindSec) * t->sr;
  for (int64_t i = 0; i < t->nChunks; ++i) {
    double s = static_cast<double>(i * t->chunkFrames);
    double e = s + t->chunkFrames;
    if (e < keepLo || s > keepHi) {
      Chunk* c = t->chunks[i].exchange(nullptr, std::memory_order_acq_rel);
      if (c) retire(nullptr, c);
    }
  }
}

void doLoad(Deck* d, const std::string& path, double startSec) {
  d->state.store(CSA_DECK_LOADING);
  d->playing.store(false);
  d->ended.store(false);
  auto* t = new Track();
  ma_decoder_config cfg = ma_decoder_config_init(ma_format_f32, 2, 0);
  cfg.seekPointCount = 4096;
  if (openDecoder(path.c_str(), &cfg, &t->dec) != MA_SUCCESS) {
    delete t;
    setError("No se pudo abrir: " + path);
    d->state.store(CSA_DECK_ERROR);
    return;
  }
  t->decOk = true;
  t->sr = t->dec.outputSampleRate ? t->dec.outputSampleRate : 44100;
  ma_uint64 len = 0;
  ma_decoder_get_length_in_pcm_frames(&t->dec, &len);
  if (len == 0) {
    delete t;
    setError("No se pudo leer la duración: " + path);
    d->state.store(CSA_DECK_ERROR);
    return;
  }
  t->length = static_cast<int64_t>(len);
  t->chunkFrames = static_cast<int64_t>(kChunkSec * t->sr);
  t->nChunks = (t->length + t->chunkFrames - 1) / t->chunkFrames;
  t->chunks.reset(new std::atomic<Chunk*>[static_cast<size_t>(t->nChunks)]);
  for (int64_t i = 0; i < t->nChunks; ++i) t->chunks[i].store(nullptr);
  t->startFrame = std::clamp<int64_t>(static_cast<int64_t>(startSec * t->sr), 0, t->length - 1);

  int64_t c0 = t->startFrame / t->chunkFrames;
  decodeChunk(t, c0);
  if (c0 + 1 < t->nChunks) decodeChunk(t, c0 + 1);

  d->posSec.store(static_cast<double>(t->startFrame) / t->sr);
  d->durSec.store(static_cast<double>(t->length) / t->sr);
  d->dir.store(1);
  d->fxRate.store(1.f);
  Track* old = d->track.exchange(t, std::memory_order_acq_rel);
  retire(old, nullptr);
  d->state.store(CSA_DECK_READY);
}

void loaderLoop(Deck* d) {
  for (;;) {
    std::string path;
    double start = 0;
    bool load = false, unload = false;
    {
      std::unique_lock<std::mutex> lk(d->m);
      d->cv.wait_for(lk, std::chrono::milliseconds(40), [&] { return d->quit || d->hasPending || d->unload; });
      if (d->quit) return;
      if (d->hasPending) {
        path = d->pendingPath;
        start = d->pendingStart;
        d->hasPending = false;
        load = true;
      }
      if (d->unload) {
        d->unload = false;
        unload = !load;
      }
    }
    if (unload) {
      d->playing.store(false);
      Track* old = d->track.exchange(nullptr, std::memory_order_acq_rel);
      retire(old, nullptr);
      d->state.store(CSA_DECK_EMPTY);
      d->durSec.store(0);
      d->posSec.store(0);
    }
    if (load) doLoad(d, path, start);
    Track* t = d->track.load(std::memory_order_acquire);
    if (t) prefetch(d, t);
    collectGarbage(false);
  }
}

// ---------------------------------------------------------------------------
// EQ

struct Biquad {
  double b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0;
  double z1[2] = {0, 0}, z2[2] = {0, 0};

  inline float run(int ch, float x) {
    double y = b0 * x + z1[ch];
    z1[ch] = b1 * x - a1 * y + z2[ch];
    z2[ch] = b2 * x - a2 * y;
    return static_cast<float>(y);
  }
};

// RBJ cookbook: type 0 peaking, 1 low shelf, 2 high shelf.
void designBiquad(Biquad& q, int type, double f0, double db, double Q) {
  double A = std::pow(10.0, db / 40.0);
  double w0 = 2 * kPi * f0 / kOutSr;
  double cw = std::cos(w0), sw = std::sin(w0);
  double alpha = sw / (2 * Q);
  double b0, b1, b2, a0, a1, a2;
  if (type == 0) {
    b0 = 1 + alpha * A; b1 = -2 * cw; b2 = 1 - alpha * A;
    a0 = 1 + alpha / A; a1 = -2 * cw; a2 = 1 - alpha / A;
  } else {
    double sq = 2 * std::sqrt(A) * alpha;
    if (type == 1) {
      b0 = A * ((A + 1) - (A - 1) * cw + sq);
      b1 = 2 * A * ((A - 1) - (A + 1) * cw);
      b2 = A * ((A + 1) - (A - 1) * cw - sq);
      a0 = (A + 1) + (A - 1) * cw + sq;
      a1 = -2 * ((A - 1) + (A + 1) * cw);
      a2 = (A + 1) + (A - 1) * cw - sq;
    } else {
      b0 = A * ((A + 1) + (A - 1) * cw + sq);
      b1 = -2 * A * ((A - 1) + (A + 1) * cw);
      b2 = A * ((A + 1) + (A - 1) * cw - sq);
      a0 = (A + 1) - (A - 1) * cw + sq;
      a1 = 2 * ((A - 1) - (A + 1) * cw);
      a2 = (A + 1) - (A - 1) * cw - sq;
    }
  }
  q.b0 = b0 / a0; q.b1 = b1 / a0; q.b2 = b2 / a0; q.a1 = a1 / a0; q.a2 = a2 / a0;
}

const double kEqFreq[5] = {60, 230, 910, 3600, 14000};
const int kEqType[5] = {1, 0, 0, 0, 2};

// ---------------------------------------------------------------------------
// Engine

struct Transition {
  bool active = false;
  int from = 0, to = 1, type = CSA_FX_FADE;
  double t = 0, dur = 1;
  float xfStart = 0.f;
  bool startedIn = false;
};

struct Engine {
  ma_context ctx{};
  bool ctxOk = false;
  ma_device master{};
  bool masterOk = false;
  ma_device cue{};
  bool cueOk = false;
  std::vector<ma_device_info> devices;
  std::mutex devMutex;

  Deck decks[2];

  std::atomic<float> xfader{0.f};
  float xfCur = 0.f;
  std::atomic<int> curve{1};
  std::atomic<float> masterVol{1.f};
  std::atomic<float> eqDb[5];
  std::atomic<int> eqDirty{1};
  Biquad eq[5];

  std::atomic<int> trSeq{0};
  int trSeen = 0;
  std::atomic<int> trTo{1}, trType{0};
  std::atomic<float> trSec{4.f};
  std::atomic<int> trActive{0};
  Transition tr;

  // Cue ring buffer (stereo frames).
  std::vector<float> ring;
  int64_t ringFrames = kOutSr * 2;
  std::atomic<int64_t> wpos{0}, rpos{0};
  bool cuePrimed = false;
  std::atomic<float> cueDelayMs{200.f};
  std::atomic<float> cueMix{0.f};
  std::atomic<bool> cueRingOn{false};

  std::atomic<bool> tone{false};
  int64_t toneClock = 0;

  float bufA[kMaxBlock * 2], bufB[kMaxBlock * 2], cueBuf[kMaxBlock * 2];

  Engine() {
    for (auto& e : eqDb) e.store(0.f);
    ring.assign(static_cast<size_t>(ringFrames * 2), 0.f);
  }
};

Engine* gEng = nullptr;
std::mutex gApiMutex;

void renderDeck(Deck& d, float* out, int frames) {
  Track* t = d.track.load(std::memory_order_acquire);
  if (t != d.cur) {
    d.cur = t;
    if (t) d.pos = static_cast<double>(t->startFrame);
  }
  double sk = d.seekReq.exchange(-1.0);
  if (sk >= 0 && t) {
    d.pos = std::clamp(sk * t->sr, 0.0, static_cast<double>(t->length - 1));
    d.ended.store(false);
  }
  float g1 = d.gain.load();
  float g0 = d.gainCur;
  d.gainCur = g1;
  float peak = 0.f;
  bool ready = t && d.state.load() == CSA_DECK_READY;
  float rate = (1.f + d.pitch.load()) * d.fxRate.load();
  if (!ready || !d.playing.load()) {
    std::memset(out, 0, sizeof(float) * frames * 2);
    d.rateOut.store(0.f);
    if (t) d.posSec.store(d.pos / t->sr);
    d.level.store(0.f);
    return;
  }
  double step = static_cast<double>(rate) * t->sr / kOutSr;
  for (int i = 0; i < frames; ++i) {
    double p = d.pos;
    int64_t f = static_cast<int64_t>(std::floor(p));
    float fr = static_cast<float>(p - f);
    float l0, r0, l1, r1, l2, r2, l3, r3;
    frameAt(t, f - 1, l0, r0);
    frameAt(t, f, l1, r1);
    frameAt(t, f + 1, l2, r2);
    frameAt(t, f + 2, l3, r3);
    float g = g0 + (g1 - g0) * (static_cast<float>(i) / frames);
    float l = hermite(l0, l1, l2, l3, fr) * g;
    float r = hermite(r0, r1, r2, r3, fr) * g;
    out[i * 2] = l;
    out[i * 2 + 1] = r;
    peak = std::max(peak, std::max(std::fabs(l), std::fabs(r)));
    d.pos += step;
    if (d.pos >= static_cast<double>(t->length)) {
      d.pos = static_cast<double>(t->length - 1);
      d.playing.store(false);
      d.ended.store(true);
      std::memset(out + (i + 1) * 2, 0, sizeof(float) * (frames - i - 1) * 2);
      break;
    }
    if (d.pos < 0) {  // reversed past the start of the track
      d.pos = 0;
      d.playing.store(false);
      std::memset(out + (i + 1) * 2, 0, sizeof(float) * (frames - i - 1) * 2);
      break;
    }
  }
  d.rateOut.store(rate);
  d.dir.store(rate < 0 ? -1 : 1);
  d.posSec.store(d.pos / t->sr);
  d.level.store(peak);
}

inline void curveGains(int curve, float x, float& ga, float& gb) {
  x = std::clamp(x, 0.f, 1.f);
  if (curve == 0) {
    ga = 1.f - x;
    gb = x;
  } else {
    ga = std::cos(x * static_cast<float>(kPi) * 0.5f);
    gb = std::sin(x * static_cast<float>(kPi) * 0.5f);
  }
}

inline float softLimit(float x) {
  float a = std::fabs(x);
  if (a <= 0.9f) return x;
  float y = 0.9f + 0.1f * std::tanh((a - 0.9f) / 0.1f);
  return x < 0 ? -y : y;
}

// Advances the transition automation by one block; returns the crossfader target.
float stepTransition(Engine& e, int frames) {
  int seq = e.trSeq.load(std::memory_order_acquire);
  if (seq != e.trSeen) {
    e.trSeen = seq;
    Transition& t = e.tr;
    // A transition still running finishes instantly before the new one starts.
    if (t.active) {
      e.decks[t.from].playing.store(false);
      e.decks[t.from].fxRate.store(1.f);
      e.xfCur = t.to == 1 ? 1.f : 0.f;
    }
    t.active = true;
    t.to = std::clamp(e.trTo.load(), 0, 1);
    t.from = 1 - t.to;
    t.type = e.trType.load();
    t.dur = t.type == CSA_FX_CUT ? 0.015 : std::max(0.05, static_cast<double>(e.trSec.load()));
    t.t = 0;
    t.xfStart = e.xfCur;
    t.startedIn = false;
    e.trActive.store(1);
  }
  Transition& t = e.tr;
  if (!t.active) return e.xfader.load();

  t.t += static_cast<double>(frames) / kOutSr;
  float p = static_cast<float>(std::min(1.0, t.t / t.dur));
  float xt = t.to == 1 ? 1.f : 0.f;
  float q = p;
  float startAt = 0.f;
  Deck& out = e.decks[t.from];
  switch (t.type) {
    case CSA_FX_REVERSE:
      out.fxRate.store(-1.f);
      break;
    case CSA_FX_BRAKE:
      out.fxRate.store(std::pow(std::max(0.f, 1.f - p), 1.6f));
      q = std::clamp((p - 0.55f) / 0.45f, 0.f, 1.f);
      startAt = 0.5f;
      break;
    default:
      break;
  }
  if (!t.startedIn && p >= startAt) {
    t.startedIn = true;
    e.decks[t.to].ended.store(false);
    e.decks[t.to].playing.store(true);
  }
  float xf = t.xfStart + (xt - t.xfStart) * q;
  if (p >= 1.f) {
    xf = xt;
    out.playing.store(false);
    out.fxRate.store(1.f);
    t.active = false;
    e.trActive.store(0);
  }
  e.xfader.store(xf);
  return xf;
}

void renderBlock(Engine& e, float* out, int frames, float* cueOut) {
  if (e.eqDirty.exchange(0)) {
    for (int b = 0; b < 5; ++b) {
      Biquad q = e.eq[b];
      designBiquad(q, kEqType[b], kEqFreq[b], e.eqDb[b].load(), b == 0 || b == 4 ? 0.707 : 1.0);
      e.eq[b].b0 = q.b0; e.eq[b].b1 = q.b1; e.eq[b].b2 = q.b2; e.eq[b].a1 = q.a1; e.eq[b].a2 = q.a2;
    }
  }
  float xfTarget = stepTransition(e, frames);
  renderDeck(e.decks[0], e.bufA, frames);
  renderDeck(e.decks[1], e.bufB, frames);
  int curve = e.curve.load();
  float vol = e.masterVol.load();
  bool pflA = e.decks[0].pfl.load(), pflB = e.decks[1].pfl.load();
  float cueMix = e.cueMix.load();
  bool tone = e.tone.load();
  float x0 = e.xfCur;
  bool eqFlat = true;
  for (int b = 0; b < 5; ++b) eqFlat = eqFlat && std::fabs(e.eqDb[b].load()) < 0.01f;

  for (int i = 0; i < frames; ++i) {
    float x = x0 + (xfTarget - x0) * (static_cast<float>(i + 1) / frames);
    float ga, gb;
    curveGains(curve, x, ga, gb);
    float l = e.bufA[i * 2] * ga + e.bufB[i * 2] * gb;
    float r = e.bufA[i * 2 + 1] * ga + e.bufB[i * 2 + 1] * gb;
    if (!eqFlat) {
      for (int b = 0; b < 5; ++b) {
        l = e.eq[b].run(0, l);
        r = e.eq[b].run(1, r);
      }
    }
    float click = 0.f;
    if (tone) {
      int64_t ph = e.toneClock % (kOutSr / 2);
      if (ph < kOutSr / 50) click = 0.5f * std::sin(2 * static_cast<float>(kPi) * 1000.f * ph / kOutSr);
      e.toneClock++;
    }
    l = softLimit(l * vol + click);
    r = softLimit(r * vol + click);
    out[i * 2] = l;
    out[i * 2 + 1] = r;

    float cl = (pflA ? e.bufA[i * 2] : 0.f) + (pflB ? e.bufB[i * 2] : 0.f);
    float cr = (pflA ? e.bufA[i * 2 + 1] : 0.f) + (pflB ? e.bufB[i * 2 + 1] : 0.f);
    cl = softLimit(cl * (1.f - cueMix) + l * cueMix + click);
    cr = softLimit(cr * (1.f - cueMix) + r * cueMix + click);
    e.cueBuf[i * 2] = cl;
    e.cueBuf[i * 2 + 1] = cr;
  }
  e.xfCur = xfTarget;

  if (cueOut) std::memcpy(cueOut, e.cueBuf, sizeof(float) * frames * 2);
  if (e.cueRingOn.load()) {
    int64_t w = e.wpos.load(std::memory_order_relaxed);
    int64_t r = e.rpos.load(std::memory_order_acquire);
    if (w - r + frames <= e.ringFrames) {
      for (int i = 0; i < frames; ++i) {
        int64_t k = ((w + i) % e.ringFrames) * 2;
        e.ring[static_cast<size_t>(k)] = e.cueBuf[i * 2];
        e.ring[static_cast<size_t>(k + 1)] = e.cueBuf[i * 2 + 1];
      }
      e.wpos.store(w + frames, std::memory_order_release);
    }
  }
}

void renderMaster(Engine& e, float* out, int frames, float* cueOut) {
  int done = 0;
  while (done < frames) {
    int n = std::min(kMaxBlock, frames - done);
    renderBlock(e, out + done * 2, n, cueOut ? cueOut + done * 2 : nullptr);
    done += n;
  }
}

void renderCue(Engine& e, float* out, int frames) {
  int64_t w = e.wpos.load(std::memory_order_acquire);
  int64_t r = e.rpos.load(std::memory_order_relaxed);
  int64_t fill = w - r;
  int64_t target = static_cast<int64_t>(e.cueDelayMs.load() * kOutSr / 1000.0) + frames * 2;
  target = std::min(target, e.ringFrames - frames * 2);
  if (!e.cuePrimed) {
    if (fill < target) {
      std::memset(out, 0, sizeof(float) * frames * 2);
      return;
    }
    e.cuePrimed = true;
  }
  if (fill > target + kOutSr / 10) {  // delay shortened or we fell behind: jump
    r = w - target;
    fill = target;
  }
  if (fill < frames) {
    std::memset(out, 0, sizeof(float) * frames * 2);
    e.cuePrimed = false;
    return;
  }
  for (int i = 0; i < frames; ++i) {
    int64_t k = ((r + i) % e.ringFrames) * 2;
    out[i * 2] = e.ring[static_cast<size_t>(k)];
    out[i * 2 + 1] = e.ring[static_cast<size_t>(k + 1)];
  }
  r += frames;
  // Slow drift correction between the two device clocks.
  if (fill > target + kOutSr / 100) r += 1;
  else if (fill < target - kOutSr / 100 && fill > frames + 1) r -= 1;
  e.rpos.store(r, std::memory_order_release);
}

void cbMaster(ma_device* dev, void* out, const void*, ma_uint32 frames) {
  auto* e = static_cast<Engine*>(dev->pUserData);
  renderMaster(*e, static_cast<float*>(out), static_cast<int>(frames), nullptr);
}

void cbCue(ma_device* dev, void* out, const void*, ma_uint32 frames) {
  auto* e = static_cast<Engine*>(dev->pUserData);
  renderCue(*e, static_cast<float*>(out), static_cast<int>(frames));
}

int32_t openDevice(Engine& e, ma_device& dev, bool& ok, int32_t index, int32_t androidId, ma_device_data_proc cb) {
  if (ok) {
    ma_device_uninit(&dev);
    ok = false;
  }
  ma_device_config cfg = ma_device_config_init(ma_device_type_playback);
  cfg.playback.format = ma_format_f32;
  cfg.playback.channels = 2;
  cfg.sampleRate = kOutSr;
  cfg.dataCallback = cb;
  cfg.pUserData = &e;
  cfg.periodSizeInMilliseconds = 10;
  cfg.performanceProfile = ma_performance_profile_low_latency;
  ma_device_id id;
  std::memset(&id, 0, sizeof(id));
  if (androidId > 0) {
    id.aaudio = androidId;
    cfg.playback.pDeviceID = &id;
  } else if (index >= 0) {
    std::lock_guard<std::mutex> lk(e.devMutex);
    if (index < static_cast<int32_t>(e.devices.size())) {
      id = e.devices[static_cast<size_t>(index)].id;
      cfg.playback.pDeviceID = &id;
    }
  }
  if (ma_device_init(e.ctxOk ? &e.ctx : nullptr, &cfg, &dev) != MA_SUCCESS) {
    setError("No se pudo abrir la salida de audio.");
    return -1;
  }
  if (ma_device_start(&dev) != MA_SUCCESS) {
    ma_device_uninit(&dev);
    setError("No se pudo iniciar la salida de audio.");
    return -2;
  }
  ok = true;
  return 0;
}

}  // namespace

// ---------------------------------------------------------------------------
// C API

extern "C" {

int32_t csa_init(void) {
  std::lock_guard<std::mutex> lk(gApiMutex);
  if (gEng) return 0;
  gEng = new Engine();
  gEng->ctxOk = ma_context_init(nullptr, 0, nullptr, &gEng->ctx) == MA_SUCCESS;
  for (auto& d : gEng->decks) d.th = std::thread(loaderLoop, &d);
  return gEng->ctxOk ? 0 : 1;
}

void csa_shutdown(void) {
  std::lock_guard<std::mutex> lk(gApiMutex);
  if (!gEng) return;
  if (gEng->cueOk) ma_device_uninit(&gEng->cue);
  if (gEng->masterOk) ma_device_uninit(&gEng->master);
  for (auto& d : gEng->decks) {
    {
      std::lock_guard<std::mutex> l2(d.m);
      d.quit = true;
    }
    d.cv.notify_all();
    if (d.th.joinable()) d.th.join();
    retire(d.track.exchange(nullptr), nullptr);
  }
  if (gEng->ctxOk) ma_context_uninit(&gEng->ctx);
  delete gEng;
  gEng = nullptr;
  collectGarbage(true);
}

int32_t csa_last_error(char* buf, int32_t len) {
  std::lock_guard<std::mutex> lk(gErrMutex);
  if (!buf || len <= 0) return static_cast<int32_t>(gErr.size());
  std::snprintf(buf, static_cast<size_t>(len), "%s", gErr.c_str());
  return static_cast<int32_t>(gErr.size());
}

int32_t csa_device_count(void) {
  if (!gEng || !gEng->ctxOk) return 0;
  ma_device_info* pb = nullptr;
  ma_uint32 n = 0;
  if (ma_context_get_devices(&gEng->ctx, &pb, &n, nullptr, nullptr) != MA_SUCCESS) return 0;
  std::lock_guard<std::mutex> lk(gEng->devMutex);
  gEng->devices.assign(pb, pb + n);
  return static_cast<int32_t>(n);
}

int32_t csa_device_name(int32_t index, char* buf, int32_t len) {
  if (!gEng) return 0;
  std::lock_guard<std::mutex> lk(gEng->devMutex);
  if (index < 0 || index >= static_cast<int32_t>(gEng->devices.size())) return 0;
  const auto& di = gEng->devices[static_cast<size_t>(index)];
  std::snprintf(buf, static_cast<size_t>(len), "%s", di.name);
  return di.isDefault ? 1 : 0;
}

int32_t csa_open_master(int32_t index, int32_t android_id) {
  if (!gEng) return -10;
  std::lock_guard<std::mutex> lk(gApiMutex);
  return openDevice(*gEng, gEng->master, gEng->masterOk, index, android_id, cbMaster);
}

int32_t csa_open_cue(int32_t index, int32_t android_id) {
  if (!gEng) return -10;
  std::lock_guard<std::mutex> lk(gApiMutex);
  gEng->cueRingOn.store(false);
  int32_t r = openDevice(*gEng, gEng->cue, gEng->cueOk, index, android_id, cbCue);
  if (r == 0) {
    gEng->rpos.store(gEng->wpos.load());
    gEng->cuePrimed = false;
    gEng->cueRingOn.store(true);
  }
  return r;
}

void csa_close_cue(void) {
  if (!gEng) return;
  std::lock_guard<std::mutex> lk(gApiMutex);
  gEng->cueRingOn.store(false);
  if (gEng->cueOk) ma_device_uninit(&gEng->cue);
  gEng->cueOk = false;
}

int32_t csa_cue_open(void) { return gEng && gEng->cueOk ? 1 : 0; }

int32_t csa_deck_load(int32_t deck, const char* path, double start_sec) {
  if (!gEng || deck < 0 || deck > 1 || !path) return -1;
  Deck& d = gEng->decks[deck];
  d.state.store(CSA_DECK_LOADING);
  {
    std::lock_guard<std::mutex> lk(d.m);
    d.pendingPath = path;
    d.pendingStart = start_sec;
    d.hasPending = true;
  }
  d.cv.notify_all();
  return 0;
}

void csa_deck_unload(int32_t deck) {
  if (!gEng || deck < 0 || deck > 1) return;
  Deck& d = gEng->decks[deck];
  {
    std::lock_guard<std::mutex> lk(d.m);
    d.unload = true;
  }
  d.cv.notify_all();
}

void csa_deck_info(int32_t deck, CsaDeckInfo* out) {
  if (!out) return;
  std::memset(out, 0, sizeof(*out));
  if (!gEng || deck < 0 || deck > 1) return;
  Deck& d = gEng->decks[deck];
  out->state = d.state.load();
  out->playing = d.playing.load() ? 1 : 0;
  out->ended = d.ended.load() ? 1 : 0;
  out->pfl = d.pfl.load() ? 1 : 0;
  out->position = d.posSec.load();
  out->duration = d.durSec.load();
  out->rate = d.rateOut.load();
  out->level = d.level.load();
}

void csa_deck_play(int32_t deck, int32_t play) {
  if (!gEng || deck < 0 || deck > 1) return;
  if (play) gEng->decks[deck].ended.store(false);
  gEng->decks[deck].playing.store(play != 0);
}

void csa_deck_seek(int32_t deck, double sec) {
  if (!gEng || deck < 0 || deck > 1) return;
  Deck& d = gEng->decks[deck];
  d.seekReq.store(std::max(0.0, sec));
  d.posSec.store(std::max(0.0, sec));
  d.cv.notify_all();
}

void csa_deck_set_pitch(int32_t deck, float delta) {
  if (!gEng || deck < 0 || deck > 1) return;
  gEng->decks[deck].pitch.store(std::clamp(delta, -0.5f, 0.5f));
}

void csa_deck_set_gain_db(int32_t deck, float db) {
  if (!gEng || deck < 0 || deck > 1) return;
  gEng->decks[deck].gain.store(std::pow(10.f, std::clamp(db, -24.f, 12.f) / 20.f));
}

void csa_deck_set_pfl(int32_t deck, int32_t on) {
  if (!gEng || deck < 0 || deck > 1) return;
  gEng->decks[deck].pfl.store(on != 0);
}

void csa_set_crossfader(float x) {
  if (!gEng || gEng->trActive.load()) return;
  gEng->xfader.store(std::clamp(x, 0.f, 1.f));
}

float csa_get_crossfader(void) { return gEng ? gEng->xfader.load() : 0.f; }

void csa_set_curve(int32_t curve) {
  if (gEng) gEng->curve.store(curve == 0 ? 0 : 1);
}

void csa_transition(int32_t to_deck, int32_t type, float seconds) {
  if (!gEng) return;
  gEng->trTo.store(to_deck);
  gEng->trType.store(std::clamp(type, 0, 3));
  gEng->trSec.store(seconds);
  gEng->trActive.store(1);
  gEng->trSeq.fetch_add(1, std::memory_order_release);
}

int32_t csa_transition_active(void) { return gEng ? gEng->trActive.load() : 0; }

void csa_set_eq(int32_t band, float db) {
  if (!gEng || band < 0 || band > 4) return;
  gEng->eqDb[band].store(std::clamp(db, -12.f, 12.f));
  gEng->eqDirty.store(1);
}

void csa_set_master_volume(float v) {
  if (gEng) gEng->masterVol.store(std::clamp(v, 0.f, 2.f));
}

void csa_set_cue_delay_ms(float ms) {
  if (gEng) gEng->cueDelayMs.store(std::clamp(ms, 0.f, 800.f));
}

void csa_set_cue_mix(float m) {
  if (gEng) gEng->cueMix.store(std::clamp(m, 0.f, 1.f));
}

void csa_test_tone(int32_t on) {
  if (!gEng) return;
  gEng->toneClock = 0;
  gEng->tone.store(on != 0);
}

void csa_render_offline(float* out, int32_t frames, float* cue_out) {
  if (!gEng || !out) return;
  renderMaster(*gEng, out, frames, cue_out);
}

// ---------------------------------------------------------------------------
// Analysis: loudness, overview peaks, tempo and intro.

int32_t csa_analyze(const char* path, CsaAnalysis* out, float* peaks, int32_t max_peaks) {
  if (!path || !out) return -1;
  std::memset(out, 0, sizeof(*out));
  constexpr int sr = 11025;
  constexpr int hop = 110;                 // ~100 onset frames per second
  constexpr int peakHop = sr / 30;         // 30 overview values per second
  constexpr int loudWin = sr * 4 / 10;     // 0.4 s loudness windows
  ma_decoder_config cfg = ma_decoder_config_init(ma_format_f32, 1, sr);
  ma_decoder dec;
  if (openDecoder(path, &cfg, &dec) != MA_SUCCESS) {
    setError(std::string("No se pudo abrir: ") + path);
    return -2;
  }

  std::vector<float> onsetLow, onsetFull, energyLow;
  std::vector<double> winRms;
  std::vector<float> buf(4096);
  int32_t nPeaks = 0;
  float peakAcc = 0.f;
  int peakCount = 0;
  double hopLow = 0, hopFull = 0;
  int hopCount = 0;
  double winAcc = 0;
  int winCount = 0;
  double lp = 0;
  const double lpA = 1.0 - std::exp(-2 * kPi * 180.0 / sr);
  int64_t total = 0;

  for (;;) {
    ma_uint64 got = 0;
    ma_decoder_read_pcm_frames(&dec, buf.data(), buf.size(), &got);
    if (got == 0) break;
    for (ma_uint64 i = 0; i < got; ++i) {
      float x = buf[i];
      lp += lpA * (x - lp);
      hopLow += lp * lp;
      hopFull += static_cast<double>(x) * x;
      if (++hopCount == hop) {
        energyLow.push_back(static_cast<float>(hopLow / hop));
        onsetFull.push_back(static_cast<float>(hopFull / hop));
        hopLow = hopFull = 0;
        hopCount = 0;
      }
      winAcc += static_cast<double>(x) * x;
      if (++winCount == loudWin) {
        winRms.push_back(std::sqrt(winAcc / loudWin));
        winAcc = 0;
        winCount = 0;
      }
      peakAcc = std::max(peakAcc, std::fabs(x));
      if (++peakCount == peakHop) {
        if (peaks && nPeaks < max_peaks) peaks[nPeaks++] = std::min(1.f, peakAcc);
        peakAcc = 0;
        peakCount = 0;
      }
    }
    total += static_cast<int64_t>(got);
  }
  ma_decoder_uninit(&dec);
  if (total < sr) {
    setError("Archivo demasiado corto.");
    return -3;
  }
  out->duration = static_cast<double>(total) / sr;

  // Loudness: 90th percentile of 0.4 s windows, so quiet intros do not count.
  float loudDb = -60.f;
  if (!winRms.empty()) {
    std::vector<double> s = winRms;
    std::sort(s.begin(), s.end());
    double v = s[static_cast<size_t>(s.size() * 0.9)];
    loudDb = static_cast<float>(20.0 * std::log10(std::max(v, 1e-6)));
  }
  out->loud_db = loudDb;
  out->gain_db = std::clamp(-11.f - loudDb, -12.f, 6.f);

  // Onset strength: positive log-energy differences, low band weighted.
  size_t n = energyLow.size();
  std::vector<float> onset(n, 0.f);
  for (size_t i = 1; i < n; ++i) {
    float dl = std::log1p(1000.f * energyLow[i]) - std::log1p(1000.f * energyLow[i - 1]);
    float df = std::log1p(1000.f * onsetFull[i]) - std::log1p(1000.f * onsetFull[i - 1]);
    onset[i] = std::max(0.f, dl) + 0.5f * std::max(0.f, df);
  }
  double mean = 0;
  for (float v : onset) mean += v;
  mean /= std::max<size_t>(1, n);
  for (float& v : onset) v = static_cast<float>(v - mean);

  // Autocorrelation over lags covering 4 beats at 70 BPM.
  const double fps = static_cast<double>(sr) / hop;
  int maxLag = static_cast<int>(fps * 60.0 / 70.0 * 4) + 2;
  std::vector<double> ac(static_cast<size_t>(maxLag + 1), 0.0);
  if (static_cast<int>(n) > maxLag * 2) {
    for (int L = 1; L <= maxLag; ++L) {
      double s = 0;
      for (size_t i = static_cast<size_t>(L); i < n; ++i) s += static_cast<double>(onset[i]) * onset[i - L];
      ac[static_cast<size_t>(L)] = s / (n - L);
    }
    auto acAt = [&](double lag) {
      int i = static_cast<int>(lag);
      if (i < 1 || i + 1 > maxLag) return 0.0;
      double f = lag - i;
      return ac[static_cast<size_t>(i)] * (1 - f) + ac[static_cast<size_t>(i + 1)] * f;
    };
    double best = -1e30, bestBpm = 0;
    for (double bpm = 70.0; bpm <= 180.0; bpm += 0.05) {
      double L = fps * 60.0 / bpm;
      double s = acAt(L) + 0.6 * acAt(2 * L) + 0.4 * acAt(3 * L) + 0.5 * acAt(4 * L) + 0.25 * acAt(L / 2);
      double oct = std::log2(bpm / 122.0) / 0.75;
      s *= std::exp(-0.5 * oct * oct);
      if (s > best) {
        best = s;
        bestBpm = bpm;
      }
    }
    // Refine: the beat grid must also line up 8 and 16 beats later, which pins
    // the tempo far more precisely than the first lag alone.
    if (best > 0) {
      int fineMaxLag = static_cast<int>(fps * 60.0 / (bestBpm - 2.0) * 16) + 2;
      if (static_cast<int>(n) > fineMaxLag * 2) {
        std::vector<double> ac2(static_cast<size_t>(fineMaxLag + 1), 0.0);
        int minLag = static_cast<int>(fps * 60.0 / (bestBpm + 2.0)) - 2;
        for (int L = std::max(1, minLag); L <= fineMaxLag; ++L) {
          double s = 0;
          for (size_t i = static_cast<size_t>(L); i < n; ++i) s += static_cast<double>(onset[i]) * onset[i - L];
          ac2[static_cast<size_t>(L)] = s / (n - L);
        }
        auto ac2At = [&](double lag) {
          int i = static_cast<int>(lag);
          if (i < 1 || i + 1 > fineMaxLag) return 0.0;
          double f = lag - i;
          return ac2[static_cast<size_t>(i)] * (1 - f) + ac2[static_cast<size_t>(i + 1)] * f;
        };
        double fineBest = -1e30, fineBpm = bestBpm;
        for (double bpm = bestBpm - 2.0; bpm <= bestBpm + 2.0; bpm += 0.01) {
          double L = fps * 60.0 / bpm;
          double sc = 0;
          for (int k = 1; k <= 16; ++k) sc += ac2At(k * L);
          if (sc > fineBest) {
            fineBest = sc;
            fineBpm = bpm;
          }
        }
        bestBpm = fineBpm;
      }
      // Most produced music sits on a whole BPM: snap when very close.
      double whole = std::round(bestBpm);
      if (std::fabs(bestBpm - whole) <= 0.15) bestBpm = whole;
      out->bpm = static_cast<float>(std::round(bestBpm * 10.0) / 10.0);
    }
  }

  // Intro: first point where the low band reaches 30 % of its loud level,
  // pulled back to the closest onset just before it.
  float intro = 0.f;
  if (n > 10) {
    int win = static_cast<int>(fps / 2);
    std::vector<float> sm(n, 0.f);
    double acc = 0;
    for (size_t i = 0; i < n; ++i) {
      acc += energyLow[i];
      if (i >= static_cast<size_t>(win)) acc -= energyLow[i - win];
      sm[i] = static_cast<float>(acc / win);
    }
    std::vector<float> s2 = sm;
    std::sort(s2.begin(), s2.end());
    float loud = s2[static_cast<size_t>(s2.size() * 0.9)];
    // sm is a trailing average, so the hit that raised it lies in (cross - win, cross].
    size_t cross = 0;
    for (size_t i = 0; i < n; ++i) {
      if (sm[i] >= 0.3f * loud) {
        cross = i;
        break;
      }
    }
    size_t from = cross >= static_cast<size_t>(win) ? cross - win : 0;
    size_t bestI = cross;
    float bestO = -1.f;
    for (size_t i = from; i <= cross; ++i) {
      if (onset[i] > bestO + 1e-4f) {
        bestO = onset[i];
        bestI = i;
      }
    }
    intro = static_cast<float>(std::max<double>(0.0, (static_cast<double>(bestI) - 1) / fps));
    if (intro > out->duration * 0.5) intro = 0.f;
  }
  out->intro_sec = intro;
  return nPeaks;
}

}  // extern "C"
