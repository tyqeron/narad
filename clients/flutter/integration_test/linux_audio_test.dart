import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:narad_client/audio.dart';
import 'package:narad_client/desktop_audio_routes.dart';
import 'package:narad_client/camera_tools.dart';

/// Uses only generated tones and owned virtual devices, never a hardware microphone.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Linux virtual speaker and microphone carry WebRTC audio', (
    tester,
  ) async {
    final routes = LinuxAudioRoutes();
    final sender = await createPeerConnection({
      'iceServers': [],
      'sdpSemantics': 'unified-plan',
    });
    final receiver = await createPeerConnection({
      'iceServers': [],
      'sdpSemantics': 'unified-plan',
    });
    final renderer = RTCVideoRenderer();
    MediaStream? stream;
    MediaStreamTrack? remoteAudio;
    CameraTools? cameraTools;
    final recordingErrors = <Object>[];
    Process? tone, recorder;
    final directory = await Directory.systemTemp.createTemp(
      'narad-audio-test-',
    );
    final queuedSender = <RTCIceCandidate>[],
        queuedReceiver = <RTCIceCandidate>[];
    bool senderReady = false, receiverReady = false;
    sender.onIceCandidate = (c) {
      if (c.candidate?.isNotEmpty != true) return;
      if (receiverReady) {
        unawaited(receiver.addCandidate(c));
      } else {
        queuedReceiver.add(c);
      }
    };
    receiver.onIceCandidate = (c) {
      if (c.candidate?.isNotEmpty != true) return;
      if (senderReady) {
        unawaited(sender.addCandidate(c));
      } else {
        queuedSender.add(c);
      }
    };
    try {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Text('Testing Narad virtual audio with a generated tone'),
          ),
        ),
      );
      await routes.createMeetingDevices();
      await Future<void>.delayed(const Duration(seconds: 1));
      final devices = await navigator.mediaDevices.enumerateDevices();
      final inputs = devices.where((d) => d.kind == 'audioinput').toList();
      final outputs = devices.where((d) => d.kind == 'audiooutput').toList();
      // Fail before getUserMedia if the owned endpoint is absent. Never default to a microphone.
      final input = inputs.firstWhere(
        (d) =>
            d.deviceId == routes.speakerCapture ||
            d.label.contains(routes.captureLabel),
      );
      final output = outputs.firstWhere(
        (d) =>
            d.deviceId == routes.microphoneSink ||
            d.label.contains(routes.micFeedLabel),
      );
      await renderer.initialize();
      receiver.onTrack = (event) {
        if (event.track.kind == 'audio') remoteAudio = event.track;
        if (event.streams.isNotEmpty) renderer.srcObject = event.streams.first;
      };
      stream = await navigator.mediaDevices.getUserMedia({
        'audio': audioCaptureConstraints(
          inputDeviceId: input.deviceId,
          systemAudio: true,
        ),
        'video': false,
      });
      await Helper.selectAudioOutput(output.deviceId);
      expect(stream.getAudioTracks(), hasLength(1));
      expect(stream.getVideoTracks(), isEmpty);
      for (final track in stream.getAudioTracks()) {
        await sender.addTrack(track, stream);
      }
      for (final transceiver in await sender.getTransceivers()) {
        await transceiver.setDirection(TransceiverDirection.SendOnly);
      }
      final offer = await sender.createOffer({
        'offerToReceiveAudio': false,
        'offerToReceiveVideo': false,
      });
      validateMediaSdp(offer.sdp!, video: false, direction: 'sendonly');
      await sender.setLocalDescription(offer);
      await receiver.setRemoteDescription(offer);
      receiverReady = true;
      for (final c in queuedReceiver) {
        await receiver.addCandidate(c);
      }
      final answer = await receiver.createAnswer();
      validateMediaSdp(answer.sdp!, video: false, direction: 'recvonly');
      await receiver.setLocalDescription(answer);
      await sender.setRemoteDescription(answer);
      senderReady = true;
      for (final c in queuedSender) {
        await sender.addCandidate(c);
      }
      final trackDeadline = DateTime.now().add(const Duration(seconds: 10));
      while (remoteAudio == null && DateTime.now().isBefore(trackDeadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(remoteAudio, isNotNull);
      final png = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAIAAACQkWg2AAAAGUlEQVR4nGOUq9jCQApgIkn1qIZRDUNKAwAjwgFqf9sx/AAAAABJRU5ErkJggg==',
      );
      cameraTools = CameraTools(
        () => throw StateError('Generated fixture must not access a camera'),
        recordingErrors.add,
        capture: () async => png,
        audioTrack: () => remoteAudio!,
      );
      await cameraTools.startRecording();
      // Record only the owned virtual microphone endpoint for objective PCM verification.
      recorder = await Process.start('parecord', [
        '--raw',
        '--format=s16le',
        '--rate=48000',
        '--channels=2',
        '--device=${routes.microphoneSource}',
        '${directory.path}/received.pcm',
      ]);
      unawaited(recorder.stdout.drain<void>());
      unawaited(recorder.stderr.drain<void>());
      final samples = 48000 * 6;
      final pcm = ByteData(samples * 4);
      for (var i = 0; i < samples; i++) {
        final sample = (sin(2 * pi * 440 * i / 48000) * 8000).round();
        pcm.setInt16(i * 4, sample, Endian.little);
        pcm.setInt16(i * 4 + 2, sample, Endian.little);
      }
      final wav = File('${directory.path}/tone.pcm');
      await wav.writeAsBytes(pcm.buffer.asUint8List());
      tone = await Process.start('paplay', [
        '--raw',
        '--format=s16le',
        '--rate=48000',
        '--channels=2',
        '--device=${routes.speakerSink}',
        wav.path,
      ]);
      unawaited(tone.stdout.drain<void>());
      unawaited(tone.stderr.drain<void>());
      expect(await tone.exitCode.timeout(const Duration(seconds: 15)), 0);
      await Future<void>.delayed(const Duration(seconds: 1));
      final recording = await cameraTools.stopRecording();
      expect(recordingErrors, isEmpty);
      expect(recording, isNotNull);
      final probe = await Process.run('ffprobe', [
        '-v',
        'error',
        '-show_streams',
        '-of',
        'json',
        recording!,
      ]);
      expect(probe.exitCode, 0);
      final tracks = jsonDecode(probe.stdout as String)['streams'] as List;
      expect(tracks.where((s) => s['codec_type'] == 'video'), hasLength(1));
      expect(tracks.where((s) => s['codec_type'] == 'audio'), hasLength(1));
      final decode = await Process.run('ffmpeg', [
        '-v',
        'error',
        '-i',
        recording,
        '-f',
        'null',
        '-',
      ]);
      expect(decode.exitCode, 0);
      final audioDecode = await Process.run('ffmpeg', [
        '-v',
        'error',
        '-i',
        recording,
        '-vn',
        '-f',
        's16le',
        '-',
      ], stdoutEncoding: null);
      expect(audioDecode.exitCode, 0);
      final recordedPcm = Uint8List.fromList(audioDecode.stdout as List<int>);
      final recordedData = ByteData.sublistView(recordedPcm);
      var recordedPeak = 0;
      for (var i = 0; i + 1 < recordedPcm.length; i += 2) {
        recordedPeak = max(
          recordedPeak,
          recordedData.getInt16(i, Endian.little).abs(),
        );
      }
      expect(
        recordedPeak,
        greaterThan(1000),
        reason: 'MP4 must contain the generated remote tone',
      );
      final stats = await receiver.getStats();
      final inbound = stats.where((s) => s.type == 'inbound-rtp').toList();
      expect(inbound, isNotEmpty);
      expect(
        inbound.any(
          (s) => (num.tryParse('${s.values['bytesReceived']}') ?? 0) > 1000,
        ),
        true,
      );
      recorder.kill(ProcessSignal.sigint);
      await recorder.exitCode;
      final received = await File(
        '${directory.path}/received.pcm',
      ).readAsBytes();
      final data = ByteData.sublistView(received);
      var peak = 0;
      for (var i = 0; i + 1 < received.length; i += 2) {
        peak = max(peak, data.getInt16(i, Endian.little).abs());
      }
      expect(
        peak,
        greaterThan(1000),
        reason:
            'Virtual microphone must receive the generated tone, not just silent RTP packets',
      );
    } finally {
      await cameraTools?.dispose();
      tone?.kill();
      recorder?.kill();
      for (final track in stream?.getTracks() ?? <MediaStreamTrack>[]) {
        await track.stop();
      }
      await stream?.dispose();
      await sender.close();
      await receiver.close();
      await sender.dispose();
      await receiver.dispose();
      await renderer.dispose();
      await routes.dispose();
      await directory.delete(recursive: true);
    }
  });
}
