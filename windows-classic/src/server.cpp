// Shares the library with the phones: same HTTP + UDP protocol as lib/core/net.dart (LibraryServer).
#include "app.h"
#include <cstring>


Server gServer;

namespace {
constexpr int kPort = 8770;
constexpr int kDiscoveryPort = 8771;
const char* kDiscoverMsg = "CSMIX_DISCOVER_1";

struct Conn {
  SOCKET s;
  std::string ip;
};

bool SendAll(SOCKET s, const char* p, size_t n) {
  while (n > 0) {
    int put = send(s, p, (int)(n > 65536 ? 65536 : n), 0);
    if (put <= 0) return false;
    p += put;
    n -= put;
  }
  return true;
}

void Reply(SOCKET s, int code, const char* status, const char* type, const std::string& body) {
  std::string h = Fmt(
      "HTTP/1.1 %d %s\r\nContent-Type: %s\r\nContent-Length: %u\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n", code,
      status, type, (unsigned)body.size());
  if (SendAll(s, h.data(), h.size())) SendAll(s, body.data(), body.size());
}

void ReplyJson(SOCKET s, int code, const std::string& body) {
  const char* st = code == 200 ? "OK" : code == 401 ? "Unauthorized" : code == 404 ? "Not Found" : "Error";
  Reply(s, code, st, "application/json; charset=utf-8", body);
}

bool SendFile(SOCKET s, const std::wstring& path) {
  HANDLE f = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
                         OPEN_EXISTING, FILE_FLAG_SEQUENTIAL_SCAN, nullptr);
  if (f == INVALID_HANDLE_VALUE) return false;
  LARGE_INTEGER sz;
  GetFileSizeEx(f, &sz);
  std::string h = Fmt(
      "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: %llu\r\nCache-Control: no-store\r\n"
      "Connection: close\r\n\r\n",
      (unsigned long long)sz.QuadPart);
  bool ok = SendAll(s, h.data(), h.size());
  std::vector<char> buf(64 * 1024);
  while (ok) {
    DWORD got = 0;
    if (!ReadFile(f, buf.data(), (DWORD)buf.size(), &got, nullptr) || got == 0) break;
    ok = SendAll(s, buf.data(), got);
  }
  CloseHandle(f);
  return true;
}
}  // namespace

DWORD WINAPI AcceptThread(void* p) {
  static_cast<Server*>(p)->AcceptLoop();
  return 0;
}

DWORD WINAPI UdpThread(void* p) {
  static_cast<Server*>(p)->UdpLoop();
  return 0;
}

DWORD WINAPI ConnThread(void* p) {
  Conn* c = static_cast<Conn*>(p);
  gServer.Handle(c->s, c->ip);
  shutdown(c->s, SD_SEND);
  closesocket(c->s);
  delete c;
  return 0;
}

bool Server::Start(const std::string& pin, const std::string& name) {
  {
    std::lock_guard<std::mutex> lk(m_);
    pin_ = pin;
    name_ = name;
  }
  if (running()) return true;
  error.clear();
  SOCKET l = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
  if (l == INVALID_SOCKET) {
    error = "No se pudo crear el socket de red.";
    return false;
  }
  BOOL excl = TRUE;
  setsockopt(l, SOL_SOCKET, SO_EXCLUSIVEADDRUSE, (const char*)&excl, sizeof excl);
  sockaddr_in a{};
  a.sin_family = AF_INET;
  a.sin_port = htons(kPort);
  a.sin_addr.s_addr = htonl(INADDR_ANY);
  if (bind(l, (sockaddr*)&a, sizeof a) != 0 || listen(l, 16) != 0) {
    closesocket(l);
    error = Fmt("El puerto %d está ocupado (¿hay otro CS Mix abierto?).", kPort);
    return false;
  }
  listen_ = l;
  CloseHandle(CreateThread(nullptr, 0, AcceptThread, this, 0, nullptr));

  SOCKET u = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
  if (u != INVALID_SOCKET) {
    sockaddr_in ua{};
    ua.sin_family = AF_INET;
    ua.sin_port = htons(kDiscoveryPort);
    ua.sin_addr.s_addr = htonl(INADDR_ANY);
    if (bind(u, (sockaddr*)&ua, sizeof ua) == 0) {
      udp_ = u;
      CloseHandle(CreateThread(nullptr, 0, UdpThread, this, 0, nullptr));
    } else {
      // Discovery is a convenience: typing the address on the phone still works.
      closesocket(u);
    }
  }
  return true;
}

