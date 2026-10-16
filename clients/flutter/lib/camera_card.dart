import 'dart:async';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'audio.dart';
import 'camera_tools.dart';

Future<void> saveCameraRecording(CameraTools tools, String path) async {
  final saved = await FilePicker.saveFile(
    fileName: 'Narad-${path.split(Platform.pathSeparator).last}',
    mimeType: 'video/mp4',
    bytes: await File(path).readAsBytes(),
    dialogTitle: 'Save camera recording',
  );
  if (saved != null) await tools.discard(path);
}

class CameraCard extends StatefulWidget {
  const CameraCard({
    super.key,
    required this.controller,
    required this.link,
    required this.name,
  });
  final AudioController controller;
  final AudioLink link;
  final String name;
  @override
  State<CameraCard> createState() => _CameraCardState();
}

class _CameraCardState extends State<CameraCard> {
  bool _busy = false;
  Timer? _timer;
  CameraTools get tools => widget.controller.cameraTools(widget.link);
  @override
  void initState() {
    super.initState();
    if (!widget.link.outgoing) return;
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final link = widget.link;
    if (!link.outgoing) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.videocam_outlined),
                title: Text('Sharing camera with ${widget.name}'),
                subtitle: const Text(
                  'Video is shown only on the requesting device.',
                ),
              ),
              TextButton.icon(
                onPressed: _busy
                    ? null
                    : () => _run(() => widget.controller.stop(link.id)),
                icon: const Icon(Icons.stop_circle_outlined),
                label: const Text('Stop sharing camera'),
              ),
            ],
          ),
        ),
      );
    }
    final ready = link.renderer != null && link.renderer!.videoWidth > 0;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${link.outgoing ? 'Camera from' : 'Sharing camera with'} ${widget.name}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (link.renderer != null)
              SizedBox(
                height: 300,
                child: RTCVideoView(
                  link.renderer!,
                  objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
                ),
              )
            else
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('Waiting for camera video…'),
              ),
            if (tools.recording)
              Text(
                '● Recording video · ${DateTime.now().difference(tools.recordingStarted!).inSeconds}s',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: _busy || !ready
                      ? null
                      : () =>
                            _run(() => widget.controller.switchCamera(link.id)),
                  icon: const Icon(Icons.cameraswitch_outlined),
                  label: const Text('Switch camera'),
                ),
                OutlinedButton.icon(
                  onPressed: _busy || !ready
                      ? null
                      : () => _run(() async {
                          await FilePicker.saveFile(
                            fileName:
                                'Narad-photo-${DateTime.now().millisecondsSinceEpoch}.png',
                            mimeType: 'image/png',
                            bytes: await tools.photo(),
                            dialogTitle: 'Save camera image',
                          );
                        }),
                  icon: const Icon(Icons.photo_camera_outlined),
                  label: const Text('Save image'),
                ),
                FilledButton.icon(
                  onPressed: _busy || !ready
                      ? null
                      : () => _run(() async {
                          if (tools.recording) {
                            await tools.stopRecording();
                          } else {
                            await tools.startRecording();
                          }
                        }),
                  icon: Icon(
                    tools.recording ? Icons.stop : Icons.fiber_manual_record,
                  ),
                  label: Text(
                    tools.recording ? 'Stop recording' : 'Record video',
                  ),
                ),
                if (Platform.isLinux || Platform.isWindows)
                  OutlinedButton.icon(
                    onPressed: _busy || !ready
                        ? null
                        : () => _run(() async {
                            if (tools.feed.url == null) {
                              await tools.startFeed();
                            } else {
                              await tools.stopFeed();
                            }
                          }),
                    icon: const Icon(Icons.video_camera_front_outlined),
                    label: Text(
                      tools.feed.url == null
                          ? 'Use in call apps'
                          : 'Stop webcam feed',
                    ),
                  ),
                TextButton.icon(
                  onPressed: _busy
                      ? null
                      : () => _run(() => widget.controller.stop(link.id)),
                  icon: const Icon(Icons.close),
                  label: const Text('Disconnect camera'),
                ),
              ],
            ),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'Video only, without microphone audio. Recordings stop at 10 minutes / 128 MB. Save or discard below before closing Narad. Desktop recording requires FFmpeg and captures up to 8 fps.',
              ),
            ),
            if (tools.feed.url != null) ...[
              const Text(
                'In OBS: add a Browser source using this local URL (1280 × 720), then Start Virtual Camera. Select OBS Virtual Camera in your call app. Keep Narad and OBS open. Feed is a video-only preview up to 8 fps; OBS is required.',
              ),
              SelectableText(tools.feed.url!),
              TextButton.icon(
                onPressed: () =>
                    Clipboard.setData(ClipboardData(text: tools.feed.url!)),
                icon: const Icon(Icons.copy),
                label: const Text('Copy local camera URL'),
              ),
            ],
            for (final path in tools.completed.toList())
              Wrap(
                spacing: 8,
                children: [
                  TextButton.icon(
                    onPressed: _busy
                        ? null
                        : () => _run(() => saveCameraRecording(tools, path)),
                    icon: const Icon(Icons.save_alt),
                    label: const Text('Save recorded video'),
                  ),
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => _run(() => tools.discard(path)),
                    child: const Text('Discard recording'),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
