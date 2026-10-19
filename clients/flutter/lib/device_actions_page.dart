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
    required this.loadInfo,
  });
  final String peerId, name;
  final ValueListenable<Map<String, dynamic>> status;
  final List<DeviceAction> actions;
  final Future<void> Function() settings;
  final Future<Map<String, dynamic>> Function() loadInfo;
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
            if (paired && online) _DeviceInfoCard(loadInfo: loadInfo),
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

class _DeviceInfoCard extends StatefulWidget {
  const _DeviceInfoCard({required this.loadInfo});
  final Future<Map<String, dynamic>> Function() loadInfo;
  @override
  State<_DeviceInfoCard> createState() => _DeviceInfoCardState();
}

class _DeviceInfoCardState extends State<_DeviceInfoCard> {
  late Future<Map<String, dynamic>> _info;
  @override
  void initState() {
    super.initState();
    _info = widget.loadInfo();
  }

  @override
  Widget build(BuildContext context) => Card(
    child: FutureBuilder<Map<String, dynamic>>(
      future: _info,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('Device information'),
            subtitle: Text(snapshot.error.toString()),
            trailing: IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: () => setState(() => _info = widget.loadInfo()),
            ),
          );
        }
        if (!snapshot.hasData) {
          return const ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('Device information'),
            subtitle: Text('Loading…'),
          );
        }
        final data = snapshot.data!;
        final battery = data['battery'] as Map? ?? const {};
        final network = data['network'] as Map? ?? const {};
        final cellular = network['cellular'] as Map? ?? const {};
        final interfaces = network['interfaces'] as List? ?? const [];
        final percent = battery['percent'];
        final charging = battery['charging'] == true;
        final networkNames = interfaces
            .map((item) {
              final m = item as Map;
              return '${m['type'] ?? 'network'}${m['state'] == null ? '' : ' · ${m['state']}'}';
            })
            .join(', ');
        final details = <String>[
          if (percent != null)
            'Battery: $percent%${charging ? ' · charging' : ''}'
          else
            'Battery: unavailable',
          'Network: ${networkNames.isEmpty ? 'unavailable' : networkNames}',
          if (network['address'] != null) 'Address: ${network['address']}',
          'Cellular: ${cellular['connected'] == true
              ? 'connected'
              : cellular['available'] == true
              ? 'available'
              : 'unavailable'}',
        ];
        return ListTile(
          leading: const Icon(Icons.monitor_heart_outlined),
          title: const Text('Device information'),
          subtitle: Text(details.join('\n')),
          isThreeLine: true,
          trailing: IconButton(
            tooltip: 'Refresh device information',
            icon: const Icon(Icons.refresh),
            onPressed: () => setState(() => _info = widget.loadInfo()),
          ),
        );
      },
    ),
  );
}
