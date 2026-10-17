import 'package:flutter_test/flutter_test.dart';
import 'package:narad_client/audio.dart';
import 'package:narad_client/desktop_audio_routes.dart';

void main() {
  test(
    'music input uses recording source ID and disables voice processing',
    () {
      final c = audioCaptureConstraints(
        inputDeviceId: 'owned-source',
        systemAudio: true,
      );
      expect(c['optional'], [
        {'sourceId': 'owned-source'},
      ]);
      expect(c.containsKey('deviceId'), isFalse);
      expect(c['echoCancellation'], false);
      expect(c['noiseSuppression'], false);
      expect(c['autoGainControl'], false);
      expect(audioCaptureConstraints()['echoCancellation'], true);
    },
  );
  test('media SDP cannot escalate media kind or capture direction', () {
    String sdp(String media, String direction) =>
        'v=0\r\nm=$media 9 UDP/TLS/RTP/SAVPF 111\r\na=$direction\r\n';
    validateMediaSdp(
      sdp('audio', 'recvonly'),
      video: false,
      direction: 'recvonly',
    );
    validateMediaSdp(
      sdp('video', 'recvonly'),
      video: true,
      direction: 'recvonly',
    );
    for (final wrong in [
      sdp('video', 'recvonly'),
      sdp('audio', 'sendrecv'),
      sdp('audio', 'sendonly'),
      sdp('audio', 'inactive'),
      "${sdp('audio', 'recvonly')}a=sendrecv\r\n",
      sdp('audio', 'recvonly') + sdp('video', 'recvonly'),
      'v=0',
    ]) {
      expect(
        () => validateMediaSdp(wrong, video: false, direction: 'recvonly'),
        throwsStateError,
      );
    }
  });
  test(
    'meeting routes use separate cables and unload only owned modules',
    () async {
      final calls = <List<String>>[];
      var id = 100;
      final routes = LinuxAudioRoutes(
        token: 'test',
        command: (args) async {
          calls.add(args);
          return args.first == 'load-module' ? '${id++}' : '';
        },
      );
      await routes.createMeetingDevices();
      expect(calls.length, 4);
      expect(calls[0], contains('sink_name=narad_speaker_test'));
      expect(calls[1], contains('master=narad_speaker_test.monitor'));
      expect(calls[2], contains('sink_name=narad_mic_feed_test'));
      expect(calls[3], contains('source_name=narad_microphone_test'));
      await routes.dispose();
      expect(calls.skip(4).toList(), [
        for (final id in [103, 102, 101, 100]) ['unload-module', '$id'],
      ]);
      expect(routes.created, false);
      await routes.dispose();
      expect(calls.length, 8);
    },
  );
  test('partial creation rolls back and failed cleanup can retry', () async {
    final unloaded = <String>[];
    var loads = 0, failUnload = true;
    final routes = LinuxAudioRoutes(
      token: 'rollback',
      command: (args) async {
        if (args.first == 'load-module') {
          if (++loads == 3) throw StateError('load failed');
          return '$loads';
        }
        unloaded.add(args.last);
        if (failUnload && args.last == '1') throw StateError('busy');
        return '';
      },
    );
    await expectLater(routes.createMeetingDevices(), throwsStateError);
    expect(unloaded, ['2', '1']);
    expect(routes.created, true);
    failUnload = false;
    await routes.dispose();
    expect(unloaded, ['2', '1', '1']);
    expect(routes.created, false);
  });
  test(
    'system capture monitors current output without changing defaults',
    () async {
      final calls = <List<String>>[];
      final routes = LinuxAudioRoutes(
        token: 'system',
        command: (args) async {
          calls.add(args);
          return args.first == 'get-default-sink'
              ? 'alsa_output.test'
              : args.first == 'load-module'
              ? '42'
              : '';
        },
      );
      await routes.createSystemMonitor();
      expect(calls[1], contains('master=alsa_output.test.monitor'));
      expect(
        calls.every(
          (a) => !a.first.startsWith('set-') && !a.first.startsWith('move-'),
        ),
        true,
      );
      await routes.dispose();
    },
  );
}
