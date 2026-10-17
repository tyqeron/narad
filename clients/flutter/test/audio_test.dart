import 'package:flutter_test/flutter_test.dart';
import 'package:narad_client/api.dart';
import 'package:narad_client/audio.dart';

class PendingMediaApi implements NaradApi {
  final commands = <Map<String, dynamic>>[];
  @override
  Future<Map<String, dynamic>> call(Map<String, dynamic> command) async {
    commands.add(command);
    return switch (command['op']) {
      'media_start' => {'ok': true, 'id': 'session'},
      'media_poll' => {
        'ok': true,
        'session': {'state': 'requested'},
      },
      'media_events' => {'ok': true, 'signals': []},
      _ => {'ok': true},
    };
  }
}

void main() {
  test('system audio cannot fall back to a physical microphone', () async {
    final api = PendingMediaApi();
    final audio = AudioController(api, (e) => fail('$e'));
    await expectLater(audio.start('peer', systemAudio: true), throwsStateError);
    expect(api.commands, isEmpty);
  });

  test(
    'receiving playback and requesting a remote microphone never enable local capture',
    () async {
      final api = PendingMediaApi();
      final audio = AudioController(api, (e) => fail('$e'));
      await audio.setEnabled(true);
      expect(audio.microphoneEnabled, false);
      expect(api.commands.last['microphone_ready'], false);
      await audio.requestMicrophone('peer');
      expect(audio.links['session']!.remoteMicrophone, true);
      expect(audio.links['session']!.outgoing, true);
      expect(audio.links['session']!.microphone, isNull);
      await audio.setMicrophoneEnabled(false);
      expect(audio.links.containsKey('session'), true);
      await audio.setEnabled(false);
      expect(audio.links, isEmpty);
    },
  );

  test(
    'no microphone or media negotiation occurs before receiver approval',
    () async {
      final api = PendingMediaApi();
      final audio = AudioController(api, (e) => fail(e.toString()));
      await audio.start('peer');
      await audio.tick({
        'sessions': [
          {'id': 'session', 'peer_id': 'peer', 'state': 'requested'},
        ],
      });
      expect(audio.links['session']!.microphone, isNull);
      expect(audio.links['session']!.connection, isNull);
      expect(api.commands.any((c) => c['op'] == 'media_send'), false);
      await audio.stop('session');
      expect(audio.links, isEmpty);
      expect(api.commands.any((c) => c['op'] == 'session_stop'), true);
      await audio.start('peer');
      await audio.setEnabled(false);
      expect(audio.links, isEmpty);
      expect(
        api.commands.any(
          (c) => c['op'] == 'media_ready' && c['ready'] == false,
        ),
        true,
      );
    },
  );
}
