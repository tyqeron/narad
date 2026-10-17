import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'audio.dart';
import 'camera_card.dart';
import 'desktop_audio_routes.dart';

/// Explicit setup for the laptop's OS endpoints and an authorized remote device.
class MeetingPage extends StatefulWidget {
  const MeetingPage({
    super.key,
    required this.audio,
    required this.peer,
    required this.name,
  });
  final AudioController audio;
  final String peer;
  final String name;
  @override
  State<MeetingPage> createState() => _MeetingPageState();
}

class _MeetingPageState extends State<MeetingPage> {
  final Set<String> _owned = {};
  LinuxAudioRoutes? _routes;
  List<MediaDeviceInfo> _inputs = [], _outputs = [];
  String? _capture, _microphoneOutput, _localOutput;
  String? _camera, _microphone, _speaker;
  bool _busy = false;
  bool _closing = false;
  bool _routedOutput = false;
  String? _error;
  Timer? _timer;
  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    unawaited(_run(_refreshDevices));
  }

  Future<void> _refreshDevices() async {
    final all = await navigator.mediaDevices.enumerateDevices();
    _inputs = all.where((d) => d.kind == 'audioinput').toList();
    _outputs = all.where((d) => d.kind == 'audiooutput').toList();
    _localOutput ??=
        widget.audio.playbackDeviceId ??
        (_outputs.isEmpty ? null : _outputs.first.deviceId);
    if (_routes != null) {
      String? find(List<MediaDeviceInfo> list, String label, String node) {
        for (final d in list) {
          if (d.label.contains(label) || d.deviceId == node) return d.deviceId;
        }
        return null;
      }

      _capture = find(_inputs, _routes!.captureLabel, _routes!.speakerCapture);
      _microphoneOutput = find(
        _outputs,
        _routes!.micFeedLabel,
        _routes!.microphoneSink,
      );
    }
    if (mounted) setState(() {});
  }

  Future<void> _run(Future<void> Function() work) async {
    if (_busy || _closing) return;
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

  Future<void> _createRoutes() async {
    final route = LinuxAudioRoutes();
    await route.createMeetingDevices();
    _routes = route;
    await _refreshDevices();
    // Native device enumeration may take a moment to observe new PipeWire nodes.
    if (_capture == null || _microphoneOutput == null) {
      await Future<void>.delayed(const Duration(milliseconds: 700));
      await _refreshDevices();
    }
    if (_capture == null || _microphoneOutput == null) {
      throw StateError(
        'Devices were created. Refresh the device list; if they are still missing, restart Narad after stopping this setup.',
      );
    }
  }

  Future<void> _stopId(String? id) async {
    if (id == null) return;
    await widget.audio.stop(id);
    _owned.remove(id);
  }

  Future<void> _stop() async {
    Object? failure;
    for (final id in _owned.toList()) {
      try {
        await _stopId(id);
      } catch (e) {
        failure ??= e;
      }
    }
    _camera = null;
    _microphone = null;
    _speaker = null;
    if (_routedOutput && _localOutput != null) {
      try {
        await widget.audio.selectPlaybackDevice(_localOutput!);
      } catch (e) {
        failure ??= e;
      }
    }
    _routedOutput = false;
    try {
      await _routes?.dispose();
      _routes = null;
    } catch (e) {
      failure ??= e;
    }
    if (mounted && !_closing) setState(() {});
    if (failure != null) {
      throw StateError('Could not stop every meeting device: $failure');
    }
  }

  @override
  void dispose() {
    _closing = true;
    _timer?.cancel();
    unawaited(_stop().catchError((Object _) {}));
    super.dispose();
  }

  Widget _deviceChoice(
    String title,
    List<MediaDeviceInfo> devices,
    String? value,
    void Function(String?) change,
  ) => DropdownButtonFormField<String>(
    initialValue: devices.any((d) => d.deviceId == value) ? value : null,
    key: ValueKey('$title-$value-${devices.length}'),
    isExpanded: true,
    decoration: InputDecoration(
      labelText: title,
      border: const OutlineInputBorder(),
    ),
    items: devices
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
    onChanged: _busy || _owned.isNotEmpty
        ? null
        : (v) => setState(() => change(v)),
  );
  @override
  Widget build(BuildContext context) {
    final camera = widget.audio.links[_camera];
    return Scaffold(
      appBar: AppBar(title: Text('Meeting devices · ${widget.name}')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text(
            'Use this device for Google Meet or other laptop calls. Allow camera and microphone sharing on the phone, and allow it to play your laptop audio. Keep this panel open and minimize Narad during the call. Leaving this panel stops its sessions.',
          ),
          const SizedBox(height: 16),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          if (Platform.isLinux) ...[
            FilledButton.icon(
              onPressed: _busy || _routes != null
                  ? null
                  : () => _run(_createRoutes),
              icon: const Icon(Icons.settings_voice),
              label: const Text('Create meeting audio devices'),
            ),
            if (_routes != null)
              SelectableText(
                'In Meet select:\nMicrophone: ${_routes!.micLabel}\nSpeaker: ${_routes!.speakerLabel}',
              ),
          ] else
            const Text(
              'Windows needs TWO independent installed virtual audio cables (for example A and B). Meet speaker → cable A playback; Narad captures cable A recording. Narad plays phone microphone into cable B playback; Meet microphone → cable B recording. Do not use the same cable for both directions.',
            ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _busy ? null : () => _run(_refreshDevices),
            icon: const Icon(Icons.refresh),
            label: const Text('Refresh audio devices'),
          ),
          _deviceChoice(
            'Capture laptop / meeting speaker audio',
            _inputs,
            _capture,
            (v) => _capture = v,
          ),
          const SizedBox(height: 12),
          _deviceChoice(
            'Play phone microphone into virtual cable',
            _outputs,
            _microphoneOutput,
            (v) => _microphoneOutput = v,
          ),
          const SizedBox(height: 12),
          _deviceChoice(
            'Local playback to restore afterwards',
            _outputs,
            _localOutput,
            (v) => _localOutput = v,
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed:
                _busy ||
                    _capture == null ||
                    widget.audio.links.containsKey(_speaker)
                ? null
                : () => _run(() async {
                    _speaker = await widget.audio.start(
                      widget.peer,
                      inputDeviceId: _capture,
                      systemAudio: true,
                    );
                    _owned.add(_speaker!);
                  }),
            icon: const Icon(Icons.speaker),
            label: const Text('Use phone as meeting speaker'),
          ),
          FilledButton.icon(
            onPressed:
                _busy ||
                    _microphoneOutput == null ||
                    _localOutput == null ||
                    _microphoneOutput == _localOutput ||
                    widget.audio.links.containsKey(_microphone)
                ? null
                : () => _run(() async {
                    // The native audio backend has one playout route for all Narad audio.
                    if (widget.audio.links.values.any(
                      (l) => !l.camera && !_owned.contains(l.id),
                    )) {
                      throw StateError(
                        'Stop other Narad audio sessions before routing a meeting microphone.',
                      );
                    }
                    await widget.audio.selectPlaybackDevice(_microphoneOutput!);
                    _routedOutput = true;
                    try {
                      _microphone = await widget.audio.requestMicrophone(
                        widget.peer,
                      );
                      _owned.add(_microphone!);
                    } catch (_) {
                      await widget.audio.selectPlaybackDevice(_localOutput!);
                      rethrow;
                    }
                  }),
            icon: const Icon(Icons.mic),
            label: const Text('Use phone microphone in meeting'),
          ),
          const Text(
            'All incoming Narad audio uses the selected playback device. Use headphones or lower the phone speaker volume if you hear feedback.',
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _busy || widget.audio.links.containsKey(_camera)
                ? null
                : () => _run(() async {
                    _camera = await widget.audio.startCamera(widget.peer);
                    _owned.add(_camera!);
                  }),
            icon: const Icon(Icons.videocam),
            label: const Text('Use phone camera'),
          ),
          const Text(
            'Camera in Meet: select OBS Virtual Camera. Below, choose Use in call apps and add the copied URL as an OBS Browser source, then start its virtual camera. OBS/its virtual-camera driver must be installed separately.',
          ),
          if (camera != null)
            CameraCard(
              controller: widget.audio,
              link: camera,
              name: widget.name,
            ),
          for (final id in [_microphone, _speaker])
            if (id != null && widget.audio.links[id] != null)
              ListTile(
                leading: Icon(id == _microphone ? Icons.mic : Icons.speaker),
                title: Text(
                  id == _microphone ? 'Phone microphone' : 'Phone speaker',
                ),
                subtitle: Text(
                  widget.audio.links[id]!.connection == null
                      ? 'Waiting for permission / connection'
                      : '${widget.audio.links[id]!.connection!.connectionState}',
                ),
              ),
          OutlinedButton.icon(
            onPressed: _busy ? null : () => _run(_stop),
            icon: const Icon(Icons.stop),
            label: const Text('Stop meeting setup'),
          ),
        ],
      ),
    );
  }
}
