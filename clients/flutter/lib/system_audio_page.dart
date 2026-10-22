import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'audio.dart';
import 'desktop_audio_routes.dart';
import 'system_audio_sharing.dart';

class SystemAudioPage extends StatefulWidget {
  const SystemAudioPage({
    super.key,
    required this.audio,
    required this.peer,
    required this.name,
    this.recipients = const {},
    this.routeFactory,
    this.enumerateDevices,
    this.createConnection = createPeerConnection,
  });
  final Future<RTCPeerConnection> Function(Map<String, dynamic>)
  createConnection;
  final AudioController audio;
  final String peer, name;
  final Map<String, String> recipients;
  final LinuxAudioRoutes Function()? routeFactory;
  final Future<List<MediaDeviceInfo>> Function()? enumerateDevices;
  @override
  State<SystemAudioPage> createState() => _SystemAudioPageState();
}

class _SystemAudioPageState extends State<SystemAudioPage> {
  late final SystemAudioSharing sharing;
  @override
  void initState() {
    super.initState();
    sharing = widget.audio.systemAudioSharing ??= SystemAudioSharing(
      widget.audio,
      routeFactory: widget.routeFactory,
      enumerateDevices: widget.enumerateDevices,
      createConnection: widget.createConnection,
    );
    sharing.attach(widget.peer, widget.name, widget.recipients);
    sharing.addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    sharing.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Share laptop audio')),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(
          defaultTargetPlatform == TargetPlatform.linux
              ? 'Send playback from your current default laptop speaker to selected devices. Local playback continues. Sharing continues when you go back or minimize Narad.'
              : 'Select an installed Stereo Mix or virtual cable recording device. For a cable, route your video application’s output to its matching playback device in Windows sound settings. Sharing continues when you go back or minimize Narad.',
        ),
        const SizedBox(height: 16),
        if (sharing.error != null)
          Text(
            sharing.error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        OutlinedButton.icon(
          onPressed: sharing.busy || sharing.sessions.isNotEmpty
              ? null
              : () => sharing.run(sharing.prepare),
          icon: const Icon(Icons.refresh),
          label: const Text('Prepare / refresh audio capture'),
        ),
        DropdownButtonFormField<String>(
          key: ValueKey('$sharing.input-${sharing.devices.length}'),
          initialValue: sharing.input,
          isExpanded: true,
          decoration: const InputDecoration(
            labelText: 'Laptop playback capture',
          ),
          items: sharing.devices
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
          onChanged:
              sharing.busy ||
                  sharing.sessions.isNotEmpty ||
                  defaultTargetPlatform == TargetPlatform.linux
              ? null
              : sharing.selectInput,
        ),
        const SizedBox(height: 16),
        Text(
          'Listening devices',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        for (final device in sharing.recipients.entries)
          CheckboxListTile(
            value: sharing.selected.contains(device.key),
            title: Text(device.value),
            subtitle: Text(
              sharing.sessions.containsKey(device.key)
                  ? 'Sharing requested · audio plays after receiver approval'
                  : 'Select to receive laptop audio',
            ),
            onChanged: sharing.busy
                ? null
                : (selected) => sharing.select(device.key, selected == true),
            secondary: sharing.sessions.containsKey(device.key)
                ? IconButton(
                    tooltip: 'Stop audio on ${device.value}',
                    icon: const Icon(Icons.stop_circle_outlined),
                    onPressed: sharing.busy
                        ? null
                        : () =>
                              sharing.run(() => sharing.stopDevice(device.key)),
                  )
                : null,
          ),
        FilledButton.icon(
          onPressed:
              sharing.busy ||
                  sharing.input == null ||
                  !sharing.selected.any(
                    (peer) => !sharing.sessions.containsKey(peer),
                  )
              ? null
              : () => sharing.run(sharing.startSelected),
          icon: const Icon(Icons.speaker),
          label: const Text('Play on selected devices'),
        ),
        if (sharing.sessions.isNotEmpty)
          const Text(
            'Sharing continues in the background. Return here to add listeners or stop sharing. Each receiver controls its own audio permission.',
          ),
        OutlinedButton.icon(
          onPressed: sharing.busy ? null : () => sharing.run(sharing.stop),
          icon: const Icon(Icons.stop),
          label: const Text('Stop all sharing'),
        ),
      ],
    ),
  );
}
