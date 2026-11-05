// Reads ID3v2 (mp3, and inside wav/aiff), FLAC Vorbis comments + pictures and RIFF INFO.
// Same rules as lib/core/tags.dart. Never throws: a damaged tag just gives fewer fields.
#include "app.h"
#include <cstring>


namespace {

constexpr uint32_t kMaxTag = 24u * 1024 * 1024;
using Bytes = std::string;

struct File {
  HANDLE h = INVALID_HANDLE_VALUE;
  uint64_t len = 0;
  ~File() {
    if (h != INVALID_HANDLE_VALUE) CloseHandle(h);
  }
  bool Read(uint64_t pos, uint32_t n, Bytes& out) {
    out.clear();
    if (pos >= len) return false;
    if (pos + n > len) n = (uint32_t)(len - pos);
    LARGE_INTEGER li;
    li.QuadPart = (LONGLONG)pos;
    if (!SetFilePointerEx(h, li, nullptr, FILE_BEGIN)) return false;
    out.resize(n);
    DWORD got = 0;
    if (!ReadFile(h, &out[0], n, &got, nullptr)) return false;
    out.resize(got);
    return true;
  }
};

uint8_t B(const Bytes& b, size_t o) { return o < b.size() ? (uint8_t)b[o] : 0; }
uint32_t Be32(const Bytes& b, size_t o) { return (B(b, o) << 24) | (B(b, o + 1) << 16) | (B(b, o + 2) << 8) | B(b, o + 3); }
uint32_t Le32(const Bytes& b, size_t o) { return B(b, o) | (B(b, o + 1) << 8) | (B(b, o + 2) << 16) | ((uint32_t)B(b, o + 3) << 24); }
uint32_t Syncsafe(const Bytes& b, size_t o) { return (B(b, o) << 21) | (B(b, o + 1) << 14) | (B(b, o + 2) << 7) | B(b, o + 3); }
bool Is(const Bytes& b, size_t o, const char* s) {
  size_t n = std::strlen(s);
  return b.size() >= o + n && std::memcmp(b.data() + o, s, n) == 0;
}

std::string Latin1(const char* p, size_t n) {
  std::wstring w;
  w.reserve(n);
  for (size_t i = 0; i < n; ++i) w += (wchar_t)(unsigned char)p[i];
  return U8(w);
}

// Valid UTF-8 out of anything (bad sequences become U+FFFD).
std::string CleanUtf8(const char* p, size_t n) { return U8(W(std::string(p, n))); }

std::string UntilNul(const std::string& s) {
  size_t z = s.find('\0');
  return z == std::string::npos ? s : s.substr(0, z);
}

std::string Decode(int enc, const char* p, size_t n) {
  if (enc == 1 || enc == 2) {
    bool le = enc == 1;
    size_t o = 0;
    if (n >= 2 && enc == 1) {
      if ((uint8_t)p[0] == 0xFF && (uint8_t)p[1] == 0xFE) {
        le = true;
        o = 2;
      } else if ((uint8_t)p[0] == 0xFE && (uint8_t)p[1] == 0xFF) {
        le = false;
        o = 2;
      }
    }
    std::wstring w;
    for (size_t i = o; i + 1 < n; i += 2) {
      wchar_t u = le ? (wchar_t)((uint8_t)p[i] | ((uint8_t)p[i + 1] << 8)) : (wchar_t)(((uint8_t)p[i] << 8) | (uint8_t)p[i + 1]);
      if (u == 0) break;
      w += u;
    }
    return U8(w);
  }
  if (enc == 3) return UntilNul(CleanUtf8(p, n));
  return UntilNul(Latin1(p, n));
}

std::string Id3Text(const Bytes& b, size_t o, size_t n) {
  if (n == 0) return {};
  return Trim8(UntilNul(Decode(B(b, o), b.data() + o + 1, n - 1)));
}

std::string CleanGenre(std::string g) {
  g = Trim8(g);
  if (!g.empty() && g[0] == '(') {
    size_t c = g.find(')');
    bool digits = c != std::string::npos && c > 1;
    for (size_t i = 1; digits && i < c; ++i) digits = g[i] >= '0' && g[i] <= '9';
    if (digits) g = Trim8(g.substr(c + 1));
  }
  return g;
}

size_t SkipString(const Bytes& b, size_t o, size_t end, int enc) {
  if (enc == 1 || enc == 2) {
    size_t i = o;
    while (i + 1 < end && !(b[i] == 0 && b[i + 1] == 0)) i += 2;
    return i + 2;
  }
  size_t i = o;
  while (i < end && b[i] != 0) ++i;
  return i + 1;
}

void Apic(const Bytes& b, size_t o0, size_t n, FileTags& t, bool v22, bool& frontCover) {
  size_t end = o0 + n;
  if (n < 8) return;
  int enc = B(b, o0);
  size_t o;
  if (v22) {
    o = o0 + 4;
  } else {
    o = SkipString(b, o0 + 1, end, 0);
  }
  if (o >= end) return;
  int picType = B(b, o);
  o = SkipString(b, o + 1, end, enc);
  if (o >= end) return;
  // Prefer the front cover (type 3); otherwise keep the first picture.
  if (!t.cover.empty() && (picType != 3 || frontCover)) return;
  t.cover.assign(b.data() + o, end - o);
  frontCover = picType == 3;
}

Bytes Unsync(const Bytes& d) {
  Bytes o;
  o.reserve(d.size());
  for (size_t i = 0; i < d.size(); ++i) {
    o += d[i];
    if ((uint8_t)d[i] == 0xFF && i + 1 < d.size() && d[i + 1] == 0) ++i;
  }
  return o;
}

void ReadId3At(File& f, uint64_t offset, FileTags& t) {
  Bytes h;
  if (!f.Read(offset, 10, h) || h.size() < 10 || !Is(h, 0, "ID3")) return;
  int ver = B(h, 3);
  int flags = B(h, 5);
  uint32_t size = Syncsafe(h, 6);
  if (size == 0 || size > kMaxTag || offset + 10 + size > f.len) return;
  Bytes data;
  if (!f.Read(offset + 10, size, data)) return;
  if ((flags & 0x80) && ver < 4) data = Unsync(data);
  size_t p = 0;
  if ((flags & 0x40) && ver >= 3 && data.size() > 4) {
    size_t ext = ver == 4 ? Syncsafe(data, 0) : Be32(data, 0) + 4;
    p = ext < data.size() ? ext : data.size();
  }
  size_t idLen = ver == 2 ? 3 : 4;
  size_t hdrLen = ver == 2 ? 6 : 10;
  bool front = false;
  while (p + hdrLen <= data.size()) {
    if (data[p] == 0) break;
    std::string id = data.substr(p, idLen);
    uint32_t fsize;
    if (ver == 2) fsize = (B(data, p + 3) << 16) | (B(data, p + 4) << 8) | B(data, p + 5);
    else if (ver == 4) fsize = Syncsafe(data, p + 4);
    else fsize = Be32(data, p + 4);
    size_t start = p + hdrLen;
    if (fsize == 0 || start + fsize > data.size()) break;
    if (id == "TIT2" || id == "TT2") {
      if (t.title.empty()) t.title = Id3Text(data, start, fsize);
    } else if (id == "TPE1" || id == "TP1") {
      if (t.artist.empty()) t.artist = Id3Text(data, start, fsize);
    } else if (id == "TCON" || id == "TCO") {
      if (t.genre.empty()) t.genre = CleanGenre(Id3Text(data, start, fsize));
    } else if (id == "APIC") {
      Apic(data, start, fsize, t, false, front);
    } else if (id == "PIC") {
      Apic(data, start, fsize, t, true, front);
    }
    p = start + fsize;
  }
}

void Vorbis(const Bytes& b, FileTags& t) {
  if (b.size() < 8) return;
  size_t o = 4 + (size_t)Le32(b, 0);
  if (o + 4 > b.size()) return;
  uint32_t n = Le32(b, o);
  o += 4;
  for (uint32_t i = 0; i < n && o + 4 <= b.size(); ++i) {
    uint32_t l = Le32(b, o);
    o += 4;
    if (o + l > b.size()) return;
    std::string s = CleanUtf8(b.data() + o, l);
    o += l;
    size_t eq = s.find('=');
    if (eq == 0 || eq == std::string::npos) continue;
    std::string k = s.substr(0, eq);
    for (auto& c : k) c = (char)toupper((unsigned char)c);
    std::string v = Trim8(s.substr(eq + 1));
    if (v.empty()) continue;
    if (k == "TITLE" && t.title.empty()) t.title = v;
    if (k == "ARTIST" && t.artist.empty()) t.artist = v;
    if (k == "GENRE" && t.genre.empty()) t.genre = CleanGenre(v);
  }
}

void FlacPicture(const Bytes& b, FileTags& t, bool& front) {
  if (b.size() < 32) return;
  size_t o = 0;
  uint32_t type = Be32(b, o);
  o += 4;
  uint32_t ml = Be32(b, o);
  o += 4 + ml;
  if (o + 4 > b.size()) return;
  uint32_t dl = Be32(b, o);
  o += 4 + (size_t)dl + 16;
  if (o + 4 > b.size()) return;
  uint32_t len = Be32(b, o);
  o += 4;
  if (len == 0 || o + len > b.size()) return;
  if (!t.cover.empty() && (type != 3 || front)) return;
  t.cover = b.substr(o, len);
  front = type == 3;
}

void ReadFlac(File& f, FileTags& t) {
  uint64_t pos = 4;
  bool front = false;
  for (int guard = 0; pos + 4 <= f.len && guard < 128; ++guard) {
    Bytes h;
    if (!f.Read(pos, 4, h) || h.size() < 4) return;
    bool last = (B(h, 0) & 0x80) != 0;
    int type = B(h, 0) & 0x7F;
    uint32_t size = (B(h, 1) << 16) | (B(h, 2) << 8) | B(h, 3);
    if (pos + 4 + size > f.len) return;
    if ((type == 4 || type == 6) && size < kMaxTag) {
      Bytes b;
      if (f.Read(pos + 4, size, b)) {
        if (type == 4) Vorbis(b, t);
        if (type == 6) FlacPicture(b, t, front);
      }
    }
    pos += 4 + size;
    if (last) return;
  }
}

void ReadChunks(File& f, uint64_t start, FileTags& t, bool bigEndian) {
  uint64_t pos = start;
  for (int guard = 0; pos + 8 <= f.len && guard < 64; ++guard) {
    Bytes h;
    if (!f.Read(pos, 8, h) || h.size() < 8) return;
    std::string id = h.substr(0, 4);
    uint32_t size = bigEndian ? Be32(h, 4) : Le32(h, 4);
    if (pos + 8 + size > f.len + 1) return;
    if (id == "ID3 " || id == "id3 ") {
      ReadId3At(f, pos + 8, t);
    } else if (!bigEndian && id == "LIST" && size >= 4 && size < 1024 * 1024) {
      Bytes b;
      if (f.Read(pos + 8, size, b) && Is(b, 0, "INFO")) {
        size_t o = 4;
        while (o + 8 <= b.size()) {
          std::string sid = b.substr(o, 4);
          uint32_t sl = Le32(b, o + 4);
          size_t so = o + 8;
          if (so + sl > b.size()) break;
          std::string v = Trim8(UntilNul(Latin1(b.data() + so, sl)));
          if (!v.empty()) {
            if (sid == "INAM" && t.title.empty()) t.title = v;
            if (sid == "IART" && t.artist.empty()) t.artist = v;
            if (sid == "IGNR" && t.genre.empty()) t.genre = CleanGenre(v);
          }
          o = so + sl + (sl & 1);
        }
      }
    }
    pos += 8 + (uint64_t)size + (size & 1);
  }
}

}  // namespace

FileTags ReadTags(const std::wstring& path) {
  FileTags t;
  File f;
  f.h = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_EXISTING,
                    FILE_ATTRIBUTE_NORMAL, nullptr);
  if (f.h == INVALID_HANDLE_VALUE) return t;
  LARGE_INTEGER sz;
  if (!GetFileSizeEx(f.h, &sz)) return t;
  f.len = (uint64_t)sz.QuadPart;
  Bytes head;
  if (!f.Read(0, 12, head) || head.size() < 4) return t;
  if (Is(head, 0, "ID3")) ReadId3At(f, 0, t);
  else if (Is(head, 0, "fLaC")) ReadFlac(f, t);
  else if (Is(head, 0, "RIFF") && Is(head, 8, "WAVE")) ReadChunks(f, 12, t, false);
  else if (Is(head, 0, "FORM") && head.size() >= 12) ReadChunks(f, 12, t, true);
  return t;
}
