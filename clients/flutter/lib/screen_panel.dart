import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'api.dart';
import 'screen_share.dart';
import 'screen_extension.dart';

Future<void> shareScreenWith(
  BuildContext context,
  ScreenController controller,
  String peer,
  String name,
) async {
  final extension = ScreenExtension();
  try {
    final canExtend = await extension.supported();
    if (!context.mounted) return;
    final mode = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text('Use $name as a display'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 'mirror'),
            child: const ListTile(
              leading: Icon(Icons.screen_share_outlined),
              title: Text('Mirror a screen'),
              subtitle: Text(
                'Choose the screen or app to show on the other device.',
              ),
            ),
          ),
          if (canExtend)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, 'extend'),
              child: const ListTile(
                leading: Icon(Icons.add_to_queue),
                title: Text('Extend desktop'),
                subtitle: Text(
                  'Create a virtual monitor, then select it in the screen picker.',
                ),
              ),
            ),
          if (!canExtend)
            const Padding(
              padding: EdgeInsets.all(20),
              child: Text(
                'Creating a secondary desktop requires OS virtual-display support. You can mirror this device, or select an existing secondary monitor on a desktop.',
              ),
            ),
        ],
      ),
    );
    if (mode == null || !context.mounted) return;
    if (mode == 'extend') {
      await extension.start();
      if (!context.mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Select the new virtual monitor'),
          content: const Text(
            'A real secondary monitor has been created. In the next screen picker choose that new virtual monitor, not your main screen. Move windows onto it using your desktop display settings.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Continue'),
            ),
          ],
        ),
      );
    }
    String? sourceId;
    if (Platform.isWindows ||
        (Platform.isLinux &&
            Platform.environment['XDG_SESSION_TYPE'] != 'wayland')) {
      final sources = await desktopCapturer.getSources(
        types: [SourceType.Screen, SourceType.Window],
      );
      if (!context.mounted) return;
      sourceId = await showDialog<String>(
        context: context,
        builder: (context) => SimpleDialog(
          title: const Text('Choose a screen or window'),
          children: [
            for (final source in sources)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(context, source.id),
                child: ListTile(
                  leading: Icon(
                    source.type == SourceType.Screen
                        ? Icons.monitor
                        : Icons.web_asset,
                  ),
                  title: Text(source.name),
                ),
              ),
          ],
        ),
      );
      if (sourceId == null) return;
    }
    final id = await controller.send(
      peer,
      sourceId: sourceId,
      extended: mode == 'extend',
      releaseDisplay: mode == 'extend' ? extension.dispose : null,
    );
    if (mode == 'extend') {
      extension.onStopped = () => controller.stop(id);
      // The controller now owns the helper until this session ends.
      return;
    }
  } finally {
    if (!controller.links.values.any(
      (link) => link.releaseDisplay == extension.dispose,
    )) {
      // Bound tear-offs compare by receiver/method; active extensions stay alive.
      await extension.dispose();
    }
  }
}

