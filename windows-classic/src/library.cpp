#include "app.h"
#include <shlobj.h>

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <set>
#include <unordered_map>

#include "../../packages/cs_audio/src/cs_audio.h"

Library gLib;

const char* kMoods[5] = {"Enérgico", "Festivo", "Intenso", "Melódico", "Tranquilo"};

static const char* kNotes[12] = {"C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"};
static const int kCamMajor[12] = {8, 3, 10, 5, 12, 7, 2, 9, 4, 11, 6, 1};
static const int kCamMinor[12] = {5, 12, 7, 2, 9, 4, 11, 6, 1, 8, 3, 10};

std::string KeyName(int key) {
  if (key < 0 || key > 23) return {};
  if (key < 12) return Fmt("%dB  %s", kCamMajor[key], kNotes[key]);
  return Fmt("%dA  %sm", kCamMinor[key - 12], kNotes[key - 12]);
}

// Same formulas as lib/core/models.dart, so the phone shows the same moods.
static double Clamp01(double v) { return v < 0 ? 0 : (v > 1 ? 1 : v); }

static double EnergyOf(double loudDb, double onsetRate, double bpm, double brightness) {
  double loud = Clamp01((loudDb + 20) / 14);
  double hits = Clamp01(onsetRate / 7);
  double tempo = bpm <= 0 ? 0.5 : Clamp01((bpm - 70) / 70);
  double bright = Clamp01(brightness / 0.35);
  return Clamp01(0.35 * loud + 0.3 * hits + 0.2 * tempo + 0.15 * bright);
}

static std::string MoodOf(double energy, double pulse, int key, double brightness) {
  bool minor = key >= 12;
  if (energy < 0.35) return kMoods[4];
  if (energy >= 0.62) {
    if (minor && brightness < 0.3) return kMoods[2];
    return pulse >= 0.3 && !minor ? kMoods[1] : kMoods[0];
  }
  if (pulse >= 0.32 && !minor) return kMoods[1];
  return minor ? kMoods[3] : (pulse < 0.22 ? kMoods[3] : kMoods[1]);
}

// ---------------------------------------------------------------- Track

std::string Track::fileName() const {
  size_t i = rel.find_last_of('/');
  return i == std::string::npos ? rel : rel.substr(i + 1);
}

std::string Track::dir() const {
  size_t i = rel.find_last_of('/');
  return i == std::string::npos ? std::string() : rel.substr(0, i);
}

std::string Track::folder(int depth) const {
  int seg = 0;
  size_t start = 0;
  for (;;) {
    size_t slash = rel.find('/', start);
    if (slash == std::string::npos) return {};  // the file itself, not a folder
    if (seg == depth) return rel.substr(start, slash - start);
    ++seg;
    start = slash + 1;
  }
}

static void ParseName(const std::string& file, std::string& artist, std::string& title) {
  std::string base = file;
  size_t dot = base.find_last_of('.');
  if (dot != std::string::npos && dot > 0) base = base.substr(0, dot);
  size_t sep = base.find(" - ");
  if (sep != std::string::npos && sep > 0) {
    artist = Trim8(base.substr(0, sep));
    title = Trim8(base.substr(sep + 3));
  } else {
    artist.clear();
    title = Trim8(base);
  }
}

bool Library::LooksMisnamed(const Track& t) {
  if (Trim8(t.artist).empty()) return true;
  std::wstring n = Trim(Lower(W(t.title)));
  if (n.empty()) return true;
  bool junk = true;
  for (wchar_t c : n) {
    if (!(iswdigit(c) || c == L' ' || c == L'_' || c == L'-' || c == L'.' || c == L'(' || c == L')')) junk = false;
  }
  if (junk) return true;
  static const wchar_t* words[] = {L"track", L"pista", L"audio", L"unknown", L"desconocido", L"sin título", L"sin titulo"};
  for (auto w : words) {
    size_t l = wcslen(w);
    if (n.compare(0, l, w) != 0) continue;
    bool rest = true;
    for (size_t i = l; i < n.size(); ++i) {
      if (!(iswdigit(n[i]) || n[i] == L' ')) rest = false;
    }
    if (rest) return true;
  }
  return false;
}

// ---------------------------------------------------------------- lifecycle

DWORD WINAPI LibraryThread(void* p) {
  static_cast<Library*>(p)->Worker();
  return 0;
}