void Server::Stop() {
  SOCKET l = listen_, u = udp_;
  listen_ = INVALID_SOCKET;
  udp_ = INVALID_SOCKET;
  if (l != INVALID_SOCKET) closesocket(l);
  if (u != INVALID_SOCKET) closesocket(u);
}

void Server::SetPin(const std::string& p) {
  std::lock_guard<std::mutex> lk(m_);
  pin_ = p;
}

void Server::SetName(const std::string& n) {
  std::lock_guard<std::mutex> lk(m_);
  name_ = n;
}

std::vector<ShareClient> Server::Clients() {
  std::lock_guard<std::mutex> lk(m_);
  std::vector<ShareClient> out;
  int64_t cut = NowMs() - 3 * 60 * 1000;
  for (auto& kv : clients_) {
    if (kv.second.lastSeen >= cut) out.push_back(kv.second);
  }
  return out;
}

std::vector<std::string> Server::Addresses() {
  std::vector<std::string> out;
  char host[256];
  if (gethostname(host, sizeof host) != 0) return out;
  addrinfo hints{}, *res = nullptr;
  hints.ai_family = AF_INET;
  if (getaddrinfo(host, nullptr, &hints, &res) != 0) return out;
  for (addrinfo* p = res; p; p = p->ai_next) {
    auto* sa = reinterpret_cast<sockaddr_in*>(p->ai_addr);
    const unsigned char* b = reinterpret_cast<const unsigned char*>(&sa->sin_addr);
    if (b[0] == 127 || (b[0] == 169 && b[1] == 254)) continue;
    std::string ip = Fmt("%u.%u.%u.%u", b[0], b[1], b[2], b[3]);
    bool dup = false;
    for (auto& x : out) dup = dup || x == ip;
    if (!dup) out.push_back(ip);
  }
  freeaddrinfo(res);
  return out;
}

void Server::AcceptLoop() {
  for (;;) {
    SOCKET l = listen_;
    if (l == INVALID_SOCKET) return;
    sockaddr_in from{};
    int len = sizeof from;
    SOCKET s = accept(l, (sockaddr*)&from, &len);
    if (s == INVALID_SOCKET) {
      if (listen_ == INVALID_SOCKET) return;
      Sleep(50);
      continue;
    }
    DWORD rcv = 15000, snd = 60000;
    setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, (const char*)&rcv, sizeof rcv);
    setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, (const char*)&snd, sizeof snd);
    const unsigned char* b = reinterpret_cast<const unsigned char*>(&from.sin_addr);
    Conn* c = new Conn{s, Fmt("%u.%u.%u.%u", b[0], b[1], b[2], b[3])};
    HANDLE th = CreateThread(nullptr, 64 * 1024, ConnThread, c, STACK_SIZE_PARAM_IS_A_RESERVATION, nullptr);
    if (th) {
      CloseHandle(th);
    } else {
      closesocket(s);
      delete c;
    }
  }
}

void Server::UdpLoop() {
  char buf[512];
  for (;;) {
    SOCKET u = udp_;
    if (u == INVALID_SOCKET) return;
    sockaddr_in from{};
    int len = sizeof from;
    int n = recvfrom(u, buf, sizeof buf - 1, 0, (sockaddr*)&from, &len);
    if (n <= 0) {
      if (udp_ == INVALID_SOCKET) return;
      if (n < 0 && WSAGetLastError() != WSAECONNRESET) Sleep(100);
      continue;
    }
    buf[n] = 0;
    if (Trim8(buf) != kDiscoverMsg) continue;
    std::string name;
    {
      std::lock_guard<std::mutex> lk(m_);
      name = name_;
    }
    std::string reply = "{\"name\":" + JsonStr(name) + Fmt(",\"port\":%d,\"tracks\":%d}", kPort, (int)gLib.total);
    sendto(u, reply.data(), (int)reply.size(), 0, (sockaddr*)&from, len);
  }
}

