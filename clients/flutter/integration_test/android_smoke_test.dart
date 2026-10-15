import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:narad_client/android_backend.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Android vault and embedded backend survive a service restart', (
    tester,
  ) async {
    final backend = AndroidBackend();
    final first = await backend.start();
    final status = await first.call({'op': 'status'});
    final id = status['device']['device_id'];
    expect(status['device']['platform'], 'android');
    expect(await File('${first.stateDirectory}/identity.enc').exists(), isTrue);
    expect(
      await File('${first.stateDirectory}/identity.json').exists(),
      isFalse,
    );
    await backend.stop();
    final second = await backend.start();
    expect((await second.call({'op': 'status'}))['device']['device_id'], id);
  });

  testWidgets(
    'Android native WebRTC exchanges an encrypted data channel message',
    (tester) async {
      final a = await createPeerConnection({'iceServers': []});
      final b = await createPeerConnection({'iceServers': []});
      final pendingA = <RTCIceCandidate>[];
      final pendingB = <RTCIceCandidate>[];
      var readyA = false;
      var readyB = false;
      final received = Completer<String>();
      a.onIceCandidate = (candidate) {
        if (candidate.candidate == null || candidate.candidate!.isEmpty) return;
        if (readyB) {
          unawaited(b.addCandidate(candidate));
        } else {
          pendingB.add(candidate);
        }
      };
      b.onIceCandidate = (candidate) {
        if (candidate.candidate == null || candidate.candidate!.isEmpty) return;
        if (readyA) {
          unawaited(a.addCandidate(candidate));
        } else {
          pendingA.add(candidate);
        }
      };
      b.onDataChannel = (channel) {
        channel.onMessage = (message) {
          if (!received.isCompleted) received.complete(message.text);
        };
      };
      final channel = await a.createDataChannel(
        'narad-smoke',
        RTCDataChannelInit(),
      );
      final opened = Completer<void>();
      channel.onDataChannelState = (state) {
        if (state == RTCDataChannelState.RTCDataChannelOpen &&
            !opened.isCompleted) {
          opened.complete();
        }
      };
      try {
        final offer = await a.createOffer();
        await a.setLocalDescription(offer);
        await b.setRemoteDescription(offer);
        readyB = true;
        for (final candidate in pendingB) {
          await b.addCandidate(candidate);
        }
        final answer = await b.createAnswer();
        await b.setLocalDescription(answer);
        await a.setRemoteDescription(answer);
        readyA = true;
        for (final candidate in pendingA) {
          await a.addCandidate(candidate);
        }
        await opened.future.timeout(const Duration(seconds: 20));
        await channel.send(RTCDataChannelMessage('narad-android-webrtc'));
        expect(
          await received.future.timeout(const Duration(seconds: 10)),
          'narad-android-webrtc',
        );
      } finally {
        await channel.close();
        await a.close();
        await b.close();
        await a.dispose();
        await b.dispose();
      }
    },
  );
}
