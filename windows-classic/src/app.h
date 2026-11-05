// CS Mix Clásico: Windows 7 (32/64 bits) library server + player.
#pragma once
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>

#include <atomic>
#include <cstdint>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#define APP_NAME L"CS Mix Clásico"
#ifndef APP_VERSION
#define APP_VERSION "0.1"
#endif

// ---------------------------------------------------------------- util.cpp
std::string U8(const std::wstring& w);
std::wstring W(const std::string& s);
std::wstring Lower(const std::wstring& s);
std::string LowerU8(const std::string& s);
std::wstring Trim(const std::wstring& s);
std::string Trim8(const std::string& s);
std::string JsonStr(const std::string& s);
std::string JsonNum(double v);
std::string Fmt(const char* f, ...);
std::wstring FmtW(const wchar_t* f, ...);
std::wstring FmtTime(double sec);
uint64_t Fnv(const std::string& s);
std::string Hex(uint64_t v);
bool FileExists(const std::wstring& p);
bool DirExists(const std::wstring& p);
bool ReadAll(const std::wstring& p, std::string& out, size_t maxBytes = 64u << 20);
bool WriteAtomic(const std::wstring& p, const void* data, size_t len);
std::wstring ExePath();
std::wstring DataDir();  // %APPDATA%\CS Mix Clasico (created)
std::string UrlDecode(const std::string& s, bool plus);
int64_t NowMs();

// Settings (settings.ini, UTF-16).
std::wstring IniGet(const wchar_t* key, const wchar_t* def);
int IniInt(const wchar_t* key, int def);
double IniNum(const wchar_t* key, double def);
void IniSet(const wchar_t* key, const std::wstring& v);
void IniSetInt(const wchar_t* key, int v);
void IniSetNum(const wchar_t* key, double v);

// ---------------------------------------------------------------- tags.cpp
struct FileTags {
  std::string title, artist, genre;  // UTF-8, empty when missing
  std::string cover;                 // raw image bytes
};
FileTags ReadTags(const std::wstring& path);

// ---------------------------------------------------------------- library.cpp
struct Track {
  std::wstring path;  // full Windows path
  std::string rel;    // relative to the library root, '/' separated (UTF-8)
  std::string title, artist;
  int64_t size = 0, mtime = 0;

  double duration = 0, bpm = 0, gain = 0, intro = 0;
  bool analyzed = false, failed = false;
  int version = 0;
  int key = -1;
  double keyConf = 0, loud = 0, onset = 0, pulse = 0, bright = 0, energy = 0;
  std::string mood, genre;
  bool cover = false;

  int plays = 0, skips = 0;
  int64_t lastPlayed = 0;
  bool fixedName = false;
  double entry = -1;  // saved entry point, <0 = none

  std::string fileName() const;
  std::string dir() const;
  std::string folder(int sharedDepth) const;
  std::string label() const { return artist.empty() ? title : artist + " - " + title; }
};
using TrackP = std::shared_ptr<Track>;

struct Playlist {
  std::string id, name;
  std::wstring file;
  std::vector<TrackP> tracks;
};

constexpr int kAnalysisVersion = 2;
extern const char* kMoods[5];
std::string KeyName(int key);  // "8A · Am"

class Library {
 public:
  std::mutex m;  // guards everything below and every Track field
  std::vector<TrackP> tracks;
  std::vector<Playlist> playlists;
  std::wstring root;
  int sharedDepth = 0;
  std::string currentWork;  // what the worker is doing (UTF-8)

  std::atomic<int> revision{1};
  std::atomic<int> structure{1};  // bumped when the track list or the playlists change
  std::atomic<bool> scanning{false};
  std::atomic<int> analyzed{0};
  std::atomic<int> total{0};
  std::atomic<bool> paused{false};
  std::string scanError;

  void Start(const std::wstring& dataDir);
  void Stop();
  void SetRoot(const std::wstring& r);  // rescans
  void Rescan();
  void Prioritize(const TrackP& t);
  void Changed();  // bump revision + save soon
  void SaveIfDirty() {
    if (dirty_) SaveNow();
  }

  TrackP ByRel(const std::string& rel);
  std::wstring PeakPath(const Track& t) const;
  std::wstring CoverPath(const Track& t) const;
  std::vector<uint8_t> Peaks(const Track& t);
  void RecordPlay(const TrackP& t);
  void RecordSkip(const TrackP& t);
  std::shared_ptr<const std::string> LibraryJson(const std::string& name);

