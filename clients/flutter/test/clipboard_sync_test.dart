import 'package:flutter_test/flutter_test.dart';
import 'package:narad_client/api.dart';
import 'package:narad_client/clipboard_sync.dart';

class Api implements NaradApi {
  final calls = <Map<String, dynamic>>[];
  @override
  Future<Map<String, dynamic>> call(Map<String, dynamic> c) async {
    calls.add(c);
    return {'ok': true};
  }
}

void main() {
  test(
    'sync is opt-in, ignores existing text and publishes only changes',
    () async {
      final api = Api();
      String? text = 'existing';
      final sync = ClipboardSync(api, read: () async => text);
      await sync.tick(enabled: false, canRead: true);
      expect(api.calls, isEmpty);
      await sync.tick(enabled: true, canRead: true);
      expect(api.calls, isEmpty);
      text = 'new';
      await sync.tick(enabled: true, canRead: false);
      expect(api.calls, isEmpty);
      await sync.tick(enabled: true, canRead: true);
      expect(api.calls.single['text'], 'new');
      await sync.tick(enabled: true, canRead: true);
      expect(api.calls.length, 1);
      await sync.tick(enabled: false, canRead: true);
      text = 'later';
      await sync.tick(enabled: true, canRead: true);
      expect(api.calls.length, 1);
      sync.dispose();
      text = 'after dispose';
      await sync.tick(enabled: true, canRead: true);
      expect(api.calls.length, 1);
    },
  );
}
