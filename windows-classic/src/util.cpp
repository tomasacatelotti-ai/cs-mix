#include "app.h"
#include <shlobj.h>

#include <cmath>
#include <cstdarg>
#include <cstdio>


std::string U8(const std::wstring& w) {
  if (w.empty()) return {};
  int n = WideCharToMultiByte(CP_UTF8, 0, w.data(), (int)w.size(), nullptr, 0, nullptr, nullptr);
  std::string s(n, '\0');
  WideCharToMultiByte(CP_UTF8, 0, w.data(), (int)w.size(), &s[0], n, nullptr, nullptr);
  return s;
}

std::wstring W(const std::string& s) {
  if (s.empty()) return {};
  int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), nullptr, 0);
  std::wstring w(n, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), &w[0], n);
  return w;
}

std::wstring Lower(const std::wstring& s) {
  std::wstring r = s;
  if (!r.empty()) CharLowerBuffW(&r[0], (DWORD)r.size());
  return r;
}

std::string LowerU8(const std::string& s) { return U8(Lower(W(s))); }

std::wstring Trim(const std::wstring& s) {
  size_t a = s.find_first_not_of(L" \t\r\n\x00A0");
  if (a == std::wstring::npos) return {};
  size_t b = s.find_last_not_of(L" \t\r\n\x00A0");
  return s.substr(a, b - a + 1);
}

std::string Trim8(const std::string& s) {
  size_t a = s.find_first_not_of(" \t\r\n");
  if (a == std::string::npos) return {};
  size_t b = s.find_last_not_of(" \t\r\n");
  return s.substr(a, b - a + 1);
}

std::string JsonStr(const std::string& s) {
  std::string o;
  o.reserve(s.size() + 2);
  o += '"';
  for (unsigned char c : s) {
    switch (c) {
      case '"': o += "\\\""; break;
      case '\\': o += "\\\\"; break;
      case '\n': o += "\\n"; break;
      case '\r': o += "\\r"; break;
      case '\t': o += "\\t"; break;
      default:
        if (c < 0x20) {
          char b[8];
          snprintf(b, sizeof b, "\\u%04x", c);
          o += b;
        } else {
          o += (char)c;
        }
    }
  }
  o += '"';
  return o;
}

std::string JsonNum(double v) {
  if (!std::isfinite(v)) return "0";
  if (v == std::floor(v) && std::fabs(v) < 1e15) return Fmt("%.0f", v);
  return Fmt("%.4f", v);
}

std::string Fmt(const char* f, ...) {
  char buf[1024];
  va_list ap;
  va_start(ap, f);
  int n = vsnprintf(buf, sizeof buf, f, ap);
  va_end(ap);
  if (n < 0) return {};
  if (n < (int)sizeof buf) return std::string(buf, n);
  std::string s(n + 1, '\0');
  va_start(ap, f);
  vsnprintf(&s[0], s.size(), f, ap);
  va_end(ap);
  s.resize(n);
  return s;
}

std::wstring FmtW(const wchar_t* f, ...) {
  wchar_t buf[1024];
  va_list ap;
  va_start(ap, f);
  int n = _vsnwprintf(buf, 1023, f, ap);
  va_end(ap);
  if (n < 0) n = 1023;
  buf[n] = 0;
  return buf;
}

std::wstring FmtTime(double sec) {
  if (!(sec >= 0)) sec = 0;
  int s = (int)sec;
  return FmtW(L"%d:%02d", s / 60, s % 60);
}

uint64_t Fnv(const std::string& s) {
  uint64_t h = 0xcbf29ce484222325ull;
  for (unsigned char c : s) {
    h ^= c;
    h *= 0x100000001b3ull;
  }
  return h & 0x7FFFFFFFFFFFFFFFull;
}

std::string Hex(uint64_t v) { return Fmt("%llx", (unsigned long long)v); }

bool FileExists(const std::wstring& p) {
  DWORD a = GetFileAttributesW(p.c_str());
  return a != INVALID_FILE_ATTRIBUTES && !(a & FILE_ATTRIBUTE_DIRECTORY);
}

bool DirExists(const std::wstring& p) {
  DWORD a = GetFileAttributesW(p.c_str());
  return a != INVALID_FILE_ATTRIBUTES && (a & FILE_ATTRIBUTE_DIRECTORY);
}

