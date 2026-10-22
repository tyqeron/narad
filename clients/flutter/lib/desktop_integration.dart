import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications_windows/flutter_local_notifications_windows.dart';
import 'phone_sync.dart';

class DesktopIntegration {
  DesktopIntegration({
    MethodChannel? channel,
    bool? useWindowsNotifications,
    FlutterLocalNotificationsWindows Function()? windowsFactory,
  }) : _useWindowsNotifications = useWindowsNotifications ?? Platform.isWindows,
       _windowsFactory = windowsFactory ?? FlutterLocalNotificationsWindows.new,
       channel =
           channel ??
           MethodChannel(
             Platform.isWindows ? 'dev.narad/windows' : 'dev.narad/desktop',
           );
  final MethodChannel channel;
  final bool _useWindowsNotifications;
  final FlutterLocalNotificationsWindows Function() _windowsFactory;
  late final _windows = _windowsFactory();
  Future<bool>? _ready;
  Future<Directory>? _iconDirectory;
  Future<File?> _windowsIcon(int id, Uint8List? bytes) async {
    if (bytes == null) return null;
    try {
      final directory = await (_iconDirectory ??= () async {
        final cache = await getApplicationCacheDirectory();
        final folder = Directory('${cache.path}/notification-icons');
        if (await folder.exists()) await folder.delete(recursive: true);
        return folder.create(recursive: true);
      }());
      final file = File('${directory.path}/notice-$id.png');
      await file.writeAsBytes(bytes, flush: true);
      return file;
    } catch (_) {
      return null;
    }
  }

  Future<void> Function(int, String, String?)? onNotificationAction;
  Future<void> Function(List<String>)? onSharedContent;

  void onPrepareQuit(Future<void> Function() shutdown) {
    channel.setMethodCallHandler((call) async {
      if (call.method == 'prepareQuit') await shutdown();
      if (call.method == 'notificationAction') {
        final args = call.arguments as Map;
        await onNotificationAction?.call(
          args['id'] as int,
          args['action'] as String,
          null,
        );
      }
      if (call.method == 'sharedContent') {
        await onSharedContent?.call((call.arguments as List).cast<String>());
      }
    });
  }

  final Map<String, int> _pairingNotices = {};
  int _nextPairingId = 5000;
  bool _pairingBusy = false;
  Future<void> pairingStatus(Map<String, dynamic> snapshot) async {
    if (_pairingBusy) return;
    _pairingBusy = true;
    try {
      final pending = <String>{};
      for (final raw in snapshot['pairings'] as List? ?? const []) {
        final request = raw as Map;
        if (request['outgoing'] == true ||
            request['status'] != 'pending' ||
            ((request['expires_at'] as num?)?.toInt() ?? 0) <=
                DateTime.now().millisecondsSinceEpoch ~/ 1000) {
          continue;
        }
        final key = request['id'] as String;
        pending.add(key);
        if (_pairingNotices.containsKey(key)) continue;
        final id = _nextPairingId++;
        await phoneNotification(
          PhoneNotice(
            id: id,
            peer: '',
            key: key,
            title:
                'Pairing request · ${(request['peer'] as Map)['device_name']}',
            body:
                'Open Narad to review the request and compare the verification code.',
            actions: {'pairing-review': 'Review request'},
          ),
        );
        _pairingNotices[key] = id;
      }
      for (final key in _pairingNotices.keys.toList()) {
        if (!pending.contains(key)) {
          await cancelPhoneNotification(_pairingNotices[key]!);
          _pairingNotices.remove(key);
        }
      }
    } finally {
      _pairingBusy = false;
    }
  }

