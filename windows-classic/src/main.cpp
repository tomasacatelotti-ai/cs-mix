// CS Mix Clásico — window, controls and the glue between library, server and player.
#include "app.h"
#include <commctrl.h>
#include <shellapi.h>
#include <shlobj.h>
#include <windowsx.h>

#include <algorithm>
#include <cmath>
#include <random>
#include <set>

#include "../../packages/cs_audio/src/cs_audio.h"

namespace {

enum {
  IDC_ROOT = 100, IDC_ROOT_BTN, IDC_RESCAN, IDC_PAUSE,
  IDC_SHARE, IDC_PIN, IDC_PIN_BTN, IDC_NAME, IDC_FIREWALL, IDC_NET,
  IDC_SEARCH, IDC_GENRE, IDC_LIST, IDC_MOOD, IDC_PLAYVIEW,
  IDC_TRACKS, IDC_QLABEL, IDC_QUEUE, IDC_QREMOVE, IDC_QCLEAR,
  IDC_NOW, IDC_TIME, IDC_WAVE, IDC_PREV, IDC_PLAY, IDC_PASS, IDC_RESTART, IDC_FX, IDC_FXDUR, IDC_NEXT,
  IDC_AUTOXF, IDC_AUTOSEC, IDC_ENTRY, IDC_GAIN, IDC_SHUFFLE, IDC_REPEAT, IDC_VOL, IDC_OUT, IDC_AUTOSTART,
  IDC_STATUS,
  IDC_LBL_FIRST = 300,
};

enum { CM_NOW = 1, CM_AFTER, CM_QUEUE, CM_FROM, CM_FOLDER };
enum { T_TICK = 1, T_SLOW = 2, T_SEARCH = 3 };

HINSTANCE gInst;
HWND gWnd, gList, gQueue, gStatus, gWave;
HFONT gFont, gBold, gBig;
int gDpi = 96;
std::map<int, HWND> gCtl;
std::vector<std::pair<HWND, int>> gLabels;  // label + control id it sits before

// The list on screen.
std::vector<TrackP> gView;
int gSortCol = -1;
bool gSortDesc = false;
int gSeenStructure = -1, gSeenRevision = -1;
std::string gPin, gShareName;

// Waveform of the track that is sounding.
std::vector<uint8_t> gPeaks;
TrackP gPeaksOf;
double gWaveFrac = 0;
bool gWaveDrag = false;
double gDragFrac = 0;

const wchar_t* kFxNames[4] = {L"Fade", L"Reverse", L"Brake", L"Corte"};
const double kDurs[] = {0.5, 1, 1.5, 2, 3, 4, 5, 6, 8, 10, 12};
const int kAutoSecs[] = {2, 3, 4, 5, 6, 8, 10, 12};

int S(int v) { return MulDiv(v, gDpi, 96); }
HWND C(int id) { return gCtl[id]; }

HWND Make(const wchar_t* cls, const wchar_t* text, DWORD style, int id, DWORD ex = 0) {
  HWND h = CreateWindowExW(ex, cls, text, WS_CHILD | WS_VISIBLE | style, 0, 0, 10, 10, gWnd, (HMENU)(INT_PTR)id, gInst, nullptr);
  SendMessageW(h, WM_SETFONT, (WPARAM)gFont, FALSE);
  gCtl[id] = h;
  return h;
}

void Label(const wchar_t* text, int beforeId) {
  HWND h = CreateWindowExW(0, L"STATIC", text, WS_CHILD | WS_VISIBLE | SS_RIGHT | SS_CENTERIMAGE, 0, 0, 10, 10, gWnd,
                           (HMENU)(INT_PTR)(IDC_LBL_FIRST + gLabels.size()), gInst, nullptr);
  SendMessageW(h, WM_SETFONT, (WPARAM)gFont, FALSE);
  gLabels.push_back({h, beforeId});
}

HWND LabelFor(int id) {
  for (auto& l : gLabels) {
    if (l.second == id) return l.first;
  }
  return nullptr;
}

void SetText(int id, const std::wstring& t) {
  wchar_t cur[1024];
  GetWindowTextW(C(id), cur, 1024);
  if (t != cur) SetWindowTextW(C(id), t.c_str());
}

bool Checked(int id) { return SendMessageW(C(id), BM_GETCHECK, 0, 0) == BST_CHECKED; }
void Check(int id, bool on) { SendMessageW(C(id), BM_SETCHECK, on ? BST_CHECKED : BST_UNCHECKED, 0); }
int ComboSel(int id) { return (int)SendMessageW(C(id), CB_GETCURSEL, 0, 0); }
void ComboAdd(int id, const std::wstring& s) { SendMessageW(C(id), CB_ADDSTRING, 0, (LPARAM)s.c_str()); }
void ComboSet(int id, int i) { SendMessageW(C(id), CB_SETCURSEL, i, 0); }
std::wstring ComboText(int id) {
  int i = ComboSel(id);
  if (i < 0) return {};
  int n = (int)SendMessageW(C(id), CB_GETLBTEXTLEN, i, 0);
  std::wstring s(n + 1, L'\0');
  SendMessageW(C(id), CB_GETLBTEXT, i, (LPARAM)&s[0]);
  s.resize(n);
  return s;
}

std::wstring Label(const Track& t) { return W(t.artist.empty() ? t.title : t.artist + " – " + t.title); }

// ---------------------------------------------------------------- settings

void SaveSettings() {
  const PlayerSettings& s = gPlayer.s;
  IniSetInt(L"autoCrossfade", s.autoCrossfade);
  IniSetNum(L"autoSec", s.autoSec);
  for (int i = 0; i < 4; ++i) IniSetNum(FmtW(L"fxDur%d", i).c_str(), s.fxDur[i]);
  IniSetInt(L"entryMode", s.entryMode);
  IniSetInt(L"autoGain", s.autoGain);
  IniSetInt(L"shuffle", s.shuffle);
  IniSetInt(L"repeat", s.repeat);
  IniSetInt(L"fx", gPlayer.fx);
}

void LoadSettings() {
  PlayerSettings& s = gPlayer.s;
  s.autoCrossfade = IniInt(L"autoCrossfade", 1) != 0;
  s.autoSec = std::max(1.0, std::min(20.0, IniNum(L"autoSec", 6)));
  for (int i = 0; i < 3; ++i) s.fxDur[i] = std::max(0.2, std::min(20.0, IniNum(FmtW(L"fxDur%d", i).c_str(), s.fxDur[i])));
  s.entryMode = std::max(0, std::min(2, IniInt(L"entryMode", 0)));
  s.autoGain = IniInt(L"autoGain", 1) != 0;
  s.shuffle = IniInt(L"shuffle", 0) != 0;
  s.repeat = IniInt(L"repeat", 0) != 0;
  gPlayer.fx = std::max(0, std::min(3, IniInt(L"fx", 0)));
  gPin = U8(IniGet(L"pin", L""));
  if (gPin.size() != 4) {
    std::mt19937 r((unsigned)(GetTickCount() ^ (GetCurrentProcessId() << 16) ^ (uintptr_t)&r));
    gPin = Fmt("%d", 1000 + (int)(r() % 9000));
    IniSet(L"pin", W(gPin));
  }
  gShareName = U8(IniGet(L"shareName", L"PC del gimnasio"));
}

// ---------------------------------------------------------------- start with Windows

const wchar_t* kRunKey = L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";

bool AutostartOn() {
  HKEY k;
  if (RegOpenKeyExW(HKEY_CURRENT_USER, kRunKey, 0, KEY_READ, &k) != ERROR_SUCCESS) return false;
  bool on = RegQueryValueExW(k, L"CS Mix Clasico", nullptr, nullptr, nullptr, nullptr) == ERROR_SUCCESS;
  RegCloseKey(k);
  return on;
}

void SetAutostart(bool on) {
  HKEY k;
  if (RegOpenKeyExW(HKEY_CURRENT_USER, kRunKey, 0, KEY_SET_VALUE, &k) != ERROR_SUCCESS) return;
  if (on) {
    std::wstring cmd = L"\"" + ExePath() + L"\" /min";
    RegSetValueExW(k, L"CS Mix Clasico", 0, REG_SZ, (const BYTE*)cmd.c_str(), (DWORD)((cmd.size() + 1) * sizeof(wchar_t)));
  } else {
    RegDeleteValueW(k, L"CS Mix Clasico");
  }
  RegCloseKey(k);
}

// ---------------------------------------------------------------- sharing

void UpdateShareUi() {
  SetText(IDC_PIN, W(gPin));
}

void SetSharing(bool on) {
  IniSetInt(L"share", on);
  if (on) {
    if (!gServer.Start(gPin, gShareName)) {
      Check(IDC_SHARE, false);
      MessageBoxW(gWnd, W(gServer.error).c_str(), APP_NAME, MB_ICONWARNING);
    }
  } else {
    gServer.Stop();
  }
}

void AllowFirewall() {
  std::wstring args = L"/c \"netsh advfirewall firewall delete rule name=CSMixClasico >nul & "
                      L"netsh advfirewall firewall add rule name=CSMixClasico dir=in action=allow program=\"" +
                      ExePath() + L"\" enable=yes profile=private,domain\"";
  HINSTANCE r = ShellExecuteW(gWnd, L"runas", L"cmd.exe", args.c_str(), nullptr, SW_HIDE);
  if ((INT_PTR)r > 32) {
    MessageBoxW(gWnd,
                L"Listo: el firewall deja entrar a los celulares.\n\n"
                L"La red de esta PC tiene que ser \"Red doméstica\" o \"Red de trabajo\" (no \"Red pública\"). "
                L"Se cambia en Panel de control → Centro de redes y recursos compartidos.",
                APP_NAME, MB_ICONINFORMATION);
  }
}

// ---------------------------------------------------------------- the track list

std::wstring Cell(const Track& t, int col, int depth) {
  switch (col) {
    case 0: return W(t.title);
    case 1: return W(t.artist);
    case 2: return W(t.folder(depth));
    case 3: return t.bpm > 0 ? FmtW(L"%.0f", t.bpm) : L"";
    case 4: return W(KeyName(t.key));
    case 5: return W(t.mood);
    case 6: return t.duration > 0 ? FmtTime(t.duration) : L"";
    case 7: return t.plays > 0 ? FmtW(L"%d", t.plays) : L"";
  }
  return L"";
}

void SortView() {
  if (gSortCol < 0) return;
  int col = gSortCol, depth = gLib.sharedDepth;
  bool desc = gSortDesc;
  auto key = [&](const Track& t) -> double {
    switch (col) {
      case 3: return t.bpm;
      case 4: return t.key < 0 ? 99 : (t.key < 12 ? t.key * 2 + 1 : (t.key - 12) * 2);
      case 6: return t.duration;
      case 7: return t.plays;
    }
    return 0;
  };
  bool numeric = col == 3 || col == 4 || col == 6 || col == 7;
  std::stable_sort(gView.begin(), gView.end(), [&](const TrackP& a, const TrackP& b) {
    int c;
    if (numeric) {
      double x = key(*a), y = key(*b);
      c = x < y ? -1 : (x > y ? 1 : 0);
    } else {
      std::wstring x = Cell(*a, col, depth), y = Cell(*b, col, depth);
      if (x.empty() != y.empty()) return x.empty() ? false : true;  // blanks last
      c = CompareStringW(LOCALE_USER_DEFAULT, NORM_IGNORECASE, x.c_str(), -1, y.c_str(), -1) - 2;
    }
    return desc ? c > 0 : c < 0;
  });
}

std::vector<std::wstring> Words(const std::wstring& s) {
  std::vector<std::wstring> out;
  std::wstring cur;
  for (wchar_t c : Lower(s)) {
    if (c == L' ') {
      if (!cur.empty()) out.push_back(cur);
      cur.clear();
    } else {
      cur += c;
    }
  }
  if (!cur.empty()) out.push_back(cur);
  return out;
}

// Letters without accents, so "cancion" finds "Canción".
std::wstring Fold(const std::wstring& s) {
  std::wstring o = Lower(s);
  wchar_t buf[2048];
  int n = FoldStringW(MAP_COMPOSITE, o.c_str(), (int)o.size(), buf, 2048);
  if (n <= 0) return o;
  std::wstring r;
  for (int i = 0; i < n; ++i) {
    if (buf[i] < 0x300 || buf[i] > 0x36F) r += buf[i];
  }
  return r;
}

void RebuildView() {
  wchar_t q[256];
  GetWindowTextW(C(IDC_SEARCH), q, 256);
  std::vector<std::wstring> words = Words(Fold(q));
  int listSel = ComboSel(IDC_LIST);
  std::wstring genre = ComboSel(IDC_GENRE) > 0 ? ComboText(IDC_GENRE) : L"";
  std::wstring mood = ComboSel(IDC_MOOD) > 0 ? ComboText(IDC_MOOD) : L"";
  std::string genre8 = U8(genre), mood8 = U8(mood);
  gView.clear();
  {
    std::lock_guard<std::mutex> lk(gLib.m);
    const std::vector<TrackP>* src = &gLib.tracks;
    if (listSel > 0 && listSel - 1 < (int)gLib.playlists.size()) src = &gLib.playlists[listSel - 1].tracks;
    for (auto& t : *src) {
      if (!genre8.empty() && t->folder(gLib.sharedDepth) != genre8) continue;
      if (!mood8.empty() && t->mood != mood8) continue;
      if (!words.empty()) {
        std::wstring hay = Fold(W(t->title + " " + t->artist + " " + t->rel + " " + t->genre));
        bool all = true;
        for (auto& w : words) all = all && hay.find(w) != std::wstring::npos;
        if (!all) continue;
      }
      gView.push_back(t);
    }
    SortView();
  }
  ListView_SetItemCountEx(gList, (int)gView.size(), 0);
  InvalidateRect(gList, nullptr, FALSE);
}

void FillCombos() {
  std::wstring g = ComboText(IDC_GENRE), l = ComboText(IDC_LIST);
  std::set<std::wstring, bool (*)(const std::wstring&, const std::wstring&)> genres(
      [](const std::wstring& a, const std::wstring& b) {
        return CompareStringW(LOCALE_USER_DEFAULT, NORM_IGNORECASE, a.c_str(), -1, b.c_str(), -1) == CSTR_LESS_THAN;
      });
  std::vector<std::wstring> lists;
  {
    std::lock_guard<std::mutex> lk(gLib.m);
    for (auto& t : gLib.tracks) {
      std::string f = t->folder(gLib.sharedDepth);
      if (!f.empty()) genres.insert(W(f));
    }
    for (auto& p : gLib.playlists) lists.push_back(FmtW(L"%s  (%d)", W(p.name).c_str(), (int)p.tracks.size()));
  }
  SendMessageW(C(IDC_GENRE), CB_RESETCONTENT, 0, 0);
  ComboAdd(IDC_GENRE, L"Todas las carpetas");
  int gi = 0, k = 1;
  for (auto& x : genres) {
    ComboAdd(IDC_GENRE, x);
    if (x == g) gi = k;
    ++k;
  }
  ComboSet(IDC_GENRE, gi);
  SendMessageW(C(IDC_LIST), CB_RESETCONTENT, 0, 0);
  ComboAdd(IDC_LIST, L"Toda la biblioteca");
  int li = 0;
  for (size_t i = 0; i < lists.size(); ++i) {
    ComboAdd(IDC_LIST, lists[i]);
    if (lists[i].substr(0, lists[i].rfind(L"  (")) == l.substr(0, l.rfind(L"  ("))) li = (int)i + 1;
  }
  ComboSet(IDC_LIST, li);
}

std::vector<int> Selected() {
  std::vector<int> out;
  int i = -1;
  while ((i = ListView_GetNextItem(gList, i, LVNI_SELECTED)) >= 0) {
    if (i < (int)gView.size()) out.push_back(i);
  }
  return out;
}

std::string ViewName() {
  if (ComboSel(IDC_LIST) > 0) {
    std::wstring l = ComboText(IDC_LIST);
    return U8(l.substr(0, l.rfind(L"  (")));
  }
  if (ComboSel(IDC_GENRE) > 0) return U8(ComboText(IDC_GENRE));
  return "Biblioteca";
}

void PlayFromView(int i) {
  if (i < 0 || i >= (int)gView.size()) return;
  gPlayer.PlayList(gView, i, ViewName());
}

void Activate(int i) {
  if (i < 0 || i >= (int)gView.size()) return;
  if (!gPlayer.Current()) PlayFromView(i);
  else gPlayer.PlayNow(gView[i]);
}

void ContextMenu(int x, int y) {
  std::vector<int> sel = Selected();
  if (sel.empty()) return;
  HMENU m = CreatePopupMenu();
  bool on = gPlayer.Current() != nullptr;
  AppendMenuW(m, MF_STRING, CM_NOW, on ? L"Pasar ahora a este tema\tDoble clic" : L"Reproducir\tDoble clic");
  AppendMenuW(m, MF_STRING | (on ? 0 : MF_GRAYED), CM_AFTER, L"Que suene después");
  AppendMenuW(m, MF_STRING, CM_QUEUE, sel.size() > 1 ? L"Agregar los elegidos a la cola" : L"Agregar a la cola");
  AppendMenuW(m, MF_STRING, CM_FROM, L"Reproducir la lista desde acá");
  AppendMenuW(m, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(m, MF_STRING, CM_FOLDER, L"Mostrar el archivo en su carpeta");
  int cmd = TrackPopupMenu(m, TPM_RETURNCMD | TPM_RIGHTBUTTON, x, y, 0, gWnd, nullptr);
  DestroyMenu(m);
  switch (cmd) {
    case CM_NOW: Activate(sel[0]); break;
    case CM_AFTER:
      for (auto it = sel.rbegin(); it != sel.rend(); ++it) gPlayer.PlayAfterCurrent(gView[*it]);
      break;
    case CM_QUEUE:
      for (int i : sel) gPlayer.Enqueue(gView[i]);
      break;
    case CM_FROM: PlayFromView(sel[0]); break;
    case CM_FOLDER: {
      std::wstring args = L"/select,\"" + gView[sel[0]]->path + L"\"";
      ShellExecuteW(gWnd, nullptr, L"explorer.exe", args.c_str(), nullptr, SW_SHOWNORMAL);
      break;
    }
  }
}

// ---------------------------------------------------------------- queue + now playing

void RefreshQueue() {
  int top = (int)SendMessageW(gQueue, LB_GETTOPINDEX, 0, 0);
  int sel = (int)SendMessageW(gQueue, LB_GETCURSEL, 0, 0);
  SendMessageW(gQueue, WM_SETREDRAW, FALSE, 0);
  SendMessageW(gQueue, LB_RESETCONTENT, 0, 0);
  {
    std::lock_guard<std::mutex> lk(gLib.m);
    for (size_t i = 0; i < gPlayer.queue.size(); ++i) {
      const Track& t = *gPlayer.queue[i];
      std::wstring s = (int)i == gPlayer.index ? L"» " : FmtW(L"%d.  ", (int)i + 1);
      s += Label(t);
      if (t.bpm > 0) s += FmtW(L"   · %.0f", t.bpm);
      SendMessageW(gQueue, LB_ADDSTRING, 0, (LPARAM)s.c_str());
    }
  }
  SendMessageW(gQueue, LB_SETTOPINDEX, top, 0);
  if (sel >= 0 && sel < (int)gPlayer.queue.size()) SendMessageW(gQueue, LB_SETCURSEL, sel, 0);
  SendMessageW(gQueue, WM_SETREDRAW, TRUE, 0);
  InvalidateRect(gQueue, nullptr, TRUE);
  SetText(IDC_QLABEL, gPlayer.queue.empty() ? L"Cola" : FmtW(L"Cola · %d temas%s%s", (int)gPlayer.queue.size(),
                                                                gPlayer.source.empty() ? L"" : L" · ",
                                                                W(gPlayer.source).c_str()));
}

void RefreshNow() {
  TrackP cur = gPlayer.Current();
  const DeckView& d = gPlayer.Deck(gPlayer.active);
  if (!cur) {
    SetText(IDC_NOW, L"No hay nada sonando. Doble clic en un tema para arrancar.");
    SetText(IDC_TIME, L"");
    SetText(IDC_NEXT, L"");
  } else {
    std::wstring title;
    {
      std::lock_guard<std::mutex> lk(gLib.m);
      title = Label(*cur);
    }
    std::wstring state = gPlayer.Transitioning() ? L"Pasando a: " : (d.loading() ? L"Cargando: " : (d.error() ? L"No se puede leer: " : L""));
    if (gPlayer.Transitioning() && gPlayer.Incoming()) {
      std::lock_guard<std::mutex> lk(gLib.m);
      title = Label(*gPlayer.Incoming());
    }
    SetText(IDC_NOW, state + title);
    SetText(IDC_TIME, FmtTime(d.position) + L" / " + FmtTime(d.duration) + L"   −" + FmtTime(d.remaining()));
    TrackP n = gPlayer.Next();
    std::wstring next;
    if (gPlayer.Transitioning()) {
      next = L"";
    } else if (n) {
      double entry = gPlayer.EntryFor(*n);
      std::lock_guard<std::mutex> lk(gLib.m);
      next = L"Próximo: " + Label(*n) + (gPlayer.NextLoading() ? L"  (cargando…)" : L"  · entra en " + FmtTime(entry));
    } else {
      next = gPlayer.s.repeat ? L"La cola vuelve a empezar." : L"Es el último tema de la cola.";
    }
    SetText(IDC_NEXT, next);
  }
  SetText(IDC_PLAY, gPlayer.Playing() ? L"Pausa" : L"Reproducir");
  EnableWindow(C(IDC_PASS), gPlayer.Next() && !gPlayer.Transitioning());
  EnableWindow(C(IDC_PREV), cur && !gPlayer.Transitioning());
  EnableWindow(C(IDC_RESTART), cur != nullptr);

  // Waveform.
  if (cur != gPeaksOf || (gPeaks.empty() && cur)) {
    gPeaksOf = cur;
    gPeaks = cur ? gLib.Peaks(*cur) : std::vector<uint8_t>();
    InvalidateRect(gWave, nullptr, FALSE);
  }
  double frac = d.duration > 0 ? d.position / d.duration : 0;
  if (std::fabs(frac - gWaveFrac) > 0.0007 || (!cur && gWaveFrac != 0)) {
    gWaveFrac = cur ? frac : 0;
    InvalidateRect(gWave, nullptr, FALSE);
  }
}

void RefreshStatus() {
  int total = gLib.total, done = gLib.analyzed;
  std::wstring a;
  std::string work, err;
  {
    std::lock_guard<std::mutex> lk(gLib.m);
    work = gLib.currentWork;
    err = gLib.scanError;
  }
  if (gLib.scanning) a = L"Leyendo la carpeta…";
  else if (!err.empty()) a = W(err);
  else if (gLib.paused && done < total) a = L"Análisis en pausa";
  else if (!work.empty()) a = L"Analizando: " + W(work);
  else if (total > 0) a = L"Todo analizado";
  std::wstring p0 = FmtW(L"%d temas · %d analizados", total, done);
  if (total > 0 && done < total) p0 += FmtW(L" (%d %%)", done * 100 / total);
  SendMessageW(gStatus, SB_SETTEXTW, 0, (LPARAM)p0.c_str());
  SendMessageW(gStatus, SB_SETTEXTW, 1, (LPARAM)a.c_str());

  std::wstring net;
  if (!gServer.running()) {
    net = L"Sin compartir.";
  } else {
    auto addrs = gServer.Addresses();
    net = L"Los celulares la encuentran solos";
    if (!addrs.empty()) net += L" (o con la IP " + W(addrs[0]) + L")";
    auto cl = gServer.Clients();
    if (cl.empty()) {
      net += L". Ningún celular conectado.";
    } else {
      net += L". Conectados:";
      for (size_t i = 0; i < cl.size(); ++i) {
        net += (i ? L", " : L" ") + W(cl[i].name);
        if (!cl[i].playing.empty()) net += L" (" + W(cl[i].playing) + L")";
      }
    }
  }
  SetText(IDC_NET, net);

  // Keep the PC awake while it plays or shares (a sleeping laptop drops the phones).
  SetThreadExecutionState(ES_CONTINUOUS | ((gServer.running() || gPlayer.Playing()) ? ES_SYSTEM_REQUIRED : 0));
}

// ---------------------------------------------------------------- waveform control

LRESULT CALLBACK WaveProc(HWND h, UINT msg, WPARAM wp, LPARAM lp) {
  switch (msg) {
    case WM_ERASEBKGND: return 1;
    case WM_PAINT: {
      PAINTSTRUCT ps;
      HDC dc = BeginPaint(h, &ps);
      RECT rc;
      GetClientRect(h, &rc);
      int w = rc.right, ht = rc.bottom;
      HDC mem = CreateCompatibleDC(dc);
      HBITMAP bmp = CreateCompatibleBitmap(dc, w, ht);
      HGDIOBJ old = SelectObject(mem, bmp);
      HBRUSH bg = CreateSolidBrush(RGB(22, 22, 26));
      FillRect(mem, &rc, bg);
      DeleteObject(bg);
      double frac = gWaveDrag ? gDragFrac : gWaveFrac;
      int px = (int)(frac * w);
      HBRUSH played = CreateSolidBrush(RGB(226, 35, 45)), rest = CreateSolidBrush(RGB(105, 105, 115));
      if (!gPeaks.empty()) {
        int bar = std::max(2, S(3)), step = bar + 1;
        for (int x = 0; x < w; x += step) {
          size_t a = (size_t)((double)x / w * gPeaks.size()), b = (size_t)((double)(x + step) / w * gPeaks.size());
          if (b <= a) b = a + 1;
          int v = 0;
          for (size_t i = a; i < b && i < gPeaks.size(); ++i) v = std::max(v, (int)gPeaks[i]);
          int bh = std::max(2, v * (ht - 6) / 255);
          RECT r = {x, (ht - bh) / 2, x + bar, (ht + bh) / 2};
          FillRect(mem, &r, x < px ? played : rest);
        }
      } else if (gPeaksOf) {
        RECT r = {0, ht / 2 - S(2), w, ht / 2 + S(2)};
        FillRect(mem, &r, rest);
        r.right = px;
        FillRect(mem, &r, played);
      }
      if (gPeaksOf) {
        RECT r = {px - 1, 0, px + 1, ht};
        FillRect(mem, &r, (HBRUSH)GetStockObject(WHITE_BRUSH));
      }
      DeleteObject(played);
      DeleteObject(rest);
      BitBlt(dc, 0, 0, w, ht, mem, 0, 0, SRCCOPY);
      SelectObject(mem, old);
      DeleteObject(bmp);
      DeleteDC(mem);
      EndPaint(h, &ps);
      return 0;
    }
    case WM_LBUTTONDOWN:
    case WM_MOUSEMOVE:
    case WM_LBUTTONUP: {
      if (!gPlayer.Current()) return 0;
      if (msg == WM_MOUSEMOVE && !gWaveDrag) return 0;
      RECT rc;
      GetClientRect(h, &rc);
      double f = std::max(0.0, std::min(1.0, (double)GET_X_LPARAM(lp) / std::max(1L, rc.right)));
      if (msg == WM_LBUTTONDOWN) {
        gWaveDrag = true;
        SetCapture(h);
      }
      gDragFrac = f;
      if (msg == WM_LBUTTONUP && gWaveDrag) {
        gWaveDrag = false;
        ReleaseCapture();
        const DeckView& d = gPlayer.Deck(gPlayer.active);
        if (d.duration > 0) gPlayer.Seek(f * d.duration);
        gWaveFrac = f;
      }
      InvalidateRect(h, nullptr, FALSE);
      return 0;
    }
    case WM_SETCURSOR:
      SetCursor(LoadCursor(nullptr, gPlayer.Current() ? IDC_HAND : IDC_ARROW));
      return TRUE;
  }
  return DefWindowProcW(h, msg, wp, lp);
}

// ---------------------------------------------------------------- layout

void Layout() {
  RECT rc;
  GetClientRect(gWnd, &rc);
  int W0 = rc.right, H0 = rc.bottom;
  SendMessageW(gStatus, WM_SIZE, 0, 0);
  RECT sr;
  GetWindowRect(gStatus, &sr);
  int statusH = sr.bottom - sr.top;
  int parts[2] = {S(300), -1};
  SendMessageW(gStatus, SB_SETPARTS, 2, (LPARAM)parts);

  int m = S(10), g = S(6), rowH = S(24);
  HDWP dw = BeginDeferWindowPos(64);
  auto put = [&](HWND h, int x, int y, int w, int hh) {
    if (h) dw = DeferWindowPos(dw, h, nullptr, x, y, std::max(0, w), std::max(0, hh), SWP_NOZORDER | SWP_NOACTIVATE);
  };
  auto putL = [&](int id, int& x, int y, int lw, int w, int hh) {
    put(LabelFor(id), x, y, lw, rowH);  // combos pass their drop-down height; the label stays one row
    x += lw + S(4);
    put(C(id), x, y, w, hh);
    x += w + g * 2;
  };
  int comboH = S(300);

  // Row 1: music folder.
  int y = m, x = m;
  put(LabelFor(IDC_ROOT), x, y, S(110), rowH);
  x += S(114);
  int rootW = W0 - m - x - (S(110) + g + S(96) + 2 * g + S(130)) - g;
  put(C(IDC_ROOT), x, y, rootW, rowH);
  x += rootW + g;
  put(C(IDC_ROOT_BTN), x, y, S(110), rowH);
  x += S(110) + g;
  put(C(IDC_RESCAN), x, y, S(96), rowH);
  x += S(96) + g * 2;
  put(C(IDC_PAUSE), x, y, S(130), rowH);

  // Row 2: sharing with the phones.
  y += rowH + g;
  x = m;
  put(C(IDC_SHARE), x, y, S(190), rowH);
  x += S(190) + g;
  put(LabelFor(IDC_PIN), x, y, S(30), rowH);
  x += S(34);
  put(C(IDC_PIN), x, y, S(44), rowH);
  x += S(44) + g;
  put(C(IDC_PIN_BTN), x, y, S(96), rowH);
  x += S(96) + g * 2;
  putL(IDC_NAME, x, y, S(52), S(150), rowH);
  put(C(IDC_FIREWALL), x, y, S(150), rowH);
  x += S(150) + g * 2;
  put(C(IDC_NET), x, y, W0 - m - x, rowH);

  // Row 3: filters.
  y += rowH + g + S(4);
  x = m;
  putL(IDC_SEARCH, x, y, S(44), S(220), rowH);
  putL(IDC_GENRE, x, y, S(50), S(190), comboH);
  putL(IDC_LIST, x, y, S(34), S(220), comboH);
  putL(IDC_MOOD, x, y, S(44), S(110), comboH);
  put(C(IDC_PLAYVIEW), x, y, std::min(S(170), W0 - m - x), rowH);

  // Bottom panel.
  int bottomH = S(36) + S(56) + S(34) + S(30) + S(30) + g;
  int by = H0 - statusH - bottomH;
  y += rowH + g;
  int listH = by - y - g;
  int qW = S(320);
  put(gList, m, y, W0 - 2 * m - qW - g, listH);
  int qx = W0 - m - qW;
  put(C(IDC_QLABEL), qx, y, qW, S(20));
  put(gQueue, qx, y + S(22), qW, listH - S(22) - S(30));
  put(C(IDC_QREMOVE), qx, y + listH - S(26), (qW - g) / 2, S(26));
  put(C(IDC_QCLEAR), qx + (qW + g) / 2, y + listH - S(26), (qW - g) / 2, S(26));

  y = by;
  put(C(IDC_NOW), m, y, W0 - 2 * m - S(190), S(32));
  put(C(IDC_TIME), W0 - m - S(190), y, S(190), S(32));
  y += S(36);
  put(gWave, m, y, W0 - 2 * m, S(52));
  y += S(56);
  x = m;
  put(C(IDC_PREV), x, y, S(84), S(30));
  x += S(84) + g;
  put(C(IDC_RESTART), x, y, S(110), S(30));
  x += S(110) + g;
  put(C(IDC_PLAY), x, y, S(110), S(30));
  x += S(110) + g;
  put(C(IDC_PASS), x, y, S(120), S(30));
  x += S(120) + g * 3;
  putL(IDC_FX, x, y + S(3), S(44), S(100), comboH);
  putL(IDC_FXDUR, x, y + S(3), S(58), S(70), comboH);
  put(C(IDC_NEXT), x, y, W0 - m - x, S(30));
  y += S(34);
  x = m;
  put(C(IDC_AUTOXF), x, y, S(178), rowH);
  x += S(178);
  put(C(IDC_AUTOSEC), x, y, S(62), comboH);
  x += S(62) + g * 3;
  putL(IDC_ENTRY, x, y, S(50), S(190), comboH);
  put(C(IDC_GAIN), x, y, S(130), rowH);
  x += S(130) + g;
  put(C(IDC_SHUFFLE), x, y, S(86), rowH);
  x += S(86) + g;
  put(C(IDC_REPEAT), x, y, S(80), rowH);
  y += S(30);
  x = m;
  putL(IDC_VOL, x, y, S(56), S(160), rowH);
  putL(IDC_OUT, x, y, S(44), S(280), comboH);
  put(C(IDC_AUTOSTART), x, y, S(240), rowH);
  EndDeferWindowPos(dw);
}

// ---------------------------------------------------------------- building the window

void FillOutputs() {
  SendMessageW(C(IDC_OUT), CB_RESETCONTENT, 0, 0);
  ComboAdd(IDC_OUT, L"La del sistema (predeterminada)");
  std::wstring want = IniGet(L"output", L"");
  int n = csa_device_count(), sel = 0;
  for (int i = 0; i < n; ++i) {
    char buf[512];
    csa_device_name(i, buf, sizeof buf);
    std::wstring name = W(buf);
    ComboAdd(IDC_OUT, name);
    if (!want.empty() && name == want) sel = i + 1;
  }
  ComboSet(IDC_OUT, sel);
}

void OpenOutput() {
  int sel = ComboSel(IDC_OUT);
  int r = csa_open_master(sel <= 0 ? -1 : sel - 1, 0);
  if (r != 0 && sel > 0) {
    ComboSet(IDC_OUT, 0);
    r = csa_open_master(-1, 0);
  }
  if (r != 0) {
    char err[512] = {0};
    csa_last_error(err, sizeof err);
    std::wstring msg = L"No se pudo abrir la salida de audio.";
    if (err[0] && W(err) != msg) msg += L"\n\n" + W(err);
    MessageBoxW(gWnd, msg.c_str(), APP_NAME, MB_ICONWARNING);
  }
}

void FillDurations() {
  SendMessageW(C(IDC_FXDUR), CB_RESETCONTENT, 0, 0);
  int fx = gPlayer.fx, sel = 0;
  double cur = gPlayer.s.fxDur[fx];
  double best = 1e9;
  for (size_t i = 0; i < sizeof kDurs / sizeof kDurs[0]; ++i) {
    ComboAdd(IDC_FXDUR, kDurs[i] == std::floor(kDurs[i]) ? FmtW(L"%.0f s", kDurs[i]) : FmtW(L"%.1f s", kDurs[i]));
    if (std::fabs(kDurs[i] - cur) < best) {
      best = std::fabs(kDurs[i] - cur);
      sel = (int)i;
    }
  }
  ComboSet(IDC_FXDUR, sel);
  EnableWindow(C(IDC_FXDUR), fx != FX_CUT);
}

void CreateControls() {
  Label(L"Carpeta de música:", IDC_ROOT);
  Make(L"EDIT", L"", ES_AUTOHSCROLL | ES_READONLY, IDC_ROOT, WS_EX_CLIENTEDGE);
  Make(L"BUTTON", L"Cambiar carpeta…", WS_TABSTOP | BS_PUSHBUTTON, IDC_ROOT_BTN);
  Make(L"BUTTON", L"Volver a leer", WS_TABSTOP | BS_PUSHBUTTON, IDC_RESCAN);
  Make(L"BUTTON", L"Pausar el análisis", WS_TABSTOP | BS_AUTOCHECKBOX, IDC_PAUSE);

  Make(L"BUTTON", L"Compartir con los celulares", WS_TABSTOP | BS_AUTOCHECKBOX, IDC_SHARE);
  Label(L"PIN:", IDC_PIN);
  HWND pin = Make(L"STATIC", L"", SS_CENTER | SS_CENTERIMAGE | SS_SUNKEN, IDC_PIN);
  SendMessageW(pin, WM_SETFONT, (WPARAM)gBold, FALSE);
  Make(L"BUTTON", L"Cambiar PIN", WS_TABSTOP | BS_PUSHBUTTON, IDC_PIN_BTN);
  Label(L"Nombre:", IDC_NAME);
  Make(L"EDIT", W(gShareName).c_str(), WS_TABSTOP | ES_AUTOHSCROLL, IDC_NAME, WS_EX_CLIENTEDGE);
  Make(L"BUTTON", L"Permitir en el firewall", WS_TABSTOP | BS_PUSHBUTTON, IDC_FIREWALL);
  Make(L"STATIC", L"", SS_LEFT | SS_CENTERIMAGE | SS_ENDELLIPSIS, IDC_NET);

  Label(L"Buscar:", IDC_SEARCH);
  Make(L"EDIT", L"", WS_TABSTOP | ES_AUTOHSCROLL, IDC_SEARCH, WS_EX_CLIENTEDGE);
  SendMessageW(C(IDC_SEARCH), EM_SETCUEBANNER, TRUE, (LPARAM)L"Tema, artista o carpeta");
  Label(L"Carpeta:", IDC_GENRE);
  Make(L"COMBOBOX", L"", WS_TABSTOP | WS_VSCROLL | CBS_DROPDOWNLIST, IDC_GENRE);
  Label(L"Lista:", IDC_LIST);
  Make(L"COMBOBOX", L"", WS_TABSTOP | WS_VSCROLL | CBS_DROPDOWNLIST, IDC_LIST);
  Label(L"Ánimo:", IDC_MOOD);
  Make(L"COMBOBOX", L"", WS_TABSTOP | WS_VSCROLL | CBS_DROPDOWNLIST, IDC_MOOD);
  ComboAdd(IDC_MOOD, L"Cualquiera");
  for (auto m : kMoods) ComboAdd(IDC_MOOD, W(m));
  ComboSet(IDC_MOOD, 0);
  Make(L"BUTTON", L"Reproducir lo que se ve", WS_TABSTOP | BS_PUSHBUTTON, IDC_PLAYVIEW);

  gList = Make(WC_LISTVIEWW, L"", WS_TABSTOP | LVS_REPORT | LVS_OWNERDATA | LVS_SHOWSELALWAYS, IDC_TRACKS, WS_EX_CLIENTEDGE);
  ListView_SetExtendedListViewStyle(gList, LVS_EX_FULLROWSELECT | LVS_EX_DOUBLEBUFFER | LVS_EX_HEADERDRAGDROP);
  struct Col {
    const wchar_t* name;
    int w;
    int fmt;
  } cols[] = {{L"Título", 290, LVCFMT_LEFT},  {L"Artista", 190, LVCFMT_LEFT}, {L"Carpeta", 150, LVCFMT_LEFT},
              {L"BPM", 50, LVCFMT_RIGHT},     {L"Tono", 78, LVCFMT_LEFT},     {L"Ánimo", 80, LVCFMT_LEFT},
              {L"Duración", 66, LVCFMT_RIGHT}, {L"Veces", 52, LVCFMT_RIGHT}};
  for (int i = 0; i < 8; ++i) {
    LVCOLUMNW c{};
    c.mask = LVCF_TEXT | LVCF_WIDTH | LVCF_FMT;
    c.pszText = const_cast<wchar_t*>(cols[i].name);
    c.cx = S(cols[i].w);
    c.fmt = cols[i].fmt;
    ListView_InsertColumn(gList, i, &c);
  }

  Make(L"STATIC", L"Cola", SS_LEFT | SS_CENTERIMAGE | SS_ENDELLIPSIS, IDC_QLABEL);
  SendMessageW(C(IDC_QLABEL), WM_SETFONT, (WPARAM)gBold, FALSE);
  gQueue = Make(L"LISTBOX", L"", WS_TABSTOP | WS_VSCROLL | LBS_NOTIFY | LBS_NOINTEGRALHEIGHT, IDC_QUEUE, WS_EX_CLIENTEDGE);
  Make(L"BUTTON", L"Quitar de la cola", WS_TABSTOP | BS_PUSHBUTTON, IDC_QREMOVE);
  Make(L"BUTTON", L"Vaciar lo que sigue", WS_TABSTOP | BS_PUSHBUTTON, IDC_QCLEAR);

  HWND now = Make(L"STATIC", L"", SS_LEFT | SS_CENTERIMAGE | SS_ENDELLIPSIS | SS_NOPREFIX, IDC_NOW);
  SendMessageW(now, WM_SETFONT, (WPARAM)gBig, FALSE);
  HWND tm = Make(L"STATIC", L"", SS_RIGHT | SS_CENTERIMAGE, IDC_TIME);
  SendMessageW(tm, WM_SETFONT, (WPARAM)gBold, FALSE);
  gWave = Make(L"CSWave", L"", 0, IDC_WAVE);

  Make(L"BUTTON", L"Anterior", WS_TABSTOP | BS_PUSHBUTTON, IDC_PREV);
  Make(L"BUTTON", L"Volver al inicio", WS_TABSTOP | BS_PUSHBUTTON, IDC_RESTART);
  HWND play = Make(L"BUTTON", L"Reproducir", WS_TABSTOP | BS_PUSHBUTTON, IDC_PLAY);
  SendMessageW(play, WM_SETFONT, (WPARAM)gBold, FALSE);
  Make(L"BUTTON", L"Pasar ahora", WS_TABSTOP | BS_PUSHBUTTON, IDC_PASS);
  Label(L"Efecto:", IDC_FX);
  Make(L"COMBOBOX", L"", WS_TABSTOP | CBS_DROPDOWNLIST, IDC_FX);
  for (auto n : kFxNames) ComboAdd(IDC_FX, n);
  ComboSet(IDC_FX, gPlayer.fx);
  Label(L"Duración:", IDC_FXDUR);
  Make(L"COMBOBOX", L"", WS_TABSTOP | WS_VSCROLL | CBS_DROPDOWNLIST, IDC_FXDUR);
  FillDurations();
  Make(L"STATIC", L"", SS_LEFT | SS_CENTERIMAGE | SS_ENDELLIPSIS | SS_NOPREFIX, IDC_NEXT);

  Make(L"BUTTON", L"Crossfade al terminar, desde", WS_TABSTOP | BS_AUTOCHECKBOX, IDC_AUTOXF);
  Check(IDC_AUTOXF, gPlayer.s.autoCrossfade);
  Make(L"COMBOBOX", L"", WS_TABSTOP | WS_VSCROLL | CBS_DROPDOWNLIST, IDC_AUTOSEC);
  int as = 0;
  for (size_t i = 0; i < sizeof kAutoSecs / sizeof kAutoSecs[0]; ++i) {
    ComboAdd(IDC_AUTOSEC, FmtW(L"%d s", kAutoSecs[i]));
    if (std::fabs(kAutoSecs[i] - gPlayer.s.autoSec) < std::fabs(kAutoSecs[as] - gPlayer.s.autoSec)) as = (int)i;
  }
  ComboSet(IDC_AUTOSEC, as);
  Label(L"Entrada:", IDC_ENTRY);
  Make(L"COMBOBOX", L"", WS_TABSTOP | CBS_DROPDOWNLIST, IDC_ENTRY);
  ComboAdd(IDC_ENTRY, L"Punto guardado o sin intro");
  ComboAdd(IDC_ENTRY, L"Saltar la intro");
  ComboAdd(IDC_ENTRY, L"Desde el principio");
  ComboSet(IDC_ENTRY, gPlayer.s.entryMode);
  Make(L"BUTTON", L"Volumen parejo", WS_TABSTOP | BS_AUTOCHECKBOX, IDC_GAIN);
  Check(IDC_GAIN, gPlayer.s.autoGain);
  Make(L"BUTTON", L"Aleatorio", WS_TABSTOP | BS_AUTOCHECKBOX, IDC_SHUFFLE);
  Check(IDC_SHUFFLE, gPlayer.s.shuffle);
  Make(L"BUTTON", L"Repetir", WS_TABSTOP | BS_AUTOCHECKBOX, IDC_REPEAT);
  Check(IDC_REPEAT, gPlayer.s.repeat);

  Label(L"Volumen:", IDC_VOL);
  Make(TRACKBAR_CLASSW, L"", WS_TABSTOP | TBS_HORZ | TBS_NOTICKS | TBS_BOTH, IDC_VOL);
  SendMessageW(C(IDC_VOL), TBM_SETRANGE, TRUE, MAKELONG(0, 100));
  int vol = std::max(0, std::min(100, IniInt(L"volume", 100)));
  SendMessageW(C(IDC_VOL), TBM_SETPOS, TRUE, vol);
  csa_set_master_volume((float)(vol / 100.0 * vol / 100.0));
  Label(L"Salida:", IDC_OUT);
  Make(L"COMBOBOX", L"", WS_TABSTOP | WS_VSCROLL | CBS_DROPDOWNLIST, IDC_OUT);
  Make(L"BUTTON", L"Abrir al prender la PC", WS_TABSTOP | BS_AUTOCHECKBOX, IDC_AUTOSTART);
  Check(IDC_AUTOSTART, AutostartOn());

  gStatus = CreateWindowExW(0, STATUSCLASSNAMEW, L"", WS_CHILD | WS_VISIBLE | SBARS_SIZEGRIP, 0, 0, 0, 0, gWnd,
                            (HMENU)(INT_PTR)IDC_STATUS, gInst, nullptr);
  SendMessageW(gStatus, WM_SETFONT, (WPARAM)gFont, FALSE);
}

std::wstring PickFolder(const std::wstring& title) {
  BROWSEINFOW bi{};
  bi.hwndOwner = gWnd;
  bi.lpszTitle = title.c_str();
  bi.ulFlags = BIF_RETURNONLYFSDIRS | BIF_NEWDIALOGSTYLE | BIF_NONEWFOLDERBUTTON;
  PIDLIST_ABSOLUTE id = SHBrowseForFolderW(&bi);
  if (!id) return {};
  wchar_t buf[MAX_PATH];
  std::wstring out;
  if (SHGetPathFromIDListW(id, buf)) out = buf;
  CoTaskMemFree(id);
  return out;
}

void SetRoot(const std::wstring& r) {
  IniSet(L"root", r);
  SetText(IDC_ROOT, r);
  gLib.SetRoot(r);
}

void Command(int id, int code) {
  switch (id) {
    case IDC_ROOT_BTN: {
      std::wstring r = PickFolder(L"Elegí la carpeta con toda la música (por ejemplo E:\\BIBLIOTECA - EN USO).");
      if (!r.empty()) SetRoot(r);
      break;
    }
    case IDC_RESCAN: gLib.Rescan(); break;
    case IDC_PAUSE:
      gLib.paused = Checked(IDC_PAUSE);
      IniSetInt(L"pauseAnalysis", gLib.paused);
      break;
    case IDC_SHARE: SetSharing(Checked(IDC_SHARE)); break;
    case IDC_PIN_BTN: {
      std::mt19937 r((unsigned)(GetTickCount() * 2654435761u));
      std::string p;
      do p = Fmt("%d", 1000 + (int)(r() % 9000));
      while (p == gPin);
      gPin = p;
      IniSet(L"pin", W(gPin));
      gServer.SetPin(gPin);
      UpdateShareUi();
      break;
    }
    case IDC_NAME:
      if (code == EN_KILLFOCUS) {
        wchar_t b[128];
        GetWindowTextW(C(IDC_NAME), b, 128);
        std::string n = U8(Trim(b));
        if (n.empty()) n = "PC del gimnasio";
        gShareName = n;
        IniSet(L"shareName", W(n));
        gServer.SetName(n);
      }
      break;
    case IDC_FIREWALL: AllowFirewall(); break;
    case IDC_SEARCH:
      if (code == EN_CHANGE) SetTimer(gWnd, T_SEARCH, 300, nullptr);
      break;
    case IDC_GENRE:
    case IDC_LIST:
    case IDC_MOOD:
      if (code == CBN_SELCHANGE) RebuildView();
      break;
    case IDC_PLAYVIEW:
      if (!gView.empty()) gPlayer.PlayList(gView, 0, ViewName());
      break;
    case IDC_QUEUE:
      if (code == LBN_DBLCLK) gPlayer.JumpTo((int)SendMessageW(gQueue, LB_GETCURSEL, 0, 0));
      break;
    case IDC_QREMOVE: gPlayer.RemoveAt((int)SendMessageW(gQueue, LB_GETCURSEL, 0, 0)); break;
    case IDC_QCLEAR:
      for (int i = (int)gPlayer.queue.size() - 1; i > gPlayer.index; --i) gPlayer.RemoveAt(i);
      break;
    case IDC_PREV: gPlayer.Previous(); break;
    case IDC_RESTART: gPlayer.Seek(0); break;
    case IDC_PLAY:
      if (!gPlayer.Current()) {
        std::vector<int> sel = Selected();
        PlayFromView(sel.empty() ? 0 : sel[0]);
      } else {
        gPlayer.TogglePlay();
      }
      break;
    case IDC_PASS: gPlayer.PassNow(); break;
    case IDC_FX:
      if (code == CBN_SELCHANGE) {
        gPlayer.fx = std::max(0, ComboSel(IDC_FX));
        FillDurations();
        SaveSettings();
      }
      break;
    case IDC_FXDUR:
      if (code == CBN_SELCHANGE && gPlayer.fx != FX_CUT) {
        gPlayer.s.fxDur[gPlayer.fx] = kDurs[std::max(0, ComboSel(IDC_FXDUR))];
        SaveSettings();
      }
      break;
    case IDC_AUTOXF:
      gPlayer.s.autoCrossfade = Checked(IDC_AUTOXF);
      SaveSettings();
      break;
    case IDC_AUTOSEC:
      if (code == CBN_SELCHANGE) {
        gPlayer.s.autoSec = kAutoSecs[std::max(0, ComboSel(IDC_AUTOSEC))];
        SaveSettings();
      }
      break;
    case IDC_ENTRY:
      if (code == CBN_SELCHANGE) {
        gPlayer.s.entryMode = std::max(0, ComboSel(IDC_ENTRY));
        SaveSettings();
      }
      break;
    case IDC_GAIN:
      gPlayer.s.autoGain = Checked(IDC_GAIN);
      gPlayer.ReapplyGain();
      SaveSettings();
      break;
    case IDC_SHUFFLE:
      gPlayer.s.shuffle = Checked(IDC_SHUFFLE);
      SaveSettings();
      break;
    case IDC_REPEAT:
      gPlayer.s.repeat = Checked(IDC_REPEAT);
      SaveSettings();
      gPlayer.changed = true;
      break;
    case IDC_OUT:
      if (code == CBN_SELCHANGE) {
        IniSet(L"output", ComboSel(IDC_OUT) > 0 ? ComboText(IDC_OUT) : L"");
        OpenOutput();
      }
      break;
    case IDC_AUTOSTART: SetAutostart(Checked(IDC_AUTOSTART)); break;
  }
}

LRESULT Notify(NMHDR* nh) {
  if (nh->hwndFrom != gList) return 0;
  switch (nh->code) {
    case LVN_GETDISPINFOW: {
      auto* di = reinterpret_cast<NMLVDISPINFOW*>(nh);
      int i = di->item.iItem;
      if (!(di->item.mask & LVIF_TEXT) || i < 0 || i >= (int)gView.size()) return 0;
      std::wstring s;
      {
        std::lock_guard<std::mutex> lk(gLib.m);
        s = Cell(*gView[i], di->item.iSubItem, gLib.sharedDepth);
      }
      lstrcpynW(di->item.pszText, s.c_str(), di->item.cchTextMax);
      return 0;
    }
    case LVN_COLUMNCLICK: {
      auto* nl = reinterpret_cast<NMLISTVIEW*>(nh);
      if (gSortCol == nl->iSubItem) gSortDesc = !gSortDesc;
      else {
        gSortCol = nl->iSubItem;
        gSortDesc = nl->iSubItem == 7;  // most played first
      }
      RebuildView();
      return 0;
    }
    case LVN_ITEMACTIVATE: {
      auto* ia = reinterpret_cast<NMITEMACTIVATE*>(nh);
      Activate(ia->iItem);
      return 0;
    }
    case NM_RCLICK: {
      POINT p;
      GetCursorPos(&p);
      ContextMenu(p.x, p.y);
      return 0;
    }
    case NM_CUSTOMDRAW: {
      auto* cd = reinterpret_cast<NMLVCUSTOMDRAW*>(nh);
      if (cd->nmcd.dwDrawStage == CDDS_PREPAINT) return CDRF_NOTIFYITEMDRAW;
      if (cd->nmcd.dwDrawStage == CDDS_ITEMPREPAINT) {
        size_t i = cd->nmcd.dwItemSpec;
        if (i < gView.size()) {
          if (gView[i] == gPlayer.Current()) cd->clrText = RGB(200, 20, 30);
          else if (gView[i] == gPlayer.Next()) cd->clrText = RGB(176, 106, 0);
        }
        return CDRF_DODEFAULT;
      }
      return CDRF_DODEFAULT;
    }
  }
  return 0;
}

LRESULT CALLBACK WndProc(HWND h, UINT msg, WPARAM wp, LPARAM lp) {
  switch (msg) {
    case WM_CREATE: return 0;
    case WM_SIZE:
      Layout();
      InvalidateRect(h, nullptr, TRUE);
      return 0;
    case WM_GETMINMAXINFO: {
      auto* mm = reinterpret_cast<MINMAXINFO*>(lp);
      mm->ptMinTrackSize.x = S(980);
      mm->ptMinTrackSize.y = S(600);
      return 0;
    }
    case WM_COMMAND: Command(LOWORD(wp), HIWORD(wp)); return 0;
    case WM_NOTIFY: return Notify(reinterpret_cast<NMHDR*>(lp));
    case WM_CONTEXTMENU:
      if ((HWND)wp == gList && GET_X_LPARAM(lp) == -1) {
        RECT r;
        int i = ListView_GetNextItem(gList, -1, LVNI_FOCUSED);
        if (i >= 0 && ListView_GetItemRect(gList, i, &r, LVIR_LABEL)) {
          POINT p = {r.left, r.bottom};
          ClientToScreen(gList, &p);
          ContextMenu(p.x, p.y);
        }
        return 0;
      }
      break;
    case WM_HSCROLL:
      if ((HWND)lp == C(IDC_VOL)) {
        int v = (int)SendMessageW(C(IDC_VOL), TBM_GETPOS, 0, 0);
        csa_set_master_volume((float)(v / 100.0 * v / 100.0));
        if (LOWORD(wp) == TB_ENDTRACK || LOWORD(wp) == TB_THUMBPOSITION) IniSetInt(L"volume", v);
      }
      return 0;
    case WM_TIMER:
      if (wp == T_TICK) {
        gPlayer.Tick();
        static int n = 0;
        if (gPlayer.changed) {
          gPlayer.changed = false;
          RefreshQueue();
          InvalidateRect(gList, nullptr, FALSE);
        }
        if (++n % 4 == 0) RefreshNow();
        else {
          const DeckView& d = gPlayer.Deck(gPlayer.active);
          double frac = d.duration > 0 ? d.position / d.duration : 0;
          if (gPlayer.Current() && std::fabs(frac - gWaveFrac) > 0.0007) {
            gWaveFrac = frac;
            InvalidateRect(gWave, nullptr, FALSE);
          }
        }
      } else if (wp == T_SLOW) {
        int st = gLib.structure;
        if (st != gSeenStructure) {
          gSeenStructure = st;
          FillCombos();
          RebuildView();
          gSeenRevision = gLib.revision;
        } else if (gLib.revision != gSeenRevision) {
          gSeenRevision = gLib.revision;
          InvalidateRect(gList, nullptr, FALSE);
        }
        RefreshStatus();
      } else if (wp == T_SEARCH) {
        KillTimer(h, T_SEARCH);
        RebuildView();
      }
      return 0;
    case WM_CLOSE:
      if (gPlayer.Playing() &&
          MessageBoxW(h, L"Está sonando música y se va a cortar. ¿Cerrar CS Mix Clásico?", APP_NAME, MB_YESNO | MB_ICONQUESTION) != IDYES) {
        return 0;
      }
      DestroyWindow(h);
      return 0;
    case WM_ENDSESSION:
      // Windows is shutting down: keep the analysis and the play counts done so far.
      if (wp) {
        SaveSettings();
        gLib.SaveIfDirty();
      }
      return 0;
    case WM_DESTROY:
      KillTimer(h, T_TICK);
      KillTimer(h, T_SLOW);
      PostQuitMessage(0);
      return 0;
  }
  return DefWindowProcW(h, msg, wp, lp);
}

void MakeFonts() {
  HDC dc = GetDC(nullptr);
  gDpi = GetDeviceCaps(dc, LOGPIXELSY);
  ReleaseDC(nullptr, dc);
  NONCLIENTMETRICSW nm{};
  nm.cbSize = sizeof nm;
  SystemParametersInfoW(SPI_GETNONCLIENTMETRICS, sizeof nm, &nm, 0);
  LOGFONTW lf = nm.lfMessageFont;
  gFont = CreateFontIndirectW(&lf);
  lf.lfWeight = FW_BOLD;
  gBold = CreateFontIndirectW(&lf);
  lf.lfHeight = lf.lfHeight * 3 / 2;
  gBig = CreateFontIndirectW(&lf);
}

}  // namespace

int WINAPI wWinMain(HINSTANCE inst, HINSTANCE, PWSTR cmdLine, int show) {
  gInst = inst;
  HANDLE single = CreateMutexW(nullptr, TRUE, L"CSMixClasico_SingleInstance");
  if (GetLastError() == ERROR_ALREADY_EXISTS) {
    HWND other = FindWindowW(L"CSMixClasico", nullptr);
    if (other) {
      ShowWindow(other, SW_RESTORE);
      SetForegroundWindow(other);
    }
    return 0;
  }
  bool minimized = cmdLine && wcsstr(cmdLine, L"/min");

  WSADATA wsa;
  WSAStartup(MAKEWORD(2, 2), &wsa);
  CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  INITCOMMONCONTROLSEX icc = {sizeof icc, ICC_LISTVIEW_CLASSES | ICC_BAR_CLASSES | ICC_STANDARD_CLASSES | ICC_WIN95_CLASSES};
  InitCommonControlsEx(&icc);
  MakeFonts();
  LoadSettings();

  int audio = csa_init();
  csa_set_curve(1);

  WNDCLASSEXW wc{sizeof wc};
  wc.lpfnWndProc = WndProc;
  wc.hInstance = inst;
  wc.hIcon = LoadIconW(inst, MAKEINTRESOURCEW(1));
  wc.hIconSm = (HICON)LoadImageW(inst, MAKEINTRESOURCEW(1), IMAGE_ICON, GetSystemMetrics(SM_CXSMICON), GetSystemMetrics(SM_CYSMICON), 0);
  wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
  wc.hbrBackground = (HBRUSH)(COLOR_BTNFACE + 1);
  wc.lpszClassName = L"CSMixClasico";
  RegisterClassExW(&wc);
  WNDCLASSEXW wv{sizeof wv};
  wv.lpfnWndProc = WaveProc;
  wv.hInstance = inst;
  wv.hCursor = LoadCursor(nullptr, IDC_HAND);
  wv.lpszClassName = L"CSWave";
  RegisterClassExW(&wv);

  RECT work;
  SystemParametersInfoW(SPI_GETWORKAREA, 0, &work, 0);
  int ww = std::min(S(1200), (int)(work.right - work.left)), wh = std::min(S(800), (int)(work.bottom - work.top));
  gWnd = CreateWindowExW(0, L"CSMixClasico", APP_NAME, WS_OVERLAPPEDWINDOW | WS_CLIPCHILDREN, work.left + (work.right - work.left - ww) / 2,
                         work.top + (work.bottom - work.top - wh) / 2, ww, wh, nullptr, nullptr, inst, nullptr);
  CreateControls();
  FillOutputs();
  UpdateShareUi();

  gLib.Start(DataDir());
  gLib.paused = IniInt(L"pauseAnalysis", 0) != 0;
  Check(IDC_PAUSE, gLib.paused);

  bool smallScreen = work.right - work.left < S(1300);
  ShowWindow(gWnd, minimized ? SW_SHOWMINNOACTIVE : (smallScreen ? SW_SHOWMAXIMIZED : show));
  UpdateWindow(gWnd);
  Layout();
  SetTimer(gWnd, T_TICK, 50, nullptr);
  SetTimer(gWnd, T_SLOW, 1000, nullptr);

  std::wstring root = IniGet(L"root", L"");
  if (root.empty() && DirExists(L"E:\\BIBLIOTECA - EN USO")) root = L"E:\\BIBLIOTECA - EN USO";
  if (root.empty() && !minimized) {
    MessageBoxW(gWnd, L"Elegí la carpeta donde está toda la música. Se lee una sola vez y después se actualiza sola.", APP_NAME,
                MB_ICONINFORMATION);
    root = PickFolder(L"Elegí la carpeta con toda la música.");
  }
  if (!root.empty()) SetRoot(root);

  if (IniInt(L"share", 1)) {
    Check(IDC_SHARE, true);
    SetSharing(true);
  }
  // Audio last: a warning box here must not hold up the library or the phones.
  if (audio == 0) {
    OpenOutput();
  } else {
    MessageBoxW(gWnd, L"No se pudo iniciar el audio de Windows. La biblioteca y el compartir con los celulares funcionan igual.",
                APP_NAME, MB_ICONWARNING);
  }

  MSG msg;
  while (GetMessageW(&msg, nullptr, 0, 0) > 0) {
    if (msg.message == WM_KEYDOWN && msg.wParam == VK_SPACE && (msg.hwnd == gList || msg.hwnd == gQueue)) {
      gPlayer.Current() ? gPlayer.TogglePlay() : PlayFromView(std::max(0, ListView_GetNextItem(gList, -1, LVNI_FOCUSED)));
      continue;
    }
    if (msg.message == WM_KEYDOWN && msg.wParam == 'F' && (GetKeyState(VK_CONTROL) & 0x8000)) {
      SetFocus(C(IDC_SEARCH));
      SendMessageW(C(IDC_SEARCH), EM_SETSEL, 0, -1);
      continue;
    }
    if (IsDialogMessageW(gWnd, &msg)) continue;
    TranslateMessage(&msg);
    DispatchMessageW(&msg);
  }

  SaveSettings();
  SetThreadExecutionState(ES_CONTINUOUS);
  gServer.Stop();
  gPlayer.Clear();
  gLib.Stop();
  csa_shutdown();
  WSACleanup();
  CoUninitialize();
  CloseHandle(single);
  return 0;
}
