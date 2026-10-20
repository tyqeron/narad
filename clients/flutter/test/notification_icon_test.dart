import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:narad_client/notification_icon.dart';
import 'fixtures/notification_icon.dart';

void main() {
  test('decodes the bounded PNG format used by notification sync', () {
    expect(
      notificationIcon(sampleNotificationIcon),
      base64Decode(sampleNotificationIcon),
    );
  });
  test(
    'missing, malformed and oversized icons fall back without losing the notice',
    () {
      for (final input in [
        null,
        42,
        '',
        'file:///tmp/icon.png',
        'https://example.com/icon.png',
        '%bad',
        'A' * 8193,
      ]) {
        expect(notificationIcon(input), isNull);
      }
      final bytes = base64Decode(sampleNotificationIcon);
      ByteData.sublistView(bytes).setUint32(16, 100000);
      expect(notificationIcon(base64Encode(bytes)), isNull);
      expect(notificationIcon(base64Encode(bytes.sublist(0, 20))), isNull);
      bytes[0] = 0;
      expect(notificationIcon(base64Encode(bytes)), isNull);
    },
  );
}
