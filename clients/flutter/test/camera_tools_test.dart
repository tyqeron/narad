import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:narad_client/camera_tools.dart';

void main() {
  test(
    'camera feed requires random path, rejects foreign Host and closes on stop',
    () async {
      final feed = CameraFeed();
      final client = HttpClient();
      try {
        final url = Uri.parse(await feed.start());
        final request = await client.getUrl(url);
        final page = await request.close();
        expect(page.statusCode, 200);
        expect(page.headers.value('cache-control'), 'no-store');
        await page.drain<void>();
        final wrong = await (await client.getUrl(
          url.replace(path: '/'),
        )).close();
        expect(wrong.statusCode, 404);
        await wrong.drain<void>();
        final rebound = await client.getUrl(url);
        rebound.headers.set('host', 'evil.invalid');
        final denied = await rebound.close();
        expect(denied.statusCode, 404);
        await denied.drain<void>();
        feed.frame = utf8.encode('generated-frame');
        final image = await (await client.getUrl(
          url.resolve('frame.png'),
        )).close();
        expect(await utf8.decoder.bind(image).join(), 'generated-frame');
        await feed.stop();
        expect(feed.url, isNull);
        expect(feed.frame, isNull);
        final fresh = HttpClient();
        try {
          await expectLater(() async {
            final req = await fresh.getUrl(url);
            await req.close();
          }, throwsA(isA<SocketException>()));
        } finally {
          fresh.close(force: true);
        }
      } finally {
        client.close(force: true);
        await feed.stop();
      }
    },
  );
  test('desktop records decodable video and finalizes on session stop', () async {
    if (Platform.isWindows) {
      return; // Windows requires its own FFmpeg/runtime validation.
    }
    try {
      await Process.run('ffmpeg', ['-version']);
    } on ProcessException {
      return;
    }
    final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAIAAACQkWg2AAAAGUlEQVR4nGOUq9jCQApgIkn1qIZRDUNKAwAjwgFqf9sx/AAAAABJRU5ErkJggg==',
    );
    final errors = <Object>[];
    final tools = CameraTools(
      () => throw StateError('fixture must not access hardware'),
      errors.add,
      capture: () async {
        await Future<void>.delayed(const Duration(milliseconds: 180));
        return png;
      },
    );
    try {
      await tools.startRecording();
      await Future<void>.delayed(const Duration(seconds: 2));
      await tools.stop();
      expect(tools.recording, isFalse);
      expect(tools.completed, hasLength(1));
      expect(errors, isEmpty);
      final path = tools.completed.single;
      final probe = await Process.run('ffprobe', [
        '-v',
        'error',
        '-select_streams',
        'v:0',
        '-show_entries',
        'stream=codec_name,width,height,nb_frames,duration',
        '-of',
        'json',
        path,
      ]);
      expect(probe.exitCode, 0);
      final stream =
          (jsonDecode(probe.stdout as String)['streams'] as List).single;
      expect(stream['codec_name'], 'h264');
      expect(double.parse(stream['duration'] as String), greaterThan(1.2));
      expect(stream['width'], 16);
      expect(int.parse(stream['nb_frames'] as String), greaterThan(1));
      final decode = await Process.run('ffmpeg', [
        '-v',
        'error',
        '-i',
        path,
        '-f',
        'null',
        '-',
      ]);
      expect(decode.exitCode, 0);
      await tools.discard(path);
      expect(await File(path).exists(), isFalse);
    } finally {
      await tools.dispose();
    }
  });
}
