import 'dart:convert';
import 'package:flutter/services.dart';
import 'api.dart';

/// Observe new text only while OS clipboard access is available. No disk archive.
class ClipboardSync {
  ClipboardSync(this.api, {Future<String?> Function()? read})
    : read =
          read ??
          (() async => (await Clipboard.getData(Clipboard.kTextPlain))?.text);
  final NaradApi api;
  final Future<String?> Function() read;
  bool _busy = false, _enabled = false, _disposed = false;
  String? _seen;
  Future<void> tick({required bool enabled, required bool canRead}) async {
    if (!enabled) {
      _enabled = false;
      _seen = null;
      return;
    }
    if (_disposed || _busy || !canRead) return;
    _busy = true;
    try {
      final text = await read();
      if (_disposed) return;
      if (!_enabled) {
        _seen = text;
        _enabled = true;
        return;
      }
      if (text == _seen) return;
      _seen = text;
      if (text == null ||
          text.isEmpty ||
          text.contains('\u0000') ||
          utf8.encode(text).length > 16384) {
        return;
      }
      await api.call({'op': 'clipboard_publish', 'text': text});
    } catch (_) {
      // Clipboard denial or a disconnected peer must not expose text in diagnostics.
    } finally {
      _busy = false;
    }
  }

  void dispose() {
    _disposed = true;
    _seen = null;
  }
}
