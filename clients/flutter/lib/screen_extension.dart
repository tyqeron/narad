import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';

/// Holds a real Wayland portal virtual monitor until explicitly stopped.
class ScreenExtension {
  Directory? _directory;
  Process? _process;
  bool _stopping = false;
  void Function()? onStopped;

  Future<String> _helper() async {
    final directory = _directory ??= await Directory.systemTemp.createTemp(
      'narad-display-',
    );
    final path = '${directory.path}/screen_virtual_display.py';
    await File(path).writeAsString(
      await rootBundle.loadString('assets/helpers/screen_virtual_display.py'),
    );
    return path;
  }

  Future<bool> supported() async {
    if (!Platform.isLinux ||
        Platform.environment['XDG_SESSION_TYPE'] != 'wayland') {
      return false;
    }
    try {
      final result = await Process.run('python3', [
        await _helper(),
        '--check',
      ]).timeout(const Duration(seconds: 8));
      return result.exitCode == 0 &&
          (jsonDecode(result.stdout as String) as Map)['supported'] == true;
    } catch (_) {
      return false;
    }
  }

  Future<void> start() async {
    if (_process != null) {
      throw StateError(
        'A virtual monitor is already active; stop it before creating another',
      );
    }
    _stopping = false;
    final process = await Process.start('python3', [await _helper()]);
    _process = process;
    final ready = Completer<void>();
    final errors = StringBuffer();
    process.stderr.transform(utf8.decoder).listen((text) {
      if (errors.length < 4096) errors.write(text);
    });
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          try {
            final result = jsonDecode(line) as Map;
            if (!ready.isCompleted && result['ready'] == true) ready.complete();
            if (!ready.isCompleted && result['error'] != null) {
              ready.completeError(StateError(result['error'] as String));
            }
          } catch (error) {
            if (!ready.isCompleted) ready.completeError(error);
          }
        });
    unawaited(
      process.exitCode.then((code) {
        if (identical(_process, process)) _process = null;
        if (!ready.isCompleted) {
          ready.completeError(
            StateError('Virtual display did not start: $errors'),
          );
        }
        if (!_stopping) onStopped?.call();
      }),
    );
    try {
      await ready.future.timeout(const Duration(seconds: 125));
    } catch (_) {
      await stop();
      rethrow;
    }
  }

  Future<void> stop() async {
    _stopping = true;
    final process = _process;
    _process = null;
    if (process != null) {
      process.kill(ProcessSignal.sigterm);
      try {
        await process.exitCode.timeout(const Duration(seconds: 5));
      } on TimeoutException {
        process.kill(ProcessSignal.sigkill);
      }
    }
  }

  Future<void> dispose() async {
    await stop();
    final directory = _directory;
    _directory = null;
    if (directory != null && await directory.exists()) {
      await directory.delete(recursive: true);
    }
  }
}
