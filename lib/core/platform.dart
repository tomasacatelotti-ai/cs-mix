import 'dart:io';

import 'package:cs_audio/cs_audio.dart';
import 'package:flutter/services.dart';

/// An audio output the user can pick for the master or the pre-listen signal.
class OutputDevice {
  const OutputDevice({required this.key, required this.name, required this.kind, this.androidId = 0, this.index = -1});

  /// Stable key saved in settings ("kind|name"); ids change between connections.
  final String key;
  final String name;

  /// bluetooth, headphones, usb, speaker, default, other
  final String kind;
  final int androidId;
  final int index;

  String get label {
    switch (kind) {
      case 'bluetooth':
        return '$name (Bluetooth)';
      case 'headphones':
        return '$name (auriculares)';
      case 'usb':
        return '$name (USB)';
      case 'speaker':
        return 'Parlante del celular';
      default:
        return name;
    }
  }
}

/// Bridges to the Android side (MainActivity / PlaybackService) and Windows paths.
class Native {
  static const _ch = MethodChannel('cs_mix/native');
  static void Function(String action)? _onMedia;

  static void listenMedia(void Function(String action) cb, {void Function()? onDevices}) {
    _onMedia = cb;
    if (!Platform.isAndroid) return;
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'media') _onMedia?.call(call.arguments as String);
      if (call.method == 'devicesChanged') onDevices?.call();
      return null;
    });
  }

  static Future<String> deviceName() async {
    if (Platform.isAndroid) {
      try {
        return await _ch.invokeMethod<String>('deviceName') ?? 'Celular';
      } catch (_) {
        return 'Celular';
      }
    }
    return Platform.localHostname;
  }

  static Future<String> appDir() async {
    String dir;
    if (Platform.isAndroid) {
      dir = (await _ch.invokeMethod<String>('appDir'))!;
    } else if (Platform.isWindows) {
      dir = '${Platform.environment['APPDATA'] ?? Directory.current.path}\\CS Mix';
    } else {
      dir = '${Platform.environment['HOME'] ?? Directory.current.path}/.cs_mix';
    }
    await Directory(dir).create(recursive: true);
    return dir;
  }

  static Future<String> defaultMusicRoot() async {
    if (Platform.isAndroid) {
      final ext = await _ch.invokeMethod<String>('externalRoot') ?? '/storage/emulated/0';
      final lib = Directory('$ext/Music/BIBLIOTECA - EN USO');
      if (await lib.exists()) return lib.path;
      return '$ext/Music';
    }
    if (Platform.isWindows) {
      const vdj = r'E:\BIBLIOTECA - EN USO';
      if (await Directory(vdj).exists()) return vdj;
      return '${Platform.environment['USERPROFILE'] ?? 'C:'}\\Music';
    }
    return Platform.environment['HOME'] ?? '/';
  }

  /// Top-level places for the in-app folder browser.
  static Future<List<String>> roots() async {
    if (Platform.isAndroid) {
      final ext = await _ch.invokeMethod<String>('externalRoot') ?? '/storage/emulated/0';
      final out = <String>[ext];
      final sd = await _ch.invokeMethod<List<Object?>>('storageRoots');
      for (final s in sd ?? const []) {
        if (s is String && !out.contains(s)) out.add(s);
      }
      return out;
    }
    if (Platform.isWindows) {
      // In parallel and with a time limit: an empty card reader or DVD drive can stall for seconds.
      final letters = [for (var c = 'C'.codeUnitAt(0); c <= 'Z'.codeUnitAt(0); c++) '${String.fromCharCode(c)}:\\'];
      final ok = await Future.wait(letters.map((d) => Directory(d)
          .exists()
          .timeout(const Duration(milliseconds: 1500), onTimeout: () => false)
          .catchError((Object _) => false)));
      return [for (var i = 0; i < letters.length; i++) if (ok[i]) letters[i]];
    }
    return ['/'];
  }

  static Future<bool> hasStorageAccess() async {
    if (!Platform.isAndroid) return true;
    return await _ch.invokeMethod<bool>('hasStorage') ?? false;
  }

  /// Android's own folder chooser. Returns the path, null if cancelled, '?' if that folder can't be used.
  static Future<String?> pickFolderSystem(String initial) async {
    if (!Platform.isAndroid) return '?';
    try {
      return await _ch.invokeMethod<String>('pickFolder', {'initial': initial});
    } catch (_) {
      return '?';
    }
  }

  static Future<void> requestStorageAccess() async {
    if (!Platform.isAndroid) return;
    await _ch.invokeMethod('requestStorage');
  }

  static Future<List<OutputDevice>> outputs() async {
    if (Platform.isAndroid) {
      final raw = await _ch.invokeMethod<List<Object?>>('outputDevices') ?? const [];
      final out = <OutputDevice>[];
      final seen = <String>{};
      for (final r in raw) {
        final m = Map<String, Object?>.from(r as Map);
        final kind = m['kind'] as String? ?? 'other';
        final name = (m['name'] as String? ?? '').trim();
        final key = '$kind|$name';
        if (!seen.add(key)) continue;
        out.add(OutputDevice(key: key, name: name.isEmpty ? kind : name, kind: kind, androidId: m['id'] as int? ?? 0));
      }
      return out;
    }
    final list = CsAudio.devices();
    return [
      for (var i = 0; i < list.length; i++)
        OutputDevice(
          key: 'win|${list[i].name}',
          name: list[i].name + (list[i].isDefault ? ' (predeterminado)' : ''),
          kind: 'other',
          index: i,
        ),
    ];
  }

  static Future<void> serviceUpdate({required bool active, String title = '', bool playing = false}) async {
    if (!Platform.isAndroid) return;
    try {
      await _ch.invokeMethod(active ? 'serviceUpdate' : 'serviceStop', {'title': title, 'playing': playing});
    } on PlatformException {
      // The notification is a convenience; playback does not depend on it.
    }
  }

  static Future<void> keepScreenOn(bool on) async {
    if (!Platform.isAndroid) return;
    try {
      await _ch.invokeMethod('keepScreenOn', on);
    } on PlatformException {
      // ignore
    }
  }
}
