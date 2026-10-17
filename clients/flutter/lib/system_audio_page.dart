import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'audio.dart';
import 'desktop_audio_routes.dart';

class SystemAudioPage extends StatefulWidget {
  const SystemAudioPage({
    super.key,
    required this.audio,
    required this.peer,
    required this.name,
  });
  final AudioController audio;
  final String peer, name;
  @override
  State<SystemAudioPage> createState() => _SystemAudioPageState();
}

class _SystemAudioPageState extends State<SystemAudioPage> {
  LinuxAudioRoutes? _route;
  String? _input, _session, _error;
  List<MediaDeviceInfo> _devices = [];
  bool _busy = false, _closing = false;
  Future<void> _run(Future<void> Function() work) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await work();
      if (_closing) await _stop();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _refresh() async {
    _devices = (await navigator.mediaDevices.enumerateDevices())
        .where((d) => d.kind == 'audioinput')
        .toList();
    if (_route != null) {
      _input = null;
      for (final d in _devices) {
        if (d.deviceId == _route!.speakerCapture ||
            d.label.contains(_route!.captureLabel)) {
          _input = d.deviceId;
          break;
        }
      }
    }
  }

  Future<void> _prepare() async {
    if (Platform.isLinux && _route == null) {
      final route = LinuxAudioRoutes();
      await route.createSystemMonitor();
      _route = route;
    }
    await _refresh();
    if (Platform.isLinux && _input == null) {
      await Future<void>.delayed(const Duration(milliseconds: 700));
      await _refresh();
      if (_input == null) {
        throw StateError(
          'Temporary capture device not yet visible. Refresh and try again.',
        );
      }
    }
  }

  Future<void> _stop() async {
    try {
      if (_session != null) await widget.audio.stop(_session!);
      _session = null;
    } finally {
      await _route?.dispose();
      _route = null;
      _input = null;
    }
  }

  @override
  void dispose() {
    _closing = true;
    unawaited(_stop().catchError((Object _) {}));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text('Laptop audio · ${widget.name}')),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(
          Platform.isLinux
              ? 'Send playback from your current default laptop speaker to this device. Local playback continues. Keep this panel open; minimize Narad to watch your video.'
              : 'Select an installed Stereo Mix or virtual cable recording device. For a cable, route your video application’s output to its matching playback device in Windows sound settings. Keep this panel open while listening.',
        ),
        const SizedBox(height: 16),
        if (_error != null)
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        OutlinedButton.icon(
          onPressed: _busy || _session != null ? null : () => _run(_prepare),
          icon: const Icon(Icons.refresh),
          label: const Text('Prepare / refresh audio capture'),
        ),
        DropdownButtonFormField<String>(
          key: ValueKey('$_input-${_devices.length}'),
          initialValue: _input,
          isExpanded: true,
          decoration: const InputDecoration(
            labelText: 'Laptop playback capture',
          ),
          items: _devices
              .map(
                (d) => DropdownMenuItem(
                  value: d.deviceId,
                  child: Text(
                    d.label.isEmpty ? d.deviceId : d.label,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              )
              .toList(),
          onChanged: _busy || _session != null || Platform.isLinux
              ? null
              : (v) => setState(() => _input = v),
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: _busy || _input == null || _session != null
              ? null
              : () => _run(() async {
                  if (_closing) return;
                  if (widget.audio.links.values.any((l) => !l.camera)) {
                    throw StateError(
                      'Stop other Narad audio sessions first to avoid an audio feedback loop.',
                    );
                  }
                  _session = await widget.audio.start(
                    widget.peer,
                    inputDeviceId: _input,
                    systemAudio: true,
                  );
                }),
          icon: const Icon(Icons.speaker),
          label: const Text('Play laptop audio on device'),
        ),
        if (_session != null)
          const Text(
            'Audio session requested. Playback begins when the receiving device permits audio. Leaving this panel stops sharing.',
          ),
        OutlinedButton.icon(
          onPressed: _busy ? null : () => _run(_stop),
          icon: const Icon(Icons.stop),
          label: const Text('Stop sharing'),
        ),
      ],
    ),
  );
}
