import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'library.dart';
import 'models.dart';

const netPort = 8770;
const discoveryPort = 8771;
const _discoverMsg = 'CSMIX_DISCOVER_1';
const remotePrefix = 'csnet:';

String newPin() => (Random.secure().nextInt(9000) + 1000).toString();

/// Track as the PC shares it: its path becomes `csnet:` plus the relative path.
Map<String, Object?> remoteJson(Track t) {
  final j = t.toJson();
  j['p'] = '$remotePrefix${t.relPath}';
  return j;
}

// =====================================================================
// PC side: shares the library folder on the local network.

class ShareClient {
  ShareClient(this.address, this.name);
  final String address;
  String name;
  DateTime lastSeen = DateTime.now();
  String nowPlaying = '';
}

class LibraryServer extends ChangeNotifier {
  LibraryServer(this.library);

  final LibraryStore library;
  HttpServer? _http;
  RawDatagramSocket? _udp;
  String pin = '';
  String name = 'PC del gimnasio';
  String? error;
  final Map<String, ShareClient> clients = {};
  List<String> addresses = [];
  Timer? _cleanup;

  bool get running => _http != null;

  List<ShareClient> get activeClients {
    final cut = DateTime.now().subtract(const Duration(minutes: 3));
    return clients.values.where((c) => c.lastSeen.isAfter(cut)).toList();
  }

  Future<void> start({required String pin, required String name}) async {
    this.pin = pin;
    this.name = name;
    if (running) {
      notifyListeners();
      return;
    }
    error = null;
    try {
      _http = await HttpServer.bind(InternetAddress.anyIPv4, netPort, shared: true);
      _http!.listen(_handle, onError: (Object e) => debugPrint('server: $e'));
    } catch (e) {
      error = 'No se pudo abrir el puerto $netPort: $e';
      _http = null;
      notifyListeners();
      return;
    }
    try {
      _udp = await RawDatagramSocket.bind(InternetAddress.anyIPv4, discoveryPort, reuseAddress: true);
      _udp!.listen((ev) {
        if (ev != RawSocketEvent.read) return;
        final dg = _udp?.receive();
        if (dg == null) return;
        if (utf8.decode(dg.data, allowMalformed: true).trim() != _discoverMsg) return;
        final reply = utf8.encode(jsonEncode({'name': this.name, 'port': netPort, 'tracks': library.localTracks.length}));
        _udp?.send(reply, dg.address, dg.port);
      });
    } catch (e) {
      // Discovery is a convenience: typing the address still works.
      debugPrint('discovery: $e');
    }
    addresses = await localAddresses();
    _cleanup?.cancel();
    _cleanup = Timer.periodic(const Duration(seconds: 30), (_) => notifyListeners());
    notifyListeners();
  }

  Future<void> stop() async {
    _cleanup?.cancel();
    await _http?.close(force: true);
    _http = null;
    _udp?.close();
    _udp = null;
    notifyListeners();
  }

