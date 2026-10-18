import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:narad_client/camera_tools.dart';

// Generated black-box mux fixture: no camera, microphone or personal media access.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Android muxes generated video and PCM into an MP4 with audio', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Text('Narad generated recording test')),
      ),
    );
    final cache = await getTemporaryDirectory();
    final directory = await cache.createTemp('narad-camera-');
    final exported = File('${cache.path}/narad-av-fixture.mp4');
    final checked = File('${cache.path}/narad-av-fixture.checked');
    try {
      if (await checked.exists()) await checked.delete();
      final video = File('${directory.path}/video.mp4');
      await video.writeAsBytes(
        base64Decode(
          'AAAAIGZ0eXBpc29tAAACAGlzb21pc28yYXZjMW1wNDEAAAPxbW9vdgAAAGxtdmhkAAAAAAAAAAAAAAAAAAAD6AAAB9AAAQAAAQAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAAAxx0cmFrAAAAXHRraGQAAAADAAAAAAAAAAAAAAABAAAAAAAAB9AAAAAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAAEAAAAAwAAAAAAAkZWR0cwAAABxlbHN0AAAAAAAAAAEAAAfQAAAQAAABAAAAAAKUbWRpYQAAACBtZGhkAAAAAAAAAAAAAAAAAABAAAAAgABVxAAAAAAALWhkbHIAAAAAAAAAAHZpZGUAAAAAAAAAAAAAAABWaWRlb0hhbmRsZXIAAAACP21pbmYAAAAUdm1oZAAAAAEAAAAAAAAAAAAAACRkaW5mAAAAHGRyZWYAAAAAAAAAAQAAAAx1cmwgAAAAAQAAAf9zdGJsAAAAv3N0c2QAAAAAAAAAAQAAAK9hdmMxAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAEAAMABIAAAASAAAAAAAAAABFExhdmM2My4xLjEwMSBsaWJ4MjY0AAAAAAAAAAAAAAAAGP//AAAANWF2Y0MBZAAK/+EAGGdkAAqs2UR7ARAAAAMAEAAAAwEA8SJZYAEABmjr48siwP34+AAAAAAQcGFzcAAAAAEAAAABAAAAFGJ0cnQAAAAAAAAOtAAAAAAAAAAYc3R0cwAAAAAAAAABAAAAEAAACAAAAAAUc3RzcwAAAAAAAAABAAAAAQAAAIhjdHRzAAAAAAAAAA8AAAABAAAQAAAAAAEAACgAAAAAAQAAEAAAAAABAAAAAAAAAAEAAAgAAAAAAQAAKAAAAAABAAAQAAAAAAEAAAAAAAAAAQAACAAAAAABAAAoAAAAAAEAABAAAAAAAQAAAAAAAAABAAAIAAAAAAEAACAAAAAAAgAACAAAAAAcc3RzYwAAAAAAAAABAAAAAQAAABAAAAABAAAAVHN0c3oAAAAAAAAAAAAAABAAAALZAAAADgAAAAwAAAAMAAAADAAAABQAAAAOAAAADAAAAAwAAAAUAAAADgAAAAwAAAAMAAAAFAAAAA4AAAAMAAAAFHN0Y28AAAAAAAAAAQAABCEAAABhdWR0YQAAAFltZXRhAAAAAAAAACFoZGxyAAAAAAAAAABtZGlyYXBwbAAAAAAAAAAAAAAAACxpbHN0AAAAJKl0b28AAAAcZGF0YQAAAAEAAAAATGF2ZjYzLjEuMTAxAAAACGZyZWUAAAO1bWRhdAAAAq0GBf//qdxF6b3m2Ui3lizYINkj7u94MjY0IC0gY29yZSAxNjUgcjMyMjIgYjM1NjA1YSAtIEguMjY0L01QRUctNCBBVkMgY29kZWMgLSBDb3B5bGVmdCAyMDAzLTIwMjUgLSBodHRwOi8vd3d3LnZpZGVvbGFuLm9yZy94MjY0Lmh0bWwgLSBvcHRpb25zOiBjYWJhYz0xIHJlZj0zIGRlYmxvY2s9MTowOjAgYW5hbHlzZT0weDM6MHgxMTMgbWU9aGV4IHN1Ym1lPTcgcHN5PTEgcHN5X3JkPTEuMDA6MC4wMCBtaXhlZF9yZWY9MSBtZV9yYW5nZT0xNiBjaHJvbWFfbWU9MSB0cmVsbGlzPTEgOHg4ZGN0PTEgY3FtPTAgZGVhZHpvbmU9MjEsMTEgZmFzdF9wc2tpcD0xIGNocm9tYV9xcF9vZmZzZXQ9LTIgdGhyZWFkcz0xIGxvb2thaGVhZF90aHJlYWRzPTEgc2xpY2VkX3RocmVhZHM9MCBucj0wIGRlY2ltYXRlPTEgaW50ZXJsYWNlZD0wIGJsdXJheV9jb21wYXQ9MCBjb25zdHJhaW5lZF9pbnRyYT0wIGJmcmFtZXM9MyBiX3B5cmFtaWQ9MiBiX2FkYXB0PTEgYl9iaWFzPTAgZGlyZWN0PTEgd2VpZ2h0Yj0xIG9wZW5fZ29wPTAgd2VpZ2h0cD0yIGtleWludD0yNTAga2V5aW50X21pbj04IHNjZW5lY3V0PTQwIGludHJhX3JlZnJlc2g9MCByY19sb29rYWhlYWQ9NDAgcmM9Y3JmIG1idHJlZT0xIGNyZj0yMy4wIHFjb21wPTAuNjAgcXBtaW49MCBxcG1heD02OSBxcHN0ZXA9NCBpcF9yYXRpbz0xLjQwIGFxPTE6MS4wMACAAAAAJGWIhAAS//7oyfzLKdCfT6cOYSAraccwj0dI/65B2ZLyCHBYsQAAAApBmiRsQS/+tTlYAAAACEGeQniH/wlZAAAACAGeYXRDvwr4AAAACAGeY2pDvwr5AAAAEEGaaEmoQWiZTAgj//61OVkAAAAKQZ6GRREsP/8JWQAAAAgBnqV0Q78K+QAAAAgBnqdqQ78K+AAAABBBmqxJqEFsmUwIIf/+qnKwAAAACkGeykUVLD//CVkAAAAIAZ7pdEO/CvgAAAAIAZ7rakO/CvgAAAAQQZrvSahBbJlMCHf//qnToQAAAApBnw1FFSw7/wr5AAAACAGfLmpDvwr5',
        ),
      );
      const rate = 48000, frames = rate * 2;
      final wav = ByteData(44 + frames * 2);
      void ascii(int offset, String value) {
        for (var i = 0; i < value.length; i++) {
          wav.setUint8(offset + i, value.codeUnitAt(i));
        }
      }

      ascii(0, 'RIFF');
      wav.setUint32(4, 36 + frames * 2, Endian.little);
      ascii(8, 'WAVEfmt ');
      wav.setUint32(16, 16, Endian.little);
      wav.setUint16(20, 1, Endian.little);
      wav.setUint16(22, 1, Endian.little);
      wav.setUint32(24, rate, Endian.little);
      wav.setUint32(28, rate * 2, Endian.little);
      wav.setUint16(32, 2, Endian.little);
      wav.setUint16(34, 16, Endian.little);
      ascii(36, 'data');
      wav.setUint32(40, frames * 2, Endian.little);
      for (var i = 0; i < frames; i++) {
        wav.setInt16(
          44 + i * 2,
          (sin(2 * pi * 440 * i / rate) * 8000).round(),
          Endian.little,
        );
      }
      final audio = File('${directory.path}/audio.wav');
      await audio.writeAsBytes(wav.buffer.asUint8List());
      final output = File('${directory.path}/recorded.mp4');
      await muxCameraAudio(video.path, audio.path, output.path);
      expect(await output.length(), greaterThan(await video.length()));
      await output.copy(exported.path);
      final deadline = DateTime.now().add(const Duration(seconds: 45));
      while (!await checked.exists() && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      expect(
        await checked.exists(),
        true,
        reason:
            'Run tests/android_recording.py for host audio/video validation',
      );
    } finally {
      if (await exported.exists()) await exported.delete();
      if (await checked.exists()) await checked.delete();
      await directory.delete(recursive: true);
    }
  });
}