  final Map<String, String> _transferStates = {};
  bool _transfersInitialized = false;
  Future<void> transferStatus(Map<String, dynamic> snapshot) async {
    for (final direction in ['transfers', 'outbound', 'shared_transfers']) {
      for (final item in (snapshot[direction] as List? ?? const [])) {
        final transfer = item as Map;
        final key = '$direction:${transfer['id']}';
        final state = transfer['status'] as String;
        final total = (transfer['total'] ?? transfer['file_size'] ?? 0) as int;
        final done = (transfer['sent'] ?? transfer['received'] ?? 0) as int;
        final percent = total == 0 ? 0 : (100 * done ~/ total).clamp(0, 100);
        final signature = '$state:$percent';
        final previous = _transferStates[key];
        _transferStates[key] = signature;
        if (previous == signature ||
            (!_transfersInitialized &&
                previous == null &&
                ['completed', 'cancelled'].contains(state))) {
          continue;
        }
        final name =
            transfer['file_name'] ??
            (transfer['path'] as String? ?? 'File')
                .split(RegExp(r'[/\\]'))
                .last;
        await phoneNotification(
          PhoneNotice(
            id: 100000 + (key.hashCode & 0x3fffffff),
            peer: transfer['peer_id'] as String,
            key: key,
            progress: ['completed', 'cancelled'].contains(state)
                ? null
                : percent,
            title:
                '${direction == 'outbound' || transfer['outgoing'] == true ? 'Sending' : 'Receiving'} $name',
            body: state == 'completed'
                ? (direction == 'shared_transfers'
                      ? 'Transfer complete · Shared folder'
                      : 'Transfer complete · Downloads/Narad on the receiving device')
                : '$percent% · $done / $total bytes · $state',
            actions: const {},
          ),
        );
      }
    }
    _transfersInitialized = true;
  }

  Future<bool> autostart() async =>
      (await channel.invokeMapMethod<String, dynamic>(
        'desktopStatus',
      ))?['autostart'] ==
      true;
  Future<void> setAutostart(bool enabled) =>
      channel.invokeMethod<void>('setAutostart', {'enabled': enabled});
  Future<void> phoneNotification(PhoneNotice n) async {
    if (_useWindowsNotifications) {
      _ready ??= _windows.initialize(
        settings: const WindowsInitializationSettings(
          appName: 'Narad',
          appUserModelId: 'dev.narad.narad_client',
          guid: 'cb747b62-a84c-45fb-b748-a3fd223460c8',
        ),
        onDidReceiveNotificationResponse: (r) async {
          final parts = (r.actionId ?? '').split(':');
          if (parts.length < 2) return;
          final id = int.tryParse(parts.first);
          if (id == null) return;
          await onNotificationAction?.call(
            id,
            parts.sublist(1).join(':'),
            r.data['reply']?.toString(),
          );
        },
      );
      if (!await _ready!) throw StateError('Windows notifications unavailable');
      final icon = await _windowsIcon(n.id, n.icon);
      await _windows.show(
        id: n.id,
        title: n.title,
        body: n.body,
        notificationDetails: WindowsNotificationDetails(
          images: [
            if (icon != null)
              WindowsImage(
                icon.uri,
                altText: n.title,
                placement: WindowsImagePlacement.appLogoOverride,
              ),
          ],
          progressBars: [
            if (n.progress != null || n.progressIndeterminate)
              WindowsProgressBar(
                id: 'transfer',
                status: n.body,
                value: n.progressIndeterminate ? null : n.progress! / 100,
              ),
          ],
          actions: [
            for (final a in n.actions.entries)
              WindowsAction(
                content: a.value,
                arguments: '${n.id}:${a.key}',
                inputId: a.key == 'reply' ? 'reply' : null,
              ),
          ],
          inputs: [
            if (n.actions.containsKey('reply'))
              const WindowsTextInput(id: 'reply', placeHolderContent: 'Reply'),
          ],
        ),
      );
    } else {
      await channel.invokeMethod<void>('phoneNotification', {
        'id': n.id,
        'title': n.title,
        'deviceName': n.deviceName,
        'ongoing': n.ongoing,
        'progress': n.progress,
        'progressIndeterminate': n.progressIndeterminate,
        'icon': n.icon,
        'text': n.body,
        'actions': n.actions,
      });
    }
  }

  Future<void> cancelPhoneNotification(int id) async {
    if (_useWindowsNotifications) {
      if (_ready != null && await _ready!) await _windows.cancel(id: id);
      if (_iconDirectory != null) {
        try {
          final folder = await _iconDirectory!;
          final file = File('${folder.path}/notice-$id.png');
          if (await file.exists()) await file.delete();
        } catch (_) {}
      }
    } else {
      await channel.invokeMethod<void>('cancelPhoneNotification', {'id': id});
    }
  }

  Future<void> show() => channel.invokeMethod<void>('show');
  Future<void> quit() => channel.invokeMethod<void>('quit');
}
