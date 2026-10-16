import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:narad_client/android_backend.dart';

/// Opt-in hardware test: video stays within this device and is never recorded.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('physical camera sends a frame to the native video renderer', (
    tester,
  ) async {
    expect(await AndroidBackend().ensureCameraPermission(), isTrue);
    final viewer = await createPeerConnection({
      'iceServers': [],
      'sdpSemantics': 'unified-plan',
    });
    final source = await createPeerConnection({
      'iceServers': [],
      'sdpSemantics': 'unified-plan',
    });
    final renderer = RTCVideoRenderer();
    MediaStream? camera;
    final frame = Completer<void>();
    final sized = Completer<void>();
    final pendingViewer = <RTCIceCandidate>[];
    final pendingSource = <RTCIceCandidate>[];
    var viewerReady = false;
    var sourceReady = false;
    viewer.onIceCandidate = (candidate) {
      if (candidate.candidate?.isNotEmpty != true) return;
      if (sourceReady) {
        unawaited(source.addCandidate(candidate));
      } else {
        pendingSource.add(candidate);
      }
    };
    source.onIceCandidate = (candidate) {
      if (candidate.candidate?.isNotEmpty != true) return;
      if (viewerReady) {
        unawaited(viewer.addCandidate(candidate));
      } else {
        pendingViewer.add(candidate);
      }
    };
    try {
      await renderer.initialize();
      renderer.onResize = () {
        if (renderer.videoWidth > 0 &&
            renderer.videoHeight > 0 &&
            !sized.isCompleted) {
          sized.complete();
        }
      };
      renderer.onFirstFrameRendered = () {
        if (!frame.isCompleted) frame.complete();
      };
      viewer.onTrack = (event) {
        if (event.streams.isNotEmpty) renderer.srcObject = event.streams.first;
      };
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: RTCVideoView(renderer))),
      );
      await viewer.addTransceiver(
        kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
        init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
      );
      final offer = await viewer.createOffer({
        'offerToReceiveAudio': false,
        'offerToReceiveVideo': true,
      });
      await viewer.setLocalDescription(offer);
      await source.setRemoteDescription(offer);
      sourceReady = true;
      for (final candidate in pendingSource) {
        await source.addCandidate(candidate);
      }
      camera = await navigator.mediaDevices.getUserMedia({
        'audio': false,
        'video': {'facingMode': 'environment'},
      });
      expect(camera.getAudioTracks(), isEmpty);
      expect(camera.getVideoTracks(), hasLength(1));
      for (final track in camera.getVideoTracks()) {
        await source.addTrack(track, camera);
      }
      final answer = await source.createAnswer();
      await source.setLocalDescription(answer);
      await viewer.setRemoteDescription(answer);
      viewerReady = true;
      for (final candidate in pendingViewer) {
        await viewer.addCandidate(candidate);
      }
      await Future.wait([
        frame.future,
        sized.future,
      ]).timeout(const Duration(seconds: 30));
      expect(renderer.videoWidth, greaterThan(0));
      expect(renderer.videoHeight, greaterThan(0));
    } finally {
      for (final track in camera?.getTracks() ?? <MediaStreamTrack>[]) {
        await track.stop();
      }
      await source.close();
      await viewer.close();
      await source.dispose();
      await viewer.dispose();
      await tester.pumpWidget(const SizedBox());
      await renderer.dispose();
      await camera?.dispose();
    }
  });
}