void Library::Start(const std::wstring& dataDir) {
  dataDir_ = dataDir;
  Load();
  wake_ = CreateEventW(nullptr, FALSE, FALSE, nullptr);
  thread_ = CreateThread(nullptr, 0, LibraryThread, this, 0, nullptr);
}

void Library::Stop() {
  quit_ = true;
  if (wake_) SetEvent(wake_);
  if (thread_) {
    // An analysis can take a few seconds on a slow PC; don't hang the exit forever.
    WaitForSingleObject(thread_, 8000);
    CloseHandle(thread_);
    thread_ = nullptr;
  }
  if (dirty_) SaveNow();
}

void Library::SetRoot(const std::wstring& r) {
  {
    std::lock_guard<std::mutex> lk(m);
    root = r;
  }
  Rescan();
}

void Library::Rescan() {
  scanWanted_ = true;
  if (wake_) SetEvent(wake_);
}

void Library::Prioritize(const TrackP& t) {
  if (!t) return;
  {
    std::lock_guard<std::mutex> lk(m);
    if (t->analyzed && t->version >= kAnalysisVersion) return;
    prio_.push_back(t);
  }
  if (wake_) SetEvent(wake_);
}

void Library::Changed() {
  revision++;
  dirty_ = true;
}

static bool NeedsAnalysis(const Track& t) { return !t.failed && (!t.analyzed || t.version < kAnalysisVersion); }

void Library::Worker() {
  DWORD lastSave = GetTickCount();
  size_t cursor = 0;
  while (!quit_) {
    if (scanWanted_.exchange(false)) {
      SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_BELOW_NORMAL);
      DoScan();
      LoadPlaylists();
      cursor = 0;
      structure++;
      Changed();
    }
    TrackP next;
    {
      std::lock_guard<std::mutex> lk(m);
      while (!prio_.empty() && !next) {
        TrackP t = prio_.back();
        prio_.pop_back();
        if (NeedsAnalysis(*t)) next = t;
      }
      if (!next && !paused) {
        for (; cursor < tracks.size(); ++cursor) {
          if (NeedsAnalysis(*tracks[cursor])) {
            next = tracks[cursor];
            break;
          }
        }
      }
      currentWork = next ? next->label() : std::string();
    }
    if (next && !quit_) {
      // Lowest priority: music playing on this PC and the phones never wait for the analysis.
      SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_IDLE);
      Analyze(next);
    }
    if (dirty_ && (GetTickCount() - lastSave > 30000 || !next)) {
      SaveNow();
      lastSave = GetTickCount();
    }
    if (!next) {
      {
        std::lock_guard<std::mutex> lk(m);
        currentWork.clear();
      }
      WaitForSingleObject(wake_, 3000);
    }
  }
}

// ---------------------------------------------------------------- scanning

namespace {
struct Found {
  std::wstring path;
  std::string rel;
  int64_t size, mtime;
};

bool IsAudio(const std::wstring& name) {
  size_t dot = name.find_last_of(L'.');
  if (dot == std::wstring::npos) return false;
  std::wstring e = Lower(name.substr(dot));
  return e == L".mp3" || e == L".flac" || e == L".wav" || e == L".aiff" || e == L".aif" || e == L".aifc";
}

int64_t FileTimeMs(const FILETIME& ft) {
  ULARGE_INTEGER u;
  u.LowPart = ft.dwLowDateTime;
  u.HighPart = ft.dwHighDateTime;
  return (int64_t)(u.QuadPart / 10000ull) - 11644473600000ll;
}

void ScanDir(const std::wstring& root, std::vector<Found>& out, std::atomic<bool>& quit) {
  std::vector<std::pair<std::wstring, std::string>> stack;  // (full dir, rel prefix)
  stack.push_back({root, ""});
  while (!stack.empty() && !quit) {
    auto cur = stack.back();
    stack.pop_back();
    WIN32_FIND_DATAW fd;
    HANDLE h = FindFirstFileExW((cur.first + L"\\*").c_str(), FindExInfoBasic, &fd, FindExSearchNameMatch, nullptr,
                                FIND_FIRST_EX_LARGE_FETCH);
    if (h == INVALID_HANDLE_VALUE) continue;  // unreadable folders are skipped
    do {
      std::wstring name = fd.cFileName;
      if (name == L"." || name == L"..") continue;
      if (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
        if (fd.dwFileAttributes & (FILE_ATTRIBUTE_SYSTEM | FILE_ATTRIBUTE_HIDDEN)) continue;
        if (fd.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) continue;
        std::wstring l = Lower(name);
        if (l == L"$recycle.bin" || l == L"system volume information") continue;
        stack.push_back({cur.first + L"\\" + name, cur.second + U8(name) + "/"});
      } else if (IsAudio(name) && !(fd.dwFileAttributes & FILE_ATTRIBUTE_HIDDEN)) {
        Found f;
        f.path = cur.first + L"\\" + name;
        f.rel = cur.second + U8(name);
        f.size = ((int64_t)fd.nFileSizeHigh << 32) | fd.nFileSizeLow;
        f.mtime = FileTimeMs(fd.ftLastWriteTime);
        out.push_back(std::move(f));
      }
    } while (FindNextFileW(h, &fd));
    FindClose(h);
  }
}
}  // namespace