  static Future<List<String>> localAddresses() async {
    try {
      final ifs = await NetworkInterface.list(type: InternetAddressType.IPv4);
      return [
        for (final i in ifs)
          for (final a in i.addresses)
            if (!a.isLoopback && !a.address.startsWith('169.254')) a.address,
      ];
    } catch (_) {
      return [];
    }
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    res.headers.set('Cache-Control', 'no-store');
    try {
      final path = req.uri.path;
      if (path == '/api/info') {
        return await _json(res, {'name': name, 'tracks': library.localTracks.length, 'version': 1});
      }
      if (req.headers.value('x-csmix-pin') != pin) {
        res.statusCode = HttpStatus.unauthorized;
        return await _json(res, {'error': 'pin'});
      }
      final ip = req.connectionInfo?.remoteAddress.address ?? '?';
      final c = clients.putIfAbsent(ip, () => ShareClient(ip, ip));
      c.lastSeen = DateTime.now();
      c.name = req.headers.value('x-csmix-device') ?? c.name;
      final playing = req.headers.value('x-csmix-playing');
      if (playing != null) c.nowPlaying = Uri.decodeComponent(playing);

      switch (path) {
        case '/api/ping':
          return await _json(res, {'ok': true});
        case '/api/library':
          notifyListeners();
          return await _json(res, {
            'name': name,
            'tracks': [for (final t in library.localTracks) remoteJson(t)],
            'playlists': [
              for (final p in library.playlists)
                {
                  'id': 'pc-${p.id}',
                  'n': p.name,
                  'p': [
                    for (final path in p.paths)
                      if (library.byPath(path) case final t?) '$remotePrefix${t.relPath}',
                  ],
                  if (p.source != null) 's': 'vdj',
                },
            ],
          });
        case '/api/audio' || '/api/peaks' || '/api/cover':
          final rel = req.uri.queryParameters['r'] ?? '';
          final t = library.localByRel(rel);
          if (t == null) {
            res.statusCode = HttpStatus.notFound;
            return await _json(res, {'error': 'track'});
          }
          final file = switch (path) {
            '/api/audio' => File(t.path),
            '/api/peaks' => File(library.peakPath(t.path)),
            _ => File(library.coverPathBase(t.path)),
          };
          if (!await file.exists()) {
            res.statusCode = HttpStatus.notFound;
            return await _json(res, {'error': 'file'});
          }
          res.headers.contentType = path == '/api/audio' ? ContentType.binary : ContentType.binary;
          res.contentLength = await file.length();
          await res.addStream(file.openRead());
          await res.close();
          return;
        default:
          res.statusCode = HttpStatus.notFound;
          return await _json(res, {'error': 'route'});
      }
    } catch (e) {
      try {
        res.statusCode = HttpStatus.internalServerError;
        await res.close();
      } catch (_) {}
    }
  }

  Future<void> _json(HttpResponse res, Object body) async {
    res.headers.contentType = ContentType.json;
    res.write(jsonEncode(body));
    await res.close();
  }
}

// =====================================================================
// Phone side: uses the PC library without copying it.

class FoundPc {
  FoundPc(this.host, this.name, this.tracks);
  final String host; // "ip:port"
  final String name;
  final int tracks;
}

enum NetStatus { off, connecting, online, offline, badPin }

class NetClient extends ChangeNotifier {
  NetClient(this.library, this.dataDir, {required this.deviceName});

  final LibraryStore library;
  final String dataDir;
  final String deviceName;
  String host = '';
  String pin = '';
  String pcName = '';
  NetStatus status = NetStatus.off;
  String? error;
  int cacheLimitMb = 2048;
  String nowPlaying = '';
  final HttpClient _http = HttpClient()..connectionTimeout = const Duration(seconds: 5);
  final Map<String, Future<String?>> _inflight = {};
  final Map<String, double> progress = {};
  Timer? _refresh;

  bool get online => status == NetStatus.online;
  Directory get cacheDir => Directory('$dataDir${Platform.pathSeparator}netcache');

  Uri _uri(String path, [Map<String, String>? q]) {
    final i = host.lastIndexOf(':');
    final h = i > 0 ? host.substring(0, i) : host;
    final p = i > 0 ? int.tryParse(host.substring(i + 1)) ?? netPort : netPort;
    return Uri(scheme: 'http', host: h, port: p, path: path, queryParameters: q);
  }

  Future<HttpClientResponse> _get(String path, [Map<String, String>? q, Duration timeout = const Duration(seconds: 20)]) async {
    final req = await _http.getUrl(_uri(path, q)).timeout(const Duration(seconds: 6));
    req.headers.set('x-csmix-pin', pin);
    req.headers.set('x-csmix-device', deviceName);
    if (nowPlaying.isNotEmpty) req.headers.set('x-csmix-playing', Uri.encodeComponent(nowPlaying));
    return req.close().timeout(timeout);
  }

