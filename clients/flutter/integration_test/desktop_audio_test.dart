import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:narad_client/api.dart';
import 'package:narad_client/audio.dart';
import 'package:narad_client/desktop_audio_routes.dart';

/// Opt-in physical fixture: generated sound to tablet, live mic return discarded.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Linux and Android carry meeting audio in both directions', (
    tester,
  ) async {
    final state = Platform.environment['NARAD_AUDIO_STATE'] ?? '';
    final port =
        int.tryParse(Platform.environment['NARAD_AUDIO_PORT'] ?? '') ?? 0;
    final peer = Platform.environment['NARAD_AUDIO_PEER'] ?? '';
    expect(
      state,
      isNotEmpty,
      reason: 'Run tests/android_e2e.py --desktop-audio',
    );
    final api = DaemonApi(state, port);
    final errors = <Object>[];
    final audio = AudioController(api, errors.add);
    final routes = LinuxAudioRoutes();
    final directory = await Directory.systemTemp.createTemp(
      'narad-meeting-tone-',
    );
    Process? tone;
    try {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Text('Narad Linux / tablet audio check')),
        ),
      );
      await routes.createMeetingDevices();
      await Future<void>.delayed(const Duration(seconds: 1));
      final devices = await navigator.mediaDevices.enumerateDevices();
      final input = devices.firstWhere(
        (d) =>
            d.kind == 'audioinput' &&
            (d.deviceId == routes.speakerCapture ||
                d.label.contains(routes.captureLabel)),
      );
      final output = devices.firstWhere(
        (d) =>
            d.kind == 'audiooutput' &&
            (d.deviceId == routes.microphoneSink ||
                d.label.contains(routes.micFeedLabel)),
      );
      await audio.selectPlaybackDevice(output.deviceId);
      final microphone = await audio.requestMicrophone(peer);
      final speaker = await audio.start(
        peer,
        inputDeviceId: input.deviceId,
        systemAudio: true,
      );
      Future<void> tick() async {
        await audio.tick(await api.call({'op': 'status'}));
        expect(errors, isEmpty);
      }

      final camera = Platform.environment['NARAD_AUDIO_CAMERA'] == '1'
          ? await audio.startCamera(peer)
          : null;
      final deadline = DateTime.now().add(const Duration(seconds: 45));
      while (DateTime.now().isBefore(deadline)) {
        await tick();
        if ([microphone, speaker, ?camera].every(
          (id) =>
              audio.links[id]?.connection?.connectionState ==
              RTCPeerConnectionState.RTCPeerConnectionStateConnected,
        )) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
      expect(audio.links[microphone]?.renderer, isNotNull);
      expect(
        audio.microphoneEnabled,
        false,
        reason: 'Linux must not capture its physical microphone',
      );
      final pcm = ByteData(48000 * 4 * 3);
      for (var i = 0; i < 48000 * 3; i++) {
        final sample = (sin(2 * pi * 440 * i / 48000) * 2000).round();
        pcm.setInt16(i * 4, sample, Endian.little);
        pcm.setInt16(i * 4 + 2, sample, Endian.little);
      }
      final file = File('${directory.path}/tone.pcm');
      await file.writeAsBytes(pcm.buffer.asUint8List());
      tone = await Process.start('paplay', [
        '--raw',
        '--format=s16le',
        '--rate=48000',
        '--channels=2',
        '--device=${routes.speakerSink}',
        file.path,
      ]);
      unawaited(tone.stdout.drain<void>());
      unawaited(tone.stderr.drain<void>());
      for (var i = 0; i < 20; i++) {
        await tick();
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      expect(await tone.exitCode, 0);
      final incoming = await audio.links[microphone]!.connection!.getStats();
      final outgoing = await audio.links[speaker]!.connection!.getStats();
      expect(
        incoming.any(
          (s) =>
              s.type == 'inbound-rtp' &&
              (num.tryParse('${s.values['bytesReceived']}') ?? 0) > 1000,
        ),
        true,
      );
      expect(
        outgoing.any(
          (s) =>
              s.type == 'outbound-rtp' &&
              (num.tryParse('${s.values['bytesSent']}') ?? 0) > 1000,
        ),
        true,
      );
      if (camera != null) {
        final link = audio.links[camera]!;
        expect(link.renderer, isNotNull);
        expect(link.renderer!.srcObject!.getVideoTracks(), hasLength(1));
        expect(link.renderer!.srcObject!.getAudioTracks(), isEmpty);
        final video = await link.connection!.getStats();
        expect(
          video.any(
            (s) =>
                s.type == 'inbound-rtp' &&
                (num.tryParse('${s.values['bytesReceived']}') ?? 0) > 1000,
          ),
          true,
        );
      }
      expect(errors, isEmpty);
    } finally {
      tone?.kill();
      await audio.dispose();
      await routes.dispose();
      await directory.delete(recursive: true);
    }
  });
}