  static bool LooksMisnamed(const Track& t);

 private:
  void Worker();
  void DoScan();
  void LoadPlaylists();
  void Analyze(const TrackP& t);
  void Load();
  void SaveNow();
  void ComputeSharedDepth();

  std::wstring dataDir_;
  HANDLE wake_ = nullptr;
  std::atomic<bool> quit_{false};
  std::atomic<bool> scanWanted_{false};
  std::atomic<bool> dirty_{false};
  std::vector<TrackP> prio_;
  HANDLE thread_ = nullptr;
  std::map<std::wstring, std::vector<uint8_t>> peakCache_;
  std::vector<std::wstring> peakOrder_;
  std::shared_ptr<const std::string> json_;
  int jsonRev_ = -1;
  std::string jsonName_;
  friend DWORD WINAPI LibraryThread(void*);
};

extern Library gLib;

// ---------------------------------------------------------------- server.cpp
struct ShareClient {
  std::string ip, name, playing;
  int64_t lastSeen = 0;
};

class Server {
 public:
  bool Start(const std::string& pin, const std::string& name);
  void Stop();
  bool running() const { return listen_ != INVALID_SOCKET; }
  void SetPin(const std::string& p);
  void SetName(const std::string& n);
  std::vector<ShareClient> Clients();  // seen in the last 3 minutes
  std::vector<std::string> Addresses();
  std::string error;

 private:
  void AcceptLoop();
  void UdpLoop();
  void Handle(SOCKET s, const std::string& ip);
  friend DWORD WINAPI AcceptThread(void*);
  friend DWORD WINAPI UdpThread(void*);
  friend DWORD WINAPI ConnThread(void*);

  SOCKET listen_ = INVALID_SOCKET;
  SOCKET udp_ = INVALID_SOCKET;
  std::mutex m_;
  std::string pin_, name_;
  std::map<std::string, ShareClient> clients_;
};

extern Server gServer;

// ---------------------------------------------------------------- player.cpp
enum Fx { FX_FADE = 0, FX_REVERSE = 1, FX_BRAKE = 2, FX_CUT = 3 };

struct PlayerSettings {
  bool autoCrossfade = true;
  double autoSec = 6;
  double fxDur[4] = {4, 2, 1.5, 0};
  int entryMode = 0;  // 0 saved point (or intro), 1 skip intro, 2 from the start
  bool autoGain = true;
  bool shuffle = false;
  bool repeat = false;
};

struct DeckView {
  int state = 0;
  bool playing = false, ended = false;
  double position = 0, duration = 0;
  bool ready() const { return state == 2; }
  bool loading() const { return state == 1; }
  bool error() const { return state == -1; }
  double remaining() const { return duration > position ? duration - position : 0; }
};

class Player {
 public:
  PlayerSettings s;
  std::vector<TrackP> queue;
  int index = -1;
  int active = 0;
  int fx = FX_FADE;
  std::string source;
  double oneTimeEntry = -1;

  void PlayList(const std::vector<TrackP>& list, int start, const std::string& name);
  void PlayNow(const TrackP& t);
  void PlayAfterCurrent(const TrackP& t);
  void Enqueue(const TrackP& t);
  void RemoveAt(int i);
  void JumpTo(int i);
  void Clear();
  void TogglePlay();
  void Seek(double sec);
  void Previous();
  void PassNow();
  void Tick();  // every ~50 ms on the UI thread
  void ReapplyGain();

  TrackP Incoming() const { return incoming_; }
  TrackP Current() const { return index >= 0 && index < (int)queue.size() ? queue[index] : nullptr; }
  int NextIndex() const;
  TrackP Next() const;
  bool Playing() const;
  bool Transitioning() const { return transitioning_; }
  bool NextLoading() const;
  const DeckView& Deck(int d) const { return decks_[d]; }
  int Idle() const { return 1 - active; }
  double EntryFor(const Track& t) const;
  bool changed = true;  // UI should refresh the queue

 private:
  void Load(int deck, const TrackP& t, double start);
  void Unload(int deck);
  void PreloadNext();
  void StartTransition(int f, double sec);
  bool Ready(int deck, const TrackP& t) const;
  int InsertAt() const;
  void Poll();

  DeckView decks_[2];
  TrackP want_[2];
  bool pendingPlay_ = false;
  int pendingPass_ = -1;
  TrackP incoming_;
  bool transitioning_ = false;
  TrackP idleTrack_;
  TrackP counted_[2];
};

extern Player gPlayer;