class ScreenPanel extends StatelessWidget {
  const ScreenPanel({
    super.key,
    required this.controller,
    required this.api,
    required this.status,
    required this.onError,
  });
  final ScreenController controller;
  final NaradApi api;
  final Map<String, dynamic> status;
  final void Function(Object) onError;
  String name(String id) =>
      (status['paired'] as Map?)?[id]?['peer']?['device_name'] as String? ??
      'Device';
  Future<void> run(Future<void> Function() work) async {
    try {
      await work();
    } catch (error) {
      onError(error);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Screens', style: Theme.of(context).textTheme.titleLarge),
        SwitchListTile(
          title: const Text('Receive shared screens'),
          subtitle: const Text(
            'Requests require approval unless this device has permission to show screens automatically.',
          ),
          value: controller.enabled,
          onChanged: (value) => run(() => controller.setEnabled(value)),
        ),
        for (final session
            in (status['sessions'] as List? ?? const []).cast<Map>().where(
              (s) =>
                  s['capability'] == 'screen.view' &&
                  s['state'] == 'requested' &&
                  !(controller.links[s['id']]?.outgoing ?? false),
            ))
          Card(
            child: ListTile(
              leading: const Icon(Icons.cast_connected),
              title: Text('Screen from ${name(session['peer_id'] as String)}'),
              subtitle: const Text('Show this device’s shared screen here?'),
              trailing: Wrap(
                children: [
                  TextButton(
                    onPressed: () => run(() async {
                      await api.call({'op': 'media_deny', 'id': session['id']});
                    }),
                    child: const Text('Decline'),
                  ),
                  FilledButton(
                    onPressed: () => run(() async {
                      await api.call({
                        'op': 'media_accept',
                        'id': session['id'],
                      });
                    }),
                    child: const Text('Accept'),
                  ),
                ],
              ),
            ),
          ),
        for (final peer in ((status['paired'] as Map?) ?? {}).entries)
          if ((status['presence'] as Map?)?[peer.key]?['online'] == true)
            ListTile(
              leading: const Icon(Icons.connected_tv),
              title: Text('Use ${name(peer.key as String)} as a display'),
              subtitle: const Text(
                'Mirror a screen or extend a supported desktop',
              ),
              onTap: () => run(
                () => shareScreenWith(
                  context,
                  controller,
                  peer.key as String,
                  name(peer.key as String),
                ),
              ),
            ),
        for (final link in controller.links.values.toList())
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                children: [
                  ListTile(
                    leading: Icon(
                      link.outgoing ? Icons.screen_share : Icons.cast_connected,
                    ),
                    title: Text(
                      '${link.outgoing ? 'Sharing with' : 'Screen from'} ${name(link.peer)}',
                    ),
                    subtitle: Text(
                      link.extended
                          ? 'Extended desktop'
                          : !link.connected
                          ? 'Waiting for approval or connection…'
                          : 'Screen mirror',
                    ),
                    trailing: TextButton(
                      onPressed: () => run(() => controller.stop(link.id)),
                      child: const Text('Stop'),
                    ),
                  ),
                  if (!link.outgoing && link.renderer != null) ...[
                    ValueListenableBuilder<RTCVideoValue>(
                      valueListenable: link.renderer!,
                      builder: (context, value, _) => Text(
                        value.width > 0
                            ? '${value.width} × ${value.height}'
                            : 'Waiting for the first screen frame…',
                      ),
                    ),
                    SizedBox(
                      height: 220,
                      child: RTCVideoView(
                        link.renderer!,
                        objectFit:
                            RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
                      ),
                    ),
                    TextButton.icon(
                      icon: const Icon(Icons.fullscreen),
                      label: const Text('Full screen'),
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => ScreenViewer(
                            controller: controller,
                            id: link.id,
                            name: name(link.peer),
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
      ],
    ),
  );
}

class ScreenViewer extends StatefulWidget {
  const ScreenViewer({
    super.key,
    required this.controller,
    required this.id,
    required this.name,
  });
  final ScreenController controller;
  final String id, name;
  @override
  State<ScreenViewer> createState() => _ScreenViewerState();
}

class _ScreenViewerState extends State<ScreenViewer> {
  @override
  void initState() {
    super.initState();
    if (Platform.isAndroid) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }
  }

  @override
  void dispose() {
    if (Platform.isAndroid) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    appBar: AppBar(
      title: Text(widget.name),
      actions: [
        TextButton(
          onPressed: () async {
            await widget.controller.stop(widget.id);
            if (context.mounted) Navigator.pop(context);
          },
          child: const Text('Stop'),
        ),
      ],
    ),
    body: ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final renderer = widget.controller.links[widget.id]?.renderer;
        return renderer == null
            ? const Center(
                child: Text(
                  'Screen session ended',
                  style: TextStyle(color: Colors.white),
                ),
              )
            : InteractiveViewer(
                maxScale: 4,
                child: Center(
                  child: RTCVideoView(
                    renderer,
                    objectFit:
                        RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
                  ),
                ),
              );
      },
    ),
  );
}