  /// Finds PCs sharing a library on this Wi-Fi (broadcast, ~1.5 s).
  static Future<List<FoundPc>> discover() async {
    final found = <String, FoundPc>{};
    RawDatagramSocket? s;
    try {
      s = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      s.broadcastEnabled = true;
      s.listen((ev) {
        if (ev != RawSocketEvent.read) return;
        final dg = s?.receive();
        if (dg == null) return;
        try {
          final j = jsonDecode(utf8.decode(dg.data)) as Map;
          final host = '${dg.address.address}:${j['port'] ?? netPort}';
          found[host] = FoundPc(host, j['name'] as String? ?? 'PC', (j['tracks'] as num?)?.toInt() ?? 0);
        } catch (_) {}
      });
      final targets = <InternetAddress>{InternetAddress('255.255.255.255')};
      for (final a in await LibraryServer.localAddresses()) {
        final parts = a.split('.');
        if (parts.length == 4) targets.add(InternetAddress('${parts[0]}.${parts[1]}.${parts[2]}.255'));
      }
      final msg = utf8.encode(_discoverMsg);
      for (var round = 0; round < 3; round++) {
        for (final t in targets) {
          try {
            s.send(msg, t, discoveryPort);
          } catch (_) {}
        }
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    } catch (_) {
      // No Wi-Fi or blocked broadcast: the address can be typed instead.
    } finally {
      s?.close();
    }
    return found.values.toList();
  }

  /// Connects and downloads the shared library list. Returns null or an error message.
  Future<String?> connect(String host, String pin, {bool quiet = false}) async {
    this.host = host.trim();
    this.pin = pin.trim();
    if (!quiet) {
      status = NetStatus.connecting;
      error = null;
      notifyListeners();
    }
    try {
      final r = await _get('/api/library', null, const Duration(seconds: 60));
      if (r.statusCode == HttpStatus.unauthorized) {
        await r.drain<void>();
        status = NetStatus.badPin;
        error = 'El PIN no coincide con el que muestra la PC.';
        notifyListeners();
        return error;
      }
      if (r.statusCode != 200) {
        await r.drain<void>();
        throw HttpException('respuesta ${r.statusCode}');
      }
      final body = await r.transform(utf8.decoder).join();
      final j = jsonDecode(body) as Map;
      pcName = j['name'] as String? ?? 'PC';
      final tracks = [for (final e in (j['tracks'] as List)) Track.fromJson(Map<String, Object?>.from(e as Map))];
      final lists = [
        for (final e in (j['playlists'] as List? ?? const []))
          Playlist.fromJson(Map<String, Object?>.from(e as Map))..source = (e['s'] as String?) == 'vdj' ? 'pc-vdj' : 'pc',
      ];
      library.setRemote(tracks, lists);
      status = NetStatus.online;
      error = null;
      _refresh?.cancel();
      _refresh = Timer.periodic(const Duration(minutes: 3), (_) => refresh());
      notifyListeners();
      return null;
    } catch (e) {
      status = NetStatus.offline;
      error = 'No se pudo conectar con la PC ($e). ¿Está prendida, con CS Mix abierto y en el mismo Wi-Fi?';
      notifyListeners();
      return error;
    }
  }

  /// Reconnects with what was saved; if the PC changed address, finds it again on the Wi-Fi.
  Future<void> resume(String host, String pin, String name) async {
    if (host.isEmpty || pin.isEmpty) return;
    pcName = name;
    final err = await connect(host, pin);
    if (err == null || status == NetStatus.badPin) return;
    for (final pc in await discover()) {
      if (pc.name == name || name.isEmpty) {
        if (await connect(pc.host, pin) == null) return;
      }
    }
  }

  Future<void> refresh() async {
    if (host.isEmpty) return;
    await connect(host, pin, quiet: true);
  }

  void disconnect() {
    _refresh?.cancel();
    status = NetStatus.off;
    host = '';
    library.clearRemote();
    notifyListeners();
  }

  String _rel(Track t) => t.path.substring(remotePrefix.length);

  String _cacheName(Track t) {
    final rel = _rel(t);
    final dot = rel.lastIndexOf('.');
    final ext = dot > 0 ? rel.substring(dot) : '.audio';
    var h = 0xcbf29ce484222325;
    for (final c in utf8.encode('$rel|${t.size}')) {
      h ^= c;
      h = (h * 0x100000001b3) & 0x7FFFFFFFFFFFFFFF;
    }
    return '${h.toRadixString(16)}$ext';
  }

  /// Local copy of a shared track, downloading it if needed. Null on failure.
  Future<String?> fetch(Track t) {
    if (!t.remote) return Future.value(t.path);
    return _inflight.putIfAbsent(t.path, () async {
      try {
        await cacheDir.create(recursive: true);
        final f = File('${cacheDir.path}${Platform.pathSeparator}${_cacheName(t)}');
        if (await f.exists() && await f.length() == t.size) {
          await f.setLastModified(DateTime.now());
          return f.path;
        }
        final r = await _get('/api/audio', {'r': _rel(t)}, const Duration(minutes: 5));
        if (r.statusCode != 200) {
          await r.drain<void>();
          return null;
        }
        final part = File('${f.path}.part');
        final sink = part.openWrite();
        var got = 0;
        final total = r.contentLength > 0 ? r.contentLength : t.size;
        await for (final chunk in r) {
          sink.add(chunk);
          got += chunk.length;
          progress[t.path] = total > 0 ? got / total : 0;
          if (got % (1 << 20) < chunk.length) notifyListeners();
        }
        await sink.close();
        if (await f.exists()) await f.delete();
        await part.rename(f.path);
        progress.remove(t.path);
        unawaited(_evict(keep: f.path));
        notifyListeners();
        return f.path;
      } catch (e) {
        progress.remove(t.path);
        debugPrint('fetch ${t.path}: $e');
        return null;
      } finally {
        unawaited(Future<void>.delayed(Duration.zero, () => _inflight.remove(t.path)));
      }
    });
  }

  /// Peaks and cover come from the PC, already analyzed there.
  Future<void> fetchExtras(Track t) async {
    if (!t.remote || !online) return;
    try {
      final pf = File(library.peakPath(t.path));
      if (!await pf.exists()) {
        final r = await _get('/api/peaks', {'r': _rel(t)});
        if (r.statusCode == 200) {
          final b = await _bytes(r);
          await pf.writeAsBytes(b);
          library.putPeaks(t.path, b);
        } else {
          await r.drain<void>();
        }
      }
      if (t.hasCover) await fetchCover(t);
      library.changed();
    } catch (_) {}
  }

  final Set<String> _coverAsked = {};

  Future<void> fetchCover(Track t) async {
    if (!t.remote || !t.hasCover || !online || !_coverAsked.add(t.path)) return;
    try {
      final cf = File(library.coverPathBase(t.path));
      if (await cf.exists()) return;
      final r = await _get('/api/cover', {'r': _rel(t)});
      if (r.statusCode == 200) {
        await cf.writeAsBytes(await _bytes(r));
        library.changed();
      } else {
        await r.drain<void>();
      }
    } catch (_) {
      _coverAsked.remove(t.path);
    }
  }

  Future<Uint8List> _bytes(HttpClientResponse r) async {
    final b = BytesBuilder(copy: false);
    await for (final c in r) {
      b.add(c);
    }
    return b.toBytes();
  }

  Future<int> cacheBytes() async {
    if (!await cacheDir.exists()) return 0;
    var total = 0;
    await for (final e in cacheDir.list()) {
      if (e is File) total += await e.length();
    }
    return total;
  }

  Future<void> clearCache() async {
    if (await cacheDir.exists()) await cacheDir.delete(recursive: true);
    notifyListeners();
  }

  /// Keeps the cache under the limit, deleting what was used longest ago.
  Future<void> _evict({required String keep}) async {
    try {
      final files = <(File, int, DateTime)>[];
      var total = 0;
      await for (final e in cacheDir.list()) {
        if (e is File && !e.path.endsWith('.part')) {
          final st = await e.stat();
          files.add((e, st.size, st.modified));
          total += st.size;
        }
      }
      final limit = cacheLimitMb * 1024 * 1024;
      files.sort((a, b) => a.$3.compareTo(b.$3));
      for (final (f, size, _) in files) {
        if (total <= limit) break;
        if (f.path == keep) continue;
        await f.delete();
        total -= size;
      }
    } catch (_) {}
  }
}