void Library::DoScan() {
  std::wstring r;
  {
    std::lock_guard<std::mutex> lk(m);
    r = root;
  }
  if (r.empty()) return;
  while (r.size() > 3 && (r.back() == L'\\' || r.back() == L'/')) r.pop_back();
  scanning = true;
  revision++;
  std::vector<Found> found;
  if (DirExists(r)) ScanDir(r, found, quit_);
  std::lock_guard<std::mutex> lk(m);
  scanning = false;
  if (quit_) return;
  if (!DirExists(r)) {
    scanError = "No se encuentra la carpeta. ¿Está conectado el disco?";
    return;
  }
  if (found.empty() && !tracks.empty()) {
    // Disk not plugged in or the folder was renamed: keep what we know instead of wiping it.
    scanError = "La carpeta aparece vacía. Se conservan los temas conocidos.";
    return;
  }
  scanError.clear();
  std::unordered_map<std::wstring, TrackP> old;
  for (auto& t : tracks) old[Lower(t->path)] = t;
  std::vector<TrackP> next;
  next.reserve(found.size());
  for (auto& f : found) {
    auto it = old.find(Lower(f.path));
    if (it != old.end()) {
      TrackP t = it->second;
      t->rel = f.rel;
      if (t->size != f.size || t->mtime != f.mtime) {
        // The file changed: analyze it again, keep what the person set.
        t->size = f.size;
        t->mtime = f.mtime;
        t->analyzed = t->failed = false;
        t->version = 0;
        t->cover = false;
      }
      if (!t->fixedName && t->title.empty()) ParseName(t->fileName(), t->artist, t->title);
      next.push_back(t);
      continue;
    }
    auto t = std::make_shared<Track>();
    t->path = f.path;
    t->rel = f.rel;
    t->size = f.size;
    t->mtime = f.mtime;
    ParseName(t->fileName(), t->artist, t->title);
    next.push_back(t);
  }
  std::sort(next.begin(), next.end(), [](const TrackP& a, const TrackP& b) {
    return CompareStringW(LOCALE_USER_DEFAULT, NORM_IGNORECASE, a->path.c_str(), -1, b->path.c_str(), -1) == CSTR_LESS_THAN;
  });
  tracks.swap(next);
  ComputeSharedDepth();
  int n = 0;
  for (auto& t : tracks) n += t->analyzed ? 1 : 0;
  analyzed = n;
  total = (int)tracks.size();
  dirty_ = true;
}

void Library::ComputeSharedDepth() {
  std::vector<std::string> common;
  bool first = true;
  for (auto& t : tracks) {
    std::vector<std::string> segs;
    std::string d = t->dir();
    size_t s = 0;
    while (!d.empty()) {
      size_t sl = d.find('/', s);
      segs.push_back(d.substr(s, sl == std::string::npos ? std::string::npos : sl - s));
      if (sl == std::string::npos) break;
      s = sl + 1;
    }
    if (first) {
      common = segs;
      first = false;
      continue;
    }
    size_t k = 0;
    while (k < common.size() && k < segs.size() && common[k] == segs[k]) ++k;
    common.resize(k);
    if (common.empty()) break;
  }
  sharedDepth = (int)common.size();
}

// ---------------------------------------------------------------- Virtual DJ playlists

