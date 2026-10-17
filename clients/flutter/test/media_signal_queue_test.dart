import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:narad_client/api.dart';
import 'package:narad_client/audio.dart';

class Peer extends Fake implements RTCPeerConnection {}
class SignalApi implements NaradApi {
  SignalApi({this.failFirst = false});
  final bool failFirst;
  int active = 0, peak = 0, calls = 0;
  @override
  Future<Map<String, dynamic>> call(Map<String, dynamic> command) async {
    final number = ++calls;
    active++;
    if (active > peak) peak = active;
    try {
      await Future<void>.delayed(const Duration(milliseconds: 1));
      if (failFirst && number == 1) throw StateError('first request failed');
      return {'ok': true};
    } finally { active--; }
  }
}
void main() {
  for (final failFirst in [false, true]) {
    test('concurrent signals stay within API capacity; fail first = $failFirst', () async {
      final api = SignalApi(failFirst: failFirst);
      final audio = AudioController(api, (e) => fail('$e'));
      audio.links['camera'] = AudioLink('camera', 'peer', true, camera: true)..connection = Peer();
      final sends = Future.wait(List.generate(24, (_) => audio.switchCamera('camera')));
      if (failFirst) { await expectLater(sends, throwsStateError); }
      else { await sends; }
      expect(api.calls, 24, reason: 'A failed signal must not block the rest of the queue');
      expect(api.peak, 1, reason: 'ICE bursts must not consume the daemon’s eight local API slots');
      audio.links.clear();
    });
  }
}
