import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

class DeviceAction {
  const DeviceAction(
    this.title,
    this.icon,
    this.run, {
    this.requiresOnline = true,
  });
  final String title;
  final IconData icon;
  final Future<void> Function() run;
  final bool requiresOnline;
}

class DeviceActionsPage extends StatelessWidget {
  const DeviceActionsPage({
    super.key,
    required this.peerId,
    required this.name,
    required this.status,
    required this.actions,
    required this.settings,
  });
  final String peerId, name;
  final ValueListenable<Map<String, dynamic>> status;
  final List<DeviceAction> actions;
  final Future<void> Function() settings;
  @override
  Widget build(
    BuildContext context,
  ) => ValueListenableBuilder<Map<String, dynamic>>(
    valueListenable: status,
    builder: (context, data, _) {
      final paired = (data['paired'] as Map?)?.containsKey(peerId) ?? false;
      final online =
          paired && (data['presence'] as Map?)?[peerId]?['online'] == true;
      return Scaffold(
        appBar: AppBar(
          title: Text(name),
          actions: [
            IconButton(
              tooltip: 'Device settings and permissions',
              icon: const Icon(Icons.settings_outlined),
              onPressed: paired ? settings : null,
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            ListTile(
              leading: Icon(
                online ? Icons.check_circle_outline : Icons.cloud_off_outlined,
              ),
              title: Text(
                online
                    ? 'Connected'
                    : paired
                    ? 'Offline'
                    : 'No longer paired',
              ),
              subtitle: online
                  ? null
                  : const Text(
                      'Communication actions are available when this device is online.',
                    ),
            ),
            const SizedBox(height: 12),
            for (final action in actions)
              Card(
                child: ListTile(
                  leading: Icon(action.icon),
                  title: Text(action.title),
                  trailing: const Icon(Icons.chevron_right),
                  enabled: paired && (online || !action.requiresOnline),
                  onTap: paired && (online || !action.requiresOnline)
                      ? action.run
                      : null,
                ),
              ),
          ],
        ),
      );
    },
  );
}