static std::wstring DecodeText(std::string s) {
  if (s.size() >= 3 && (uint8_t)s[0] == 0xEF && (uint8_t)s[1] == 0xBB && (uint8_t)s[2] == 0xBF) s.erase(0, 3);
  if (s.size() >= 2 && (uint8_t)s[0] == 0xFF && (uint8_t)s[1] == 0xFE) {
    return std::wstring(reinterpret_cast<const wchar_t*>(s.data() + 2), (s.size() - 2) / 2);
  }
  int n = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, s.data(), (int)s.size(), nullptr, 0);
  UINT cp = n > 0 || s.empty() ? CP_UTF8 : CP_ACP;  // old playlists may be in the Windows code page
  n = MultiByteToWideChar(cp, 0, s.data(), (int)s.size(), nullptr, 0);
  std::wstring w(n, L'\0');
  if (n > 0) MultiByteToWideChar(cp, 0, s.data(), (int)s.size(), &w[0], n);
  return w;
}

static void FindM3u(const std::wstring& dir, int depth, std::vector<std::wstring>& out) {
  WIN32_FIND_DATAW fd;
  HANDLE h = FindFirstFileW((dir + L"\\*").c_str(), &fd);
  if (h == INVALID_HANDLE_VALUE) return;
  do {
    std::wstring name = fd.cFileName;
    if (name == L"." || name == L"..") continue;
    if (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
      if (depth > 0) FindM3u(dir + L"\\" + name, depth - 1, out);
    } else {
      std::wstring l = Lower(name);
      if (l.size() > 4 && (l.compare(l.size() - 4, 4, L".m3u") == 0 || (l.size() > 5 && l.compare(l.size() - 5, 5, L".m3u8") == 0))) {
        out.push_back(dir + L"\\" + name);
      }
    }
  } while (FindNextFileW(h, &fd));
  FindClose(h);
}

void Library::LoadPlaylists() {
  std::wstring r;
  std::vector<TrackP> all;
  {
    std::lock_guard<std::mutex> lk(m);
    r = root;
    all = tracks;
  }
  std::vector<std::wstring> files;
  if (!r.empty()) FindM3u(r, 0, files);
  wchar_t docs[MAX_PATH];
  if (SHGetFolderPathW(nullptr, CSIDL_PERSONAL, nullptr, 0, docs) == S_OK) {
    FindM3u(std::wstring(docs) + L"\\VirtualDJ\\Playlists", 3, files);
  }
  std::unordered_map<std::wstring, TrackP> byPath, byRel;
  std::unordered_map<std::wstring, std::vector<TrackP>> byName;
  for (auto& t : all) {
    byPath[Lower(t->path)] = t;
    byRel[Lower(W(t->rel))] = t;
    byName[Lower(W(t->fileName()))].push_back(t);
  }
  std::vector<Playlist> lists;
  std::set<std::wstring> seenNames;
  for (auto& f : files) {
    std::string raw;
    if (!ReadAll(f, raw, 16u << 20)) continue;
    std::wstring text = DecodeText(raw);
    std::wstring folder = f.substr(0, f.find_last_of(L'\\'));
    Playlist p;
    p.file = f;
    std::wstring base = f.substr(f.find_last_of(L'\\') + 1);
    base = base.substr(0, base.find_last_of(L'.'));
    p.name = U8(base);
    p.id = "pc-vdj-" + Hex(Fnv(U8(Lower(f))));
    std::set<Track*> in;
    size_t pos = 0;
    while (pos <= text.size()) {
      size_t nl = text.find(L'\n', pos);
      std::wstring line = Trim(text.substr(pos, nl == std::wstring::npos ? std::wstring::npos : nl - pos));
      pos = nl == std::wstring::npos ? text.size() + 1 : nl + 1;
      if (line.empty() || line[0] == L'#') continue;
      if (line.compare(0, 8, L"file:///") == 0) line = W(UrlDecode(U8(line.substr(8)), false));
      for (auto& c : line) {
        if (c == L'/') c = L'\\';
      }
      bool absolute = (line.size() > 2 && line[1] == L':') || line.compare(0, 2, L"\\\\") == 0;
      std::wstring full = absolute ? line : folder + L"\\" + line;
      TrackP hit;
      auto it = byPath.find(Lower(full));
      if (it != byPath.end()) hit = it->second;
      // The disk letter or the parent folders may differ: try shorter and shorter endings of the path.
      if (!hit) {
        std::wstring l = Lower(line);
        for (auto& c : l) {
          if (c == L'\\') c = L'/';
        }
        size_t s = 0;
        while (!hit) {
          size_t sl = l.find(L'/', s);
          if (sl == std::wstring::npos) break;
          s = sl + 1;
          auto rt = byRel.find(l.substr(s));
          if (rt != byRel.end()) hit = rt->second;
        }
        if (!hit) {
          std::wstring name = l.substr(l.find_last_of(L'/') == std::wstring::npos ? 0 : l.find_last_of(L'/') + 1);
          auto nt = byName.find(name);
          if (nt != byName.end() && !nt->second.empty()) hit = nt->second.front();
        }
      }
      if (hit && in.insert(hit.get()).second) p.tracks.push_back(hit);
    }
    if (p.tracks.empty()) continue;
    // Same name in both places: keep the first one found (library folder wins).
    if (!seenNames.insert(Lower(base)).second) continue;
    lists.push_back(std::move(p));
  }
  std::sort(lists.begin(), lists.end(), [](const Playlist& a, const Playlist& b) {
    return CompareStringW(LOCALE_USER_DEFAULT, NORM_IGNORECASE, W(a.name).c_str(), -1, W(b.name).c_str(), -1) == CSTR_LESS_THAN;
  });
  std::lock_guard<std::mutex> lk(m);
  playlists.swap(lists);
}