bool ReadAll(const std::wstring& p, std::string& out, size_t maxBytes) {
  HANDLE f = CreateFileW(p.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
                         OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (f == INVALID_HANDLE_VALUE) return false;
  LARGE_INTEGER sz;
  if (!GetFileSizeEx(f, &sz) || (uint64_t)sz.QuadPart > maxBytes) {
    CloseHandle(f);
    return false;
  }
  out.resize((size_t)sz.QuadPart);
  DWORD got = 0;
  bool ok = out.empty() || (ReadFile(f, &out[0], (DWORD)out.size(), &got, nullptr) && got == out.size());
  CloseHandle(f);
  return ok;
}

bool WriteAtomic(const std::wstring& p, const void* data, size_t len) {
  std::wstring tmp = p + L".tmp";
  HANDLE f = CreateFileW(tmp.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (f == INVALID_HANDLE_VALUE) return false;
  DWORD put = 0;
  bool ok = len == 0 || (WriteFile(f, data, (DWORD)len, &put, nullptr) && put == len);
  FlushFileBuffers(f);
  CloseHandle(f);
  if (!ok) {
    DeleteFileW(tmp.c_str());
    return false;
  }
  return MoveFileExW(tmp.c_str(), p.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH) != 0;
}

std::wstring ExePath() {
  wchar_t buf[MAX_PATH * 2];
  DWORD n = GetModuleFileNameW(nullptr, buf, MAX_PATH * 2);
  return std::wstring(buf, n);
}

std::wstring DataDir() {
  static std::wstring dir;
  if (!dir.empty()) return dir;
  wchar_t buf[MAX_PATH];
  if (SHGetFolderPathW(nullptr, CSIDL_APPDATA | CSIDL_FLAG_CREATE, nullptr, 0, buf) == S_OK) {
    dir = std::wstring(buf) + L"\\CS Mix Clasico";
  } else {
    std::wstring e = ExePath();
    dir = e.substr(0, e.find_last_of(L'\\')) + L"\\datos";
  }
  CreateDirectoryW(dir.c_str(), nullptr);
  CreateDirectoryW((dir + L"\\peaks").c_str(), nullptr);
  CreateDirectoryW((dir + L"\\covers").c_str(), nullptr);
  return dir;
}

static int Hexv(char c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  return -1;
}

std::string UrlDecode(const std::string& s, bool plus) {
  std::string o;
  o.reserve(s.size());
  for (size_t i = 0; i < s.size(); ++i) {
    char c = s[i];
    if (c == '%' && i + 2 < s.size() && Hexv(s[i + 1]) >= 0 && Hexv(s[i + 2]) >= 0) {
      o += (char)(Hexv(s[i + 1]) * 16 + Hexv(s[i + 2]));
      i += 2;
    } else if (c == '+' && plus) {
      o += ' ';
    } else {
      o += c;
    }
  }
  return o;
}

int64_t NowMs() {
  FILETIME ft;
  GetSystemTimeAsFileTime(&ft);
  ULARGE_INTEGER u;
  u.LowPart = ft.dwLowDateTime;
  u.HighPart = ft.dwHighDateTime;
  return (int64_t)(u.QuadPart / 10000ull) - 11644473600000ll;
}

// ---------------------------------------------------------------- settings.ini

static std::wstring IniPath() {
  static std::wstring p;
  if (p.empty()) {
    p = DataDir() + L"\\settings.ini";
    if (!FileExists(p)) {
      // A UTF-16 file keeps accents and other characters in the values.
      HANDLE f = CreateFileW(p.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr);
      if (f != INVALID_HANDLE_VALUE) {
        const unsigned char bom[] = {0xFF, 0xFE, '[', 0, 'c', 0, 's', 0, ']', 0, '\r', 0, '\n', 0};
        DWORD put;
        WriteFile(f, bom, sizeof bom, &put, nullptr);
        CloseHandle(f);
      }
    }
  }
  return p;
}

std::wstring IniGet(const wchar_t* key, const wchar_t* def) {
  wchar_t buf[2048];
  GetPrivateProfileStringW(L"cs", key, def, buf, 2048, IniPath().c_str());
  return buf;
}

int IniInt(const wchar_t* key, int def) {
  std::wstring v = IniGet(key, L"");
  return v.empty() ? def : _wtoi(v.c_str());
}

double IniNum(const wchar_t* key, double def) {
  std::wstring v = IniGet(key, L"");
  return v.empty() ? def : _wtof(v.c_str());
}

void IniSet(const wchar_t* key, const std::wstring& v) { WritePrivateProfileStringW(L"cs", key, v.c_str(), IniPath().c_str()); }
void IniSetInt(const wchar_t* key, int v) { IniSet(key, FmtW(L"%d", v)); }
void IniSetNum(const wchar_t* key, double v) { IniSet(key, W(Fmt("%.3f", v))); }
