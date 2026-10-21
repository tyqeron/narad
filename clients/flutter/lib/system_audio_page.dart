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
    this.recipients = const {},
    this.routeFactory,
    this.enumerateDevices,
  });
  final AudioController audio;
  final String peer, name;
  final Map<String, String> recipients;
  final LinuxAudioRoutes Function()? routeFactory;
  final Future<List<MediaDeviceInfo>> Function()? enumerateDevices;
  @override
  State<SystemAudioPage> createState() => _SystemAudioPageState();
}

class _SystemAudioPageState extends State<SystemAudioPage> {
  LinuxAudioRoutes? _route;
  String? _input, _error;
  List<MediaDeviceInfo> _devices = [];
  bool _busy = false, _closing = false;
  final _sessions = <String, String>{};
  late final _selected = <String>{widget.peer};
  Timer? _timer;
  Map<String, String> get _recipients => {
    widget.peer: widget.name,
    ...widget.recipients,
  };

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && !_busy) {
        setState(() {
          _sessions.removeWhere(
            (peer, id) => !widget.audio.links.containsKey(id),
          );
        });
      }
    });
  }

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
    _devices =
        (await (widget.enumerateDevices?.call() ??
                navigator.mediaDevices.enumerateDevices()))
            .where((d) => d.kind == 'audioinput')
            .toList();
    if (!_devices.any((d) => d.deviceId == _input)) {
      _input = null;
    }
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
      final route = widget.routeFactory?.call() ?? LinuxAudioRoutes();
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
      for (final peer in _sessions.keys.toList()) {
        await _stopDevice(peer);
      }
    } finally {
      await _route?.dispose();
      _route = null;
      _input = null;
    }
  }

  Future<void> _stopDevice(String peer) async {
    final session = _sessions.remove(peer);
    if (session != null) await widget.audio.stop(session);
  }

  Future<void> _startSelected() async {
    final errors = <String>[];
    for (final peer in _selected.toList()) {
      if (_closing || _sessions.containsKey(peer)) continue;
      try {
        _sessions[peer] = await widget.audio.start(
          peer,
          inputDeviceId: _input,
          systemAudio: true,
        );
      } catch (e) {
        errors.add('${_recipients[peer]}: $e');
      }
    }
    if (errors.isNotEmpty) throw StateError(errors.join('\n'));
  }

  @override
  void dispose() {
    _closing = true;
    _timer?.cancel();
    unawaited(_stop().catchError((Object _) {}));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Share laptop audio')),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(
          Platform.isLinux
              ? 'Send playback from your current default laptop speaker to selected devices. Local playback continues. Keep this panel open; minimize Narad to watch your video.'
              : 'Select an installed Stereo Mix or virtual cable recording device. For a cable, route your video application’s output to its matching playback device in Windows sound settings. Keep this panel open while listening.',
        ),
        const SizedBox(height: 16),
        if (_error != null)
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        OutlinedButton.icon(
          onPressed: _busy || _sessions.isNotEmpty
              ? null
              : () => _run(_prepare),
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
          onChanged: _busy || _sessions.isNotEmpty || Platform.isLinux
              ? null
              : (v) => setState(() => _input = v),
        ),
        const SizedBox(height: 16),
        Text(
          'Listening devices',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        for (final device in _recipients.entries)
          CheckboxListTile(
            value: _selected.contains(device.key),
            title: Text(device.value),
            subtitle: Text(
              _sessions.containsKey(device.key)
                  ? 'Sharing requested · audio plays after receiver approval'
                  : 'Select to receive laptop audio',
            ),
            onChanged: _busy
                ? null
                : (selected) => setState(() {
                    if (selected == true) {
                      _selected.add(device.key);
                    } else {
                      _selected.remove(device.key);
                    }
                  }),
            secondary: _sessions.containsKey(device.key)
                ? IconButton(
                    tooltip: 'Stop audio on ${device.value}',
                    icon: const Icon(Icons.stop_circle_outlined),
                    onPressed: _busy
                        ? null
                        : () => _run(() => _stopDevice(device.key)),
                  )
                : null,
          ),
        FilledButton.icon(
          onPressed:
              _busy ||
                  _input == null ||
                  !_selected.any((peer) => !_sessions.containsKey(peer))
              ? null
              : () => _run(_startSelected),
          icon: const Icon(Icons.speaker),
          label: const Text('Play on selected devices'),
        ),
        if (_sessions.isNotEmpty)
          const Text(
            'Keep this panel open or minimize Narad while listening. Add more devices without stopping current listeners. Each receiver controls its own audio permission. Leaving this panel stops all of its streams.',
          ),
        OutlinedButton.icon(
          onPressed: _busy ? null : () => _run(_stop),
          icon: const Icon(Icons.stop),
          label: const Text('Stop all sharing'),
        ),
      ],
    ),
  );
}
