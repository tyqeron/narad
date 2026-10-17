import 'dart:async';
import 'dart:io';
import 'dart:math';

/// Only loads owned user-session modules. Never changes OS defaults or moves streams.
class LinuxAudioRoutes {
  LinuxAudioRoutes({
    Future<String> Function(List<String>)? command,
    String? token,
  }) : command = command ?? pactl,
       token =
           token ??
           '${pid}_${Random.secure().nextInt(0xffffff).toRadixString(16)}' {
    if (!RegExp(r'^[a-zA-Z0-9_]+$').hasMatch(this.token)) {
      throw ArgumentError('Invalid audio route token');
    }
  }
  final Future<String> Function(List<String>) command;
  final String token;
  final List<String> _modules = [];
  static final Set<LinuxAudioRoutes> _active = {};
  bool get created => _modules.isNotEmpty;
  String get speakerSink => 'narad_speaker_$token';
  String get speakerCapture => 'narad_capture_$token';
  String get microphoneSink => 'narad_mic_feed_$token';
  String get microphoneSource => 'narad_microphone_$token';
  String get speakerLabel => 'Narad_Phone_Speaker_$token';
  String get captureLabel => 'Narad_Speaker_Capture_$token';
  String get micFeedLabel => 'Narad_Mic_Feed_$token';
  String get micLabel => 'Narad_Phone_Microphone_$token';

  static Future<String> pactl(List<String> arguments) async {
    Process process;
    try {
      process = await Process.start('pactl', arguments);
    } on ProcessException {
      throw StateError(
        'Install pactl (PulseAudio utilities) to create Linux audio devices. PipeWire must provide pipewire-pulse.',
      );
    }
    final output = process.stdout
        .transform(const SystemEncoding().decoder)
        .join();
    final error = process.stderr
        .transform(const SystemEncoding().decoder)
        .join();
    int status;
    try {
      status = await process.exitCode.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      process.kill();
      throw StateError('The audio server did not respond');
    }
    final text = await output;
    final details = await error;
    if (status != 0) {
      throw StateError('Audio routing failed: ${details.trim()}');
    }
    return text.trim();
  }

  Future<void> _load(List<String> arguments) async {
    final id = await command(['load-module', ...arguments]);
    if (!RegExp(r'^\d+$').hasMatch(id)) {
      throw StateError('Audio server returned an invalid module ID');
    }
    _modules.add(id);
    _active.add(this);
  }

  Future<void> createMeetingDevices() async {
    if (created) throw StateError('Audio devices already exist');
    try {
      await _load([
        'module-null-sink',
        'sink_name=$speakerSink',
        'rate=48000',
        'channels=2',
        'sink_properties=device.description=$speakerLabel',
      ]);
      await _load([
        'module-remap-source',
        'master=$speakerSink.monitor',
        'source_name=$speakerCapture',
        'source_properties=device.description=$captureLabel',
      ]);
      await _load([
        'module-null-sink',
        'sink_name=$microphoneSink',
        'rate=48000',
        'channels=2',
        'sink_properties=device.description=$micFeedLabel',
      ]);
      await _load([
        'module-remap-source',
        'master=$microphoneSink.monitor',
        'source_name=$microphoneSource',
        'source_properties=device.description=$micLabel',
      ]);
    } catch (_) {
      await dispose();
      rethrow;
    }
  }

  Future<void> createSystemMonitor() async {
    if (created) throw StateError('Audio devices already exist');
    final sink = await command(['get-default-sink']);
    if (!RegExp(r'^[a-zA-Z0-9_.:-]{1,255}$').hasMatch(sink)) {
      throw StateError('Unsupported default audio endpoint name');
    }
    try {
      await _load([
        'module-remap-source',
        'master=$sink.monitor',
        'source_name=$speakerCapture',
        'source_properties=device.description=$captureLabel',
      ]);
    } catch (_) {
      await dispose();
      rethrow;
    }
  }

  Future<void>? _disposing;
  Future<void> dispose() =>
      _disposing ??= _dispose().whenComplete(() => _disposing = null);
  Future<void> _dispose() async {
    Object? failure;
    for (final id in _modules.reversed.toList()) {
      try {
        await command(['unload-module', id]);
        _modules.remove(id);
      } catch (e) {
        failure ??= e;
      }
    }
    if (_modules.isEmpty) _active.remove(this);
    if (failure != null) {
      throw StateError('Could not remove a temporary audio device: $failure');
    }
  }

  static Future<void> disposeAll() async {
    Object? failure;
    for (final route in _active.toList()) {
      try {
        await route.dispose();
      } catch (e) {
        failure ??= e;
      }
    }
    if (failure != null) {
      throw StateError('Audio cleanup failed: $failure');
    }
  }
}
