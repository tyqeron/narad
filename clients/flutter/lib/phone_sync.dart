import 'dart:async';
import 'dart:convert';
import 'api.dart';

class PhoneNotice {
  PhoneNotice({
    required this.id,
    required this.peer,
    required this.key,
    required this.title,
    required this.body,
    required this.actions,
    this.progress,
    this.deviceName,
  });
  final String? deviceName;
  final int? progress;
  final int id;
  final String peer, key, title, body;
  final Map<String, String> actions;
}

/// Ephemeral mirrors of authenticated online phones; source grants authorize every click.
class PhoneSync {
  PhoneSync(
    this.api,
    this.notify, {
    required this.cancel,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;
  final DateTime Function() _clock;
  final NaradApi api;
  final Future<void> Function(PhoneNotice notice) notify;
  final Future<void> Function(int id) cancel;
  final Map<String, Map<String, String>> _seen = {};
  final Map<String, PhoneNotice> _posted = {};
  int _nextId = 10000;
  bool _busy = false, _disposed = false;
  DateTime _next = DateTime.fromMillisecondsSinceEpoch(0);
  Future<void> _remove(String key) async {
    final notice = _posted.remove(key);
    if (notice != null) await cancel(notice.id);
  }

  Future<void> act(int id, String action, {String? reply}) async {
    if (_disposed) return;
    final matches = _posted.values.where((n) => n.id == id);
    if (matches.isEmpty) return;
    final n = matches.first;
    if (!n.actions.containsKey(action)) return;
    if (action == 'reply' &&
        (reply == null || reply.trim().isEmpty || reply.length > 2000)) {
      return;
    }
    // Consume before RPC: timeouts must never cause a duplicate send.
    n.actions.remove(action);
    await api.call({
      'op': 'phone_request',
      'peer_id': n.peer,
      'kind': switch (action) {
        'reply' => 'notification_reply',
        'dismiss' => 'notification_dismiss',
        _ => 'notification_action',
      },
      'args': {
        'key': n.key,
        if (action == 'reply') 'text': reply,
        if (action != 'reply' && action != 'dismiss') 'action': action,
      },
    });
    for (final key in _posted.keys.toList()) {
      if (_posted[key]?.id == id) await _remove(key);
    }
  }

  Future<void> tick(Map<String, dynamic> status) async {
    if (_busy || _disposed || _clock().isBefore(_next)) return;
    _busy = true;
    _next = _clock().add(const Duration(seconds: 10));
    try {
      final paired = status['paired'] as Map? ?? {},
          presence = status['presence'] as Map? ?? {};
      final online = paired.keys
          .where(
            (id) =>
                (presence[id] as Map?)?['online'] == true &&
                ((paired[id] as Map)['peer'] as Map)['platform'] == 'android',
          )
          .take(4)
          .map((id) => id.toString())
          .toSet();
      for (final key in _posted.keys.toList()) {
        if (!online.contains(key.split('/').first)) await _remove(key);
      }
      _seen.removeWhere(
        (bucket, _) => !online.contains(bucket.split('/').first),
      );
      for (final id in online) {
        if (_disposed) break;
        final peer = (paired[id] as Map)['peer'] as Map;
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
            final current = <String, String>{};
            for (final item in items) {
              final raw = kind == 'notifications'
                  ? item['key'].toString()
                  : '${item['id']}/${item['state']}';
              final key = '$bucket/$raw';
              final fingerprint = jsonEncode([peer['device_name'], item]);
              current[key] = fingerprint;
              if (_seen[bucket]?[key] == fingerprint) continue;
              if (kind == 'call_state' && item['state'] != 'ringing') continue;
              final n = PhoneNotice(
                id: _posted[key]?.id ?? _nextId++,
                peer: id,
                deviceName: peer['device_name']?.toString(),
                key: raw,
                title: kind == 'notifications'
                    ? '${item['app']}'
                    : 'Incoming call',
                body: kind == 'notifications'
                    ? [
                        item['title']?.toString() ?? '',
                        item['text']?.toString() ?? '',
                      ].where((s) => s.isNotEmpty).toSet().join('\n')
                    : 'Open Phone in Narad for call controls',
                actions: kind == 'notifications'
                    ? {
                        if (item['reply'] == true) 'reply': 'Reply',
                        for (final a
                            in (item['actions'] as List? ?? [])
                                .cast<Map>()
                                .take(item['reply'] == true ? 2 : 3))
                          a['id'].toString(): a['title'].toString(),
                        if (item['dismissible'] == true) 'dismiss': 'Dismiss',
                      }
                    : {},
              );
              _posted[key] = n;
              await notify(n);
            }
            for (final key in _posted.keys.toList()) {
              if (key.startsWith('$bucket/') && !current.containsKey(key)) {
                await _remove(key);
              }
            }
            _seen[bucket] = current;
          } catch (_) {
            for (final key in _posted.keys.toList()) {
              if (key.startsWith('$bucket/')) await _remove(key);
            }
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
    for (final key in _posted.keys.toList()) {
      unawaited(_remove(key).catchError((Object _) {}));
    }
  }
}