void Server::Handle(SOCKET s, const std::string& ip) {
  std::string req;
  char buf[4096];
  while (req.find("\r\n\r\n") == std::string::npos) {
    int n = recv(s, buf, sizeof buf, 0);
    if (n <= 0 || req.size() > 32 * 1024) return;
    req.append(buf, n);
  }
  size_t eol = req.find("\r\n");
  std::string first = req.substr(0, eol);
  size_t sp1 = first.find(' '), sp2 = first.rfind(' ');
  if (sp1 == std::string::npos || sp2 <= sp1) return;
  std::string method = first.substr(0, sp1);
  std::string target = first.substr(sp1 + 1, sp2 - sp1 - 1);
  std::map<std::string, std::string> hdr;
  size_t pos = eol + 2;
  while (pos < req.size()) {
    size_t e = req.find("\r\n", pos);
    if (e == std::string::npos || e == pos) break;
    std::string line = req.substr(pos, e - pos);
    pos = e + 2;
    size_t c = line.find(':');
    if (c == std::string::npos) continue;
    std::string k = line.substr(0, c);
    for (auto& ch : k) ch = (char)tolower((unsigned char)ch);
    hdr[k] = Trim8(line.substr(c + 1));
  }
  std::string path = target, query;
  size_t q = target.find('?');
  if (q != std::string::npos) {
    path = target.substr(0, q);
    query = target.substr(q + 1);
  }
  if (method != "GET" && method != "HEAD") {
    ReplyJson(s, 404, "{\"error\":\"route\"}");
    return;
  }

  std::string pin, name;
  {
    std::lock_guard<std::mutex> lk(m_);
    pin = pin_;
    name = name_;
  }
  if (path == "/api/info") {
    ReplyJson(s, 200, "{\"name\":" + JsonStr(name) + Fmt(",\"tracks\":%d,\"version\":1}", (int)gLib.total));
    return;
  }
  if (hdr["x-csmix-pin"] != pin) {
    ReplyJson(s, 401, "{\"error\":\"pin\"}");
    return;
  }
  {
    std::lock_guard<std::mutex> lk(m_);
    ShareClient& c = clients_[ip];
    c.ip = ip;
    c.lastSeen = NowMs();
    auto d = hdr.find("x-csmix-device");
    if (d != hdr.end()) c.name = W(d->second).empty() ? c.name : U8(W(d->second));
    if (c.name.empty()) c.name = ip;
    auto p = hdr.find("x-csmix-playing");
    if (p != hdr.end()) c.playing = U8(W(UrlDecode(p->second, false)));
  }

  if (path == "/api/ping") {
    ReplyJson(s, 200, "{\"ok\":true}");
    return;
  }
  if (path == "/api/library") {
    auto json = gLib.LibraryJson(name);
    ReplyJson(s, 200, *json);
    return;
  }
  if (path == "/api/audio" || path == "/api/peaks" || path == "/api/cover") {
    std::string rel;
    size_t p = 0;
    while (p <= query.size()) {
      size_t amp = query.find('&', p);
      std::string kv = query.substr(p, amp == std::string::npos ? std::string::npos : amp - p);
      if (kv.compare(0, 2, "r=") == 0) rel = UrlDecode(kv.substr(2), true);
      if (amp == std::string::npos) break;
      p = amp + 1;
    }
    TrackP t = gLib.ByRel(rel);
    if (!t) {
      ReplyJson(s, 404, "{\"error\":\"track\"}");
      return;
    }
    std::wstring file;
    if (path == "/api/audio") file = t->path;
    else if (path == "/api/peaks") file = gLib.PeakPath(*t);
    else file = gLib.CoverPath(*t);
    if (!FileExists(file) || !SendFile(s, file)) ReplyJson(s, 404, "{\"error\":\"file\"}");
    return;
  }
  ReplyJson(s, 404, "{\"error\":\"route\"}");
}
