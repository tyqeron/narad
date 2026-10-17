import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'api.dart';

abstract class LocatorSound {
  Future<void> start();
  Future<void> stop();
}

/// Generated chirp; no downloaded media, shell interpolation, or volume changes.
class DeviceLocatorSound implements LocatorSound {
  Process? _process;
  Directory? _directory;
  static const _ios = MethodChannel('dev.narad/ios');
  Future<void> _pending = Future.value();
  Future<void> _serialize(Future<void> Function() operation) {
    final next = _pending.then((_) => operation());
    _pending = next.catchError((Object _) {});
    return next;
  }

  @override
  Future<void> start() => _serialize(_start);
  Future<void> _start() async {
    await _stop();
    _directory = await Directory.systemTemp.createTemp('narad-find-');
    final file = File('${_directory!.path}/alert.wav');
    await file.writeAsBytes(locatorWav());
    try {
      if (Platform.isIOS) {
        await _ios.invokeMethod<void>('ringDevice', {'path': file.path});
        return;
      }
      final commands = Platform.isWindows
          ? [
              [
                'powershell.exe',
                '-NoProfile',
                '-NonInteractive',
                '-WindowStyle',
                'Hidden',
                '-Command',
                r'$ErrorActionPreference="Stop"; $p=New-Object System.Media.SoundPlayer; $p.SoundLocation=$env:NARAD_FIND_WAV; $p.Load(); $p.PlaySync()',
              ],
            ]
          : [
              ['paplay', file.path],
              ['aplay', '-q', file.path],
              [
                'ffplay',
                '-nodisp',
                '-autoexit',
                '-loglevel',
                'error',
                file.path,
              ],
            ];
      for (final command in commands) {
        try {
          final process = await Process.start(
            command.first,
            command.skip(1).toList(),
            environment: {'NARAD_FIND_WAV': file.path},
          );
          unawaited(process.stdout.drain<void>());
          unawaited(process.stderr.drain<void>());
          final early = await process.exitCode.timeout(
            const Duration(milliseconds: 250),
            onTimeout: () => -999,
          );
          if (early == -999) {
            _process = process;
            return;
          }
        } on ProcessException {
          continue;
        }
      }
      throw StateError(
        'No audio player available. On Linux install paplay, aplay or FFmpeg.',
      );
    } catch (_) {
      await _stop();
      rethrow;
    }
  }

  @override
  Future<void> stop() => _serialize(_stop);
  Future<void> _stop() async {
    if (Platform.isIOS) await _ios.invokeMethod<void>('stopFinding');
    final process = _process;
    _process = null;
    if (process != null) {
      process.kill();
      await process.exitCode;
    }
    final directory = _directory;
    _directory = null;
    if (directory != null && await directory.exists()) {
      await directory.delete(recursive: true);
    }
  }
}

Uint8List locatorWav() {
  const rate = 16000, seconds = 30, samples = rate * seconds;
  final bytes = Uint8List(44 + samples * 2);
  final data = ByteData.sublistView(bytes);
  void tag(int offset, String text) =>
      bytes.setRange(offset, offset + text.length, text.codeUnits);
  tag(0, 'RIFF');
  data.setUint32(4, bytes.length - 8, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, rate, Endian.little);
  data.setUint32(28, rate * 2, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  tag(36, 'data');
  data.setUint32(40, samples * 2, Endian.little);
  for (var i = 0; i < samples; i++) {
    final t = (i % rate) / rate;
    final envelope = t < .65
        ? math.min(1.0, math.min(t * 50, (.65 - t) * 50))
        : 0.0;
    data.setInt16(
      44 + i * 2,
      (12000 * envelope * math.sin(2 * math.pi * 880 * i / rate)).round(),
      Endian.little,
    );
  }
  return bytes;
}

class FindDeviceController {
  FindDeviceController(
    this.api, {
    LocatorSound? sound,
    this.duration = const Duration(seconds: 30),
  }) : sound = sound ?? DeviceLocatorSound();
  final NaradApi api;
  final LocatorSound sound;
  final Duration duration;
  Timer? _timer;
  String? _active;
  bool get ringing => _active != null;

  Future<void> poll() async {
    if (_active != null) {
      try {
        await api.call({'op': 'platform_validate', 'id': _active});
      } catch (_) {
        await stop();
      }
    }
    final events = await api.call({'op': 'platform_events'});
    for (final item in events['clipboard'] as List? ?? []) {
      await Clipboard.setData(ClipboardData(text: item['text'] as String));
    }
    for (final action in events['actions'] as List? ?? []) {
      final id = action['id'] as String;
      var success = true;
      var message = '';
      try {
        await api.call({'op': 'platform_validate', 'id': id});
        if (action['kind'] == 'find') {
          await stop();
          await sound.start();
          _active = id;
          _timer = Timer(duration, () => unawaited(stop()));
          message = 'Ringing for up to 30 seconds';
        } else if (action['kind'] == 'find_stop') {
          await stop();
          message = 'Ringing stopped';
        } else {
          throw StateError('Unsupported device action');
        }
      } catch (e) {
        success = false;
        message = '$e';
      }
      try {
        await api.call({
          'op': 'platform_result',
          'id': id,
          'success': success,
          'message': message,
        });
      } catch (_) {
        await stop();
      }
    }
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    _active = null;
    await sound.stop();
  }
}