// ---------------------------------------------------------------- analysis

std::wstring Library::PeakPath(const Track& t) const { return dataDir_ + L"\\peaks\\" + W(Hex(Fnv(U8(Lower(t.path))))) + L".bin"; }
std::wstring Library::CoverPath(const Track& t) const { return dataDir_ + L"\\covers\\" + W(Hex(Fnv(U8(Lower(t.path))))) + L".img"; }

void Library::Analyze(const TrackP& t) {
  std::wstring path;
  {
    std::lock_guard<std::mutex> lk(m);
    path = t->path;
  }
  std::string p8 = U8(path);
  CsaAnalysis a;
  std::vector<float> pk(30 * 60 * 90);  // up to 90 minutes of overview
  int n = csa_analyze(p8.c_str(), &a, pk.data(), (int32_t)pk.size());
  FileTags tg = ReadTags(path);
  bool cover = false;
  if (tg.cover.size() > 64) cover = WriteAtomic(CoverPath(*t), tg.cover.data(), tg.cover.size());
  if (n >= 0) {
    std::vector<uint8_t> bytes(n);
    for (int i = 0; i < n; ++i) bytes[i] = (uint8_t)std::lround(Clamp01(pk[i]) * 255);
    WriteAtomic(PeakPath(*t), bytes.data(), bytes.size());
    std::lock_guard<std::mutex> lk(m);
    peakCache_.erase(Lower(path));
  }
  std::lock_guard<std::mutex> lk(m);
  if (n < 0) {
    t->failed = true;
  } else {
    t->duration = a.duration;
    t->bpm = a.bpm;
    t->gain = a.gain_db;
    t->intro = a.intro_sec;
    t->key = a.key;
    t->keyConf = a.key_conf;
    t->loud = a.loud_db;
    t->onset = a.onset_rate;
    t->pulse = a.pulse;
    t->bright = a.brightness;
    t->energy = EnergyOf(a.loud_db, a.onset_rate, a.bpm, a.brightness);
    t->mood = MoodOf(t->energy, a.pulse, a.key, a.brightness);
    if (!t->analyzed) analyzed++;
    t->analyzed = true;
    t->failed = false;
    t->version = kAnalysisVersion;
  }
  t->cover = cover;
  t->genre = tg.genre;
  // The file name wins when it has "Artist - Title"; tags fill in when it doesn't.
  if (!t->fixedName && (t->artist.empty() || LooksMisnamed(*t))) {
    if (!tg.artist.empty()) t->artist = tg.artist;
    if (!tg.title.empty()) t->title = tg.title;
  }
  Changed();
}

std::vector<uint8_t> Library::Peaks(const Track& t) {
  std::wstring key;
  {
    std::lock_guard<std::mutex> lk(m);
    if (!t.analyzed) return {};
    key = Lower(t.path);
    auto it = peakCache_.find(key);
    if (it != peakCache_.end()) return it->second;
  }
  std::string raw;
  if (!ReadAll(PeakPath(t), raw, 4u << 20)) return {};
  std::vector<uint8_t> v(raw.begin(), raw.end());
  std::lock_guard<std::mutex> lk(m);
  peakCache_[key] = v;
  peakOrder_.push_back(key);
  while (peakOrder_.size() > 16) {
    peakCache_.erase(peakOrder_.front());
    peakOrder_.erase(peakOrder_.begin());
  }
  return v;
}

