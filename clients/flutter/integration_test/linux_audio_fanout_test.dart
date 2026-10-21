import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:integration_test/integration_test.dart';
import 'package:narad_client/audio.dart';
import 'package:narad_client/desktop_audio_routes.dart';
import 'package:narad_client/shared_capture.dart';

class _Pair {
  _Pair(this.send, this.receive, this.renderer);
  final RTCPeerConnection send, receive;
  final RTCVideoRenderer renderer;
  Future<void> close() async {
    await send.close();
    await send.dispose();
    await receive.close();
    await receive.dispose();
    await renderer.dispose();
  }
}

Future<_Pair> _connect(MediaStream stream) async {
  final send = await createPeerConnection({
    'iceServers': [],
    'sdpSemantics': 'unified-plan',
  });
  final receive = await createPeerConnection({
    'iceServers': [],
    'sdpSemantics': 'unified-plan',
  });
  final renderer = RTCVideoRenderer();
  await renderer.initialize();
  final pair = _Pair(send, receive, renderer);
  final toSender = <RTCIceCandidate>[], toReceiver = <RTCIceCandidate>[];
  var senderReady = false, receiverReady = false;
  send.onIceCandidate = (c) {
    if (c.candidate?.isNotEmpty != true) return;
    if (receiverReady) {
      unawaited(receive.addCandidate(c));
    } else {
      toReceiver.add(c);
    }
  };
  receive.onIceCandidate = (c) {
    if (c.candidate?.isNotEmpty != true) return;
    if (senderReady) {
      unawaited(send.addCandidate(c));
    } else {
      toSender.add(c);
    }
  };
  receive.onTrack = (e) {
    if (e.streams.isNotEmpty) renderer.srcObject = e.streams.first;
  };
  try {
    for (final track in stream.getAudioTracks()) {
      await send.addTrack(track, stream);
    }
    for (final transceiver in await send.getTransceivers()) {
      await transceiver.setDirection(TransceiverDirection.SendOnly);
    }
    final offer = await send.createOffer({
      'offerToReceiveAudio': false,
      'offerToReceiveVideo': false,
    });
    await send.setLocalDescription(offer);
    await receive.setRemoteDescription(offer);
    receiverReady = true;
    for (final c in toReceiver) {
      await receive.addCandidate(c);
    }
    final answer = await receive.createAnswer();
    await receive.setLocalDescription(answer);
    await send.setRemoteDescription(answer);
    senderReady = true;
    for (final c in toSender) {
      await send.addCandidate(c);
    }
    return pair;
  } catch (_) {
    await pair.close();
    rethrow;
  }
}

Future<num> _receivedBytes(_Pair pair) async => (await pair.receive.getStats())
    .where((s) => s.type == 'inbound-rtp')
    .fold<num>(
      0,
      (n, s) => n + (num.tryParse('${s.values['bytesReceived']}') ?? 0),
    );

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'one capture feeds two native receivers and survives stopping one',
    (tester) async {
      final route = LinuxAudioRoutes();
      final directory = await Directory.systemTemp.createTemp('narad-fanout-');
      final pairs = <_Pair>[];
      final leases = <CaptureLease<MediaStream>>[];
      Process? tone, recorder;
      var captures = 0, releases = 0;
      final pool = SharedCapturePool<MediaStream>(
        (id) {
          captures++;
          return navigator.mediaDevices.getUserMedia({
            'audio': audioCaptureConstraints(
              inputDeviceId: id,
              systemAudio: true,
            ),
            'video': false,
          });
        },
        (stream) async {
          releases++;
          for (final track in stream.getTracks()) {
            await track.stop();
          }
          await stream.dispose();
        },
      );
      try {
        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(body: Text('Two-receiver generated audio test')),
          ),
        );
        await route.createMeetingDevices();
        await Future<void>.delayed(const Duration(seconds: 1));
        final devices = await navigator.mediaDevices.enumerateDevices();
        final input = devices.firstWhere(
          (d) =>
              d.kind == 'audioinput' &&
              (d.deviceId == route.speakerCapture ||
                  d.label.contains(route.captureLabel)),
        );
        final output = devices.firstWhere(
          (d) =>
              d.kind == 'audiooutput' &&
              (d.deviceId == route.microphoneSink ||
                  d.label.contains(route.micFeedLabel)),
        );
        // Explicit owned source only: no hardware microphone or system-output capture.
        final first = pool.acquire(input.deviceId),
            second = pool.acquire(input.deviceId);
        leases.addAll([first, second]);
        expect(await first.value, same(await second.value));
        expect(captures, 1);
        pairs.add(await _connect(await first.value));
        pairs.add(await _connect(await second.value));
        await Helper.selectAudioOutput(output.deviceId);
        final samples = 48000 * 15;
        final pcm = ByteData(samples * 4);
        for (var i = 0; i < samples; i++) {
          final value = (sin(2 * pi * 440 * i / 48000) * 4000).round();
          pcm.setInt16(i * 4, value, Endian.little);
          pcm.setInt16(i * 4 + 2, value, Endian.little);
        }
        final file = File('${directory.path}/tone.pcm');
        await file.writeAsBytes(pcm.buffer.asUint8List());
        recorder = await Process.start('parecord', [
          '--raw',
          '--format=s16le',
          '--rate=48000',
          '--channels=2',
          '--device=${route.microphoneSource}',
          '${directory.path}/received.pcm',
        ]);
        unawaited(recorder.stdout.drain<void>());
        unawaited(recorder.stderr.drain<void>());
        tone = await Process.start('paplay', [
          '--raw',
          '--format=s16le',
          '--rate=48000',
          '--channels=2',
          '--device=${route.speakerSink}',
          file.path,
        ]);
        unawaited(tone.stdout.drain<void>());
        unawaited(tone.stderr.drain<void>());
        final deadline = DateTime.now().add(const Duration(seconds: 10));
        while ((await _receivedBytes(pairs[0]) < 1000 ||
                await _receivedBytes(pairs[1]) < 1000) &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
        expect(await _receivedBytes(pairs[0]), greaterThan(1000));
        expect(await _receivedBytes(pairs[1]), greaterThan(1000));
        await first.release();
        await pairs.removeAt(0).close();
        expect(releases, 0);
        final before = await _receivedBytes(pairs.single);
        // Record only the remaining listener's decoded virtual output.
        await Future<void>.delayed(const Duration(seconds: 3));
        expect(await _receivedBytes(pairs.single), greaterThan(before + 1000));
        recorder.kill(ProcessSignal.sigint);
        await recorder.exitCode;
        final received = ByteData.sublistView(
          await File('${directory.path}/received.pcm').readAsBytes(),
        );
        var peak = 0;
        // Last second is after the first listener stopped.
        for (
          var i = max(0, received.lengthInBytes - 48000 * 4);
          i + 1 < received.lengthInBytes;
          i += 2
        ) {
          peak = max(peak, received.getInt16(i, Endian.little).abs());
        }
        expect(
          peak,
          greaterThan(500),
          reason:
              'Remaining listener must decode the tone after the other stops',
        );
        await second.release();
        expect(releases, 1);
      } finally {
        tone?.kill();
        recorder?.kill();
        for (final pair in pairs) {
          await pair.close();
        }
        for (final lease in leases) {
          await lease.release();
        }
        // The output selection belongs to this isolated test process.
        await route.dispose();
        await directory.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
