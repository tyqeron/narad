import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'audio.dart';
import 'desktop_audio_routes.dart';

/// App-owned playback, independent of navigation routes.
class SystemAudioSharing extends ChangeNotifier {
  SystemAudioSharing(
    this.audio, {
    this.routeFactory,
    this.enumerateDevices,
    this.createConnection = createPeerConnection,
  }) {
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_disposed || busy) return;
      sessions.removeWhere((peer, id) => !audio.links.containsKey(id));
      notifyListeners();
    });
  }
  final AudioController audio;
  final LinuxAudioRoutes Function()? routeFactory;
  final Future<List<MediaDeviceInfo>> Function()? enumerateDevices;
  final Future<RTCPeerConnection> Function(Map<String, dynamic>)
  createConnection;
  LinuxAudioRoutes? _route;
  RTCPeerConnection? _audioBackend;
  String? input, error;
  List<MediaDeviceInfo> devices = [];
  bool busy = false, _disposed = false;
  final sessions = <String, String>{};
  final selected = <String>{};
  final recipients = <String, String>{};
  Timer? _timer;
  Future<void>? _work;
  void attach(String peer, String name, Map<String, String> online) {
    recipients.addAll({...online, peer: name});
    selected.add(peer);
  }

  void select(String peer, bool value) {
    if (value) {
      selected.add(peer);
    } else {
      selected.remove(peer);
    }
    notifyListeners();
  }

  void selectInput(String? value) {
    input = value;
    notifyListeners();
  }

  Future<void> shutdown() async {
    _disposed = true;
    _timer?.cancel();
    try {
      await _work;
    } catch (_) {}
    await stop();
    super.dispose();
  }

  Future<void> run(Future<void> Function() work) async {
    if (busy || _disposed) return;
    busy = true;
    error = null;
    notifyListeners();
    try {
      _work = work();
      await _work;
    } catch (e) {
      error = '$e';
    } finally {
      _work = null;
      busy = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> _refresh() async {
    devices =
        (await (enumerateDevices?.call() ??
                navigator.mediaDevices.enumerateDevices()))
            .where((d) => d.kind == 'audioinput')
            .toList();
    if (!devices.any((d) => d.deviceId == input)) {
      input = null;
    }
    if (_route != null) {
      input = null;
      for (final d in devices) {
        if (d.deviceId == _route!.speakerCapture ||
            d.label.contains(_route!.captureLabel)) {
          input = d.deviceId;
          break;
        }
      }
    }
  }

  Future<void> prepare() async {
    if (_disposed) return;
    if (defaultTargetPlatform == TargetPlatform.linux &&
        _audioBackend == null) {
      // The native backend stops its audio-device observer after the last
      // connection closes. Keep an idle connection while discovering/using
      // temporary devices; this does not open a microphone or transmit media.
      _audioBackend = await createConnection({'iceServers': []});
    }
    if (defaultTargetPlatform == TargetPlatform.linux && _route == null) {
      final route = routeFactory?.call() ?? LinuxAudioRoutes();
      await route.createSystemMonitor();
      _route = route;
    }
    await _refresh();
    if (defaultTargetPlatform == TargetPlatform.linux) {
      // PipeWire/PulseAudio device removal and addition reach WebRTC
      // asynchronously, especially after the last capture stream is closed.
      for (var attempt = 0; input == null && attempt < 20; attempt++) {
        if (_disposed) return;
        await Future<void>.delayed(const Duration(milliseconds: 250));
        await _refresh();
      }
      if (input == null && !_disposed) {
        // Do not retain a route that WebRTC cannot see. A retry must create
        // a fresh endpoint rather than repeatedly enumerate a broken one.
        await _route?.dispose();
        _route = null;
        throw StateError(
          'Audio capture did not become available. Check your audio server and prepare again.',
        );
      }
    }
  }

  Future<void> stop() async {
    try {
      for (final peer in sessions.keys.toList()) {
        await stopDevice(peer);
      }
    } finally {
      try {
        await _route?.dispose();
      } finally {
        _route = null;
        input = null;
        final backend = _audioBackend;
        _audioBackend = null;
        await backend?.close();
        await backend?.dispose();
      }
    }
  }

  Future<void> stopDevice(String peer) async {
    final session = sessions.remove(peer);
    if (session != null) await audio.stop(session);
  }

  Future<void> startSelected() async {
    final errors = <String>[];
    for (final peer in selected.toList()) {
      if (_disposed || sessions.containsKey(peer)) continue;
      try {
        sessions[peer] = await audio.start(
          peer,
          inputDeviceId: input,
          systemAudio: true,
        );
      } catch (e) {
        errors.add('${recipients[peer]}: $e');
      }
    }
    if (errors.isNotEmpty) throw StateError(errors.join('\n'));
  }
}
