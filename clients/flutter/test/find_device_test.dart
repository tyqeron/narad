import 'dart:typed_data';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:narad_client/api.dart';
import 'package:narad_client/find_device.dart';

class Sound implements LocatorSound {
  int starts = 0;
  int stops = 0;
  @override
  Future<void> start() async {
    starts++;
  }

  @override
  Future<void> stop() async {
    stops++;
  }
}

class FindApi implements NaradApi {
  bool allowed = true;
  List<Map<String, dynamic>> actions = [];
  final results = <Map<String, dynamic>>[];
  @override
  Future<Map<String, dynamic>> call(Map<String, dynamic> command) async {
    if (command['op'] == 'platform_validate' && !allowed) {
      throw StateError('Permission revoked');
    }
    if (command['op'] == 'platform_events') {
      final pending = actions;
      actions = [];
      return {'actions': pending};
    }
    if (command['op'] == 'platform_result') results.add(command);
    return {'ok': true};
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('locator sound is a bounded PCM WAV with audible chirps and pauses', () {
    final wav = locatorWav();
    final data = ByteData.sublistView(wav);
    expect(String.fromCharCodes(wav.take(4)), 'RIFF');
    expect(data.getUint32(24, Endian.little), 16000);
    expect(data.getUint32(40, Endian.little), 16000 * 30 * 2);
    expect(wav.skip(44).take(16000).any((b) => b != 0), isTrue);
    expect(wav.skip(44 + 24000).take(7000).every((b) => b == 0), isTrue);
  });
  test('revoked request never plays and records failure', () async {
    final api = FindApi()
      ..allowed = false
      ..actions = [
        {'id': 'one', 'kind': 'find'},
      ];
    final sound = Sound();
    final finder = FindDeviceController(api, sound: sound);
    await finder.poll();
    expect(sound.starts, 0);
    expect(api.results.single['success'], isFalse);
    await finder.stop();
  });
  test('ring acknowledges once and remote stop cleans up', () async {
    final api = FindApi()
      ..actions = [
        {'id': 'one', 'kind': 'find'},
      ];
    final sound = Sound();
    final finder = FindDeviceController(api, sound: sound);
    await finder.poll();
    expect(finder.ringing, isTrue);
    expect(sound.starts, 1);
    await finder.poll();
    expect(sound.starts, 1);
    api.actions = [
      {'id': 'two', 'kind': 'find_stop'},
    ];
    await finder.poll();
    expect(finder.ringing, isFalse);
    expect(api.results.last['message'], 'Ringing stopped');
    await finder.stop();
  });
  testWidgets('ringing stops automatically and when permission is revoked', (
    tester,
  ) async {
    final api = FindApi()
      ..actions = [
        {'id': 'one', 'kind': 'find'},
      ];
    final sound = Sound();
    final finder = FindDeviceController(api, sound: sound);
    await finder.poll();
    await tester.pump(const Duration(seconds: 31));
    expect(finder.ringing, isFalse);
    api.actions = [
      {'id': 'two', 'kind': 'find'},
    ];
    await finder.poll();
    api.allowed = false;
    await finder.poll();
    expect(finder.ringing, isFalse);
    await finder.stop();
  });
  test(
    'real Linux locator playback starts and cleans temporary audio',
    () async {
      Set<String> alerts() => Directory.systemTemp
          .listSync()
          .whereType<Directory>()
          .where(
            (d) => d.path
                .split(Platform.pathSeparator)
                .last
                .startsWith('narad-find-'),
          )
          .map((d) => d.path)
          .toSet();
      final before = alerts();
      final sound = DeviceLocatorSound();
      try {
        await sound.start();
        expect(alerts().difference(before), hasLength(1));
        await Future<void>.delayed(const Duration(milliseconds: 700));
      } finally {
        await sound.stop();
      }
      expect(alerts().difference(before), isEmpty);
    },
    skip:
        !Platform.isLinux ||
        !const bool.fromEnvironment('NARAD_TEST_REAL_LOCATOR'),
  );
}