void Library::RecordPlay(const TrackP& t) {
  {
    std::lock_guard<std::mutex> lk(m);
    t->plays++;
    t->lastPlayed = NowMs();
  }
  Changed();
}

void Library::RecordSkip(const TrackP& t) {
  {
    std::lock_guard<std::mutex> lk(m);
    t->skips++;
  }
  Changed();
}

TrackP Library::ByRel(const std::string& rel) {
  std::lock_guard<std::mutex> lk(m);
  // Tracks are sorted by path, which mostly follows rel: binary search would need the same order,
  // so a straight scan it is (a few thousand string compares, well under a millisecond).
  for (auto& t : tracks) {
    if (t->rel == rel) return t;
  }
  return nullptr;
}

// ---------------------------------------------------------------- JSON for the phones

static void TrackJson(std::string& o, const Track& t) {
  o += "{\"p\":" + JsonStr("csnet:" + t.rel);
  o += ",\"r\":" + JsonStr(t.rel);
  o += ",\"t\":" + JsonStr(t.title);
  o += ",\"a\":" + JsonStr(t.artist);
  o += ",\"s\":" + JsonNum((double)t.size);
  o += ",\"m\":" + JsonNum((double)t.mtime);
  o += ",\"d\":" + JsonNum(t.duration);
  o += ",\"b\":" + JsonNum(t.bpm);
  o += ",\"g\":" + JsonNum(t.gain);
  o += ",\"i\":" + JsonNum(t.intro);
  o += std::string(",\"ok\":") + (t.analyzed ? "true" : "false");
  o += std::string(",\"f\":") + (t.failed ? "true" : "false");
  o += ",\"v\":" + JsonNum(t.version);
  o += ",\"k\":" + JsonNum(t.key);
  o += ",\"kc\":" + JsonNum(t.keyConf);
  o += ",\"ld\":" + JsonNum(t.loud);
  o += ",\"or\":" + JsonNum(t.onset);
  o += ",\"pu\":" + JsonNum(t.pulse);
  o += ",\"br\":" + JsonNum(t.bright);
  o += ",\"en\":" + JsonNum(t.energy);
  o += ",\"mo\":" + JsonStr(t.mood);
  o += ",\"gt\":" + JsonStr(t.genre);
  o += std::string(",\"cv\":") + (t.cover ? "true" : "false");
  if (t.plays > 0) o += ",\"pl\":" + JsonNum(t.plays);
  if (t.skips > 0) o += ",\"sk\":" + JsonNum(t.skips);
  if (t.lastPlayed > 0) o += ",\"lp\":" + JsonNum((double)t.lastPlayed);
  if (t.fixedName) o += ",\"fx\":true";
  if (t.entry >= 0) o += ",\"e\":" + JsonNum(t.entry);
  o += '}';
}

std::shared_ptr<const std::string> Library::LibraryJson(const std::string& name) {
  std::lock_guard<std::mutex> lk(m);
  int rev = revision;
  if (json_ && jsonRev_ == rev && jsonName_ == name) return json_;
  auto o = std::make_shared<std::string>();
  o->reserve(tracks.size() * 420 + 1024);
  *o += "{\"name\":" + JsonStr(name) + ",\"tracks\":[";
  for (size_t i = 0; i < tracks.size(); ++i) {
    if (i) *o += ',';
    TrackJson(*o, *tracks[i]);
  }
  *o += "],\"playlists\":[";
  for (size_t i = 0; i < playlists.size(); ++i) {
    const Playlist& p = playlists[i];
    if (i) *o += ',';
    *o += "{\"id\":" + JsonStr(p.id) + ",\"n\":" + JsonStr(p.name) + ",\"p\":[";
    for (size_t k = 0; k < p.tracks.size(); ++k) {
      if (k) *o += ',';
      *o += JsonStr("csnet:" + p.tracks[k]->rel);
    }
    *o += "],\"s\":\"vdj\"}";
  }
  *o += "]}";
  json_ = o;
  jsonRev_ = rev;
  jsonName_ = name;
  return json_;
}

// ---------------------------------------------------------------- cache file (library.tsv)

