import 'api.dart';

/// Polls only authenticated online phones. No archive and no notification bodies in OS banners.
class PhoneSync {
  PhoneSync(this.api, this.notify, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;
  final DateTime Function() _clock;
  final NaradApi api;
  final Future<void> Function(String title, String text) notify;
  final Map<String, Set<String>> _seen = {};
  bool _busy = false, _disposed = false;
  DateTime _next = DateTime.fromMillisecondsSinceEpoch(0);
  Future<void> tick(Map<String, dynamic> status) async {
    if (_busy || _disposed || _clock().isBefore(_next)) return;
    _busy = true;
    _next = _clock().add(const Duration(seconds: 10));
    try {
      final paired = status['paired'] as Map? ?? {},
          presence = status['presence'] as Map? ?? {};
      _seen.removeWhere((bucket, _) {
        final id = bucket.split('/').first;
        return !paired.containsKey(id) ||
            (presence[id] as Map?)?['online'] != true;
      });
      var phones = 0;
      for (final entry in paired.entries) {
        if (_disposed) break;
        final peer = (entry.value as Map)['peer'] as Map;
        if (peer['platform'] != 'android' ||
            (presence[entry.key] as Map?)?['online'] != true) {
          continue;
        }
        if (++phones > 4) break;
        final id = entry.key.toString();
        for (final kind in ['notifications', 'call_state']) {
          final bucket = '$id/$kind';
          try {
            final result = await api.call({
              'op': 'phone_request',
              'peer_id': id,
              'kind': kind,
              'args': <String, dynamic>{},
            });
            if (_disposed) break;
            final items = (result['items'] as List? ?? []).cast<Map>();
            final keys = items
                .map(
                  (n) => kind == 'notifications'
                      ? n['key'].toString()
                      : '${n['id']}/${n['state']}',
                )
                .toSet();
            final previous = _seen[bucket];
            _seen[bucket] = keys;
            if (previous == null && kind == 'notifications') continue;
            for (final item in items) {
              final key = kind == 'notifications'
                  ? item['key'].toString()
                  : '${item['id']}/${item['state']}';
              if (previous?.contains(key) == true) continue;
              if (kind == 'call_state' && item['state'] != 'ringing') continue;
              await notify(
                kind == 'notifications'
                    ? 'Notification on ${peer['device_name']}'
                    : 'Incoming call on ${peer['device_name']}',
                kind == 'notifications'
                    ? '${item['app']} · Open Narad to view'
                    : 'Open Phone in Narad for call controls',
              );
            }
          } catch (_) {
            _seen.remove(bucket);
          }
        }
      }
    } finally {
      _busy = false;
    }
  }

  void dispose() {
    _disposed = true;
    _seen.clear();
  }
}