static std::string Clean(const std::string& s) {
  std::string o = s;
  for (auto& c : o) {
    if (c == '\t' || c == '\n' || c == '\r') c = ' ';
  }
  return o;
}

void Library::SaveNow() {
  std::string o;
  {
    std::lock_guard<std::mutex> lk(m);
    dirty_ = false;
    o.reserve(tracks.size() * 300 + 64);
    o += "CSMIXCL1\t" + Clean(U8(root)) + "\n";
    for (auto& tp : tracks) {
      const Track& t = *tp;
      o += Clean(U8(t.path)) + '\t' + Clean(t.rel) + '\t' + Clean(t.title) + '\t' + Clean(t.artist) + '\t';
      o += Fmt("%lld\t%lld\t%.3f\t%.3f\t%.3f\t%.3f\t%d\t%d\t%d\t%d\t%.4f\t%.3f\t%.4f\t%.4f\t%.4f\t%.4f\t", (long long)t.size,
               (long long)t.mtime, t.duration, t.bpm, t.gain, t.intro, t.analyzed ? 1 : 0, t.failed ? 1 : 0, t.version, t.key,
               t.keyConf, t.loud, t.onset, t.pulse, t.bright, t.energy);
      o += Clean(t.mood) + '\t' + Clean(t.genre) + '\t';
      o += Fmt("%d\t%d\t%d\t%lld\t%d\t%.3f\n", t.cover ? 1 : 0, t.plays, t.skips, (long long)t.lastPlayed, t.fixedName ? 1 : 0,
               t.entry);
    }
  }
  if (!WriteAtomic(dataDir_ + L"\\library.tsv", o.data(), o.size())) dirty_ = true;
}

void Library::Load() {
  std::string raw;
  if (!ReadAll(dataDir_ + L"\\library.tsv", raw, 256u << 20)) return;
  std::vector<TrackP> list;
  size_t pos = 0;
  bool header = true;
  while (pos < raw.size()) {
    size_t nl = raw.find('\n', pos);
    std::string line = raw.substr(pos, nl == std::string::npos ? std::string::npos : nl - pos);
    pos = nl == std::string::npos ? raw.size() : nl + 1;
    std::vector<std::string> f;
    size_t s = 0;
    for (;;) {
      size_t tab = line.find('\t', s);
      f.push_back(line.substr(s, tab == std::string::npos ? std::string::npos : tab - s));
      if (tab == std::string::npos) break;
      s = tab + 1;
    }
    if (header) {
      header = false;
      if (f.empty() || f[0] != "CSMIXCL1") return;  // unknown file: start fresh
      continue;
    }
    if (f.size() < 28) continue;
    auto t = std::make_shared<Track>();
    int i = 0;
    t->path = W(f[i++]);
    t->rel = f[i++];
    t->title = f[i++];
    t->artist = f[i++];
    t->size = _atoi64(f[i++].c_str());
    t->mtime = _atoi64(f[i++].c_str());
    t->duration = atof(f[i++].c_str());
    t->bpm = atof(f[i++].c_str());
    t->gain = atof(f[i++].c_str());
    t->intro = atof(f[i++].c_str());
    t->analyzed = atoi(f[i++].c_str()) != 0;
    t->failed = atoi(f[i++].c_str()) != 0;
    t->version = atoi(f[i++].c_str());
    t->key = atoi(f[i++].c_str());
    t->keyConf = atof(f[i++].c_str());
    t->loud = atof(f[i++].c_str());
    t->onset = atof(f[i++].c_str());
    t->pulse = atof(f[i++].c_str());
    t->bright = atof(f[i++].c_str());
    t->energy = atof(f[i++].c_str());
    t->mood = f[i++];
    t->genre = f[i++];
    t->cover = atoi(f[i++].c_str()) != 0;
    t->plays = atoi(f[i++].c_str());
    t->skips = atoi(f[i++].c_str());
    t->lastPlayed = _atoi64(f[i++].c_str());
    t->fixedName = atoi(f[i++].c_str()) != 0;
    t->entry = atof(f[i++].c_str());
    if (t->path.empty()) continue;
    list.push_back(t);
  }
  std::lock_guard<std::mutex> lk(m);
  tracks.swap(list);
  ComputeSharedDepth();
  int n = 0;
  for (auto& t : tracks) n += t->analyzed ? 1 : 0;
  analyzed = n;
  total = (int)tracks.size();
}
