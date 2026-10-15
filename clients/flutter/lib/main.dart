import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'api.dart';
import 'audio.dart';
import 'android_backend.dart';
import 'pairing_scanner.dart';

void main() => runApp(const NaradApp());

class NaradApp extends StatelessWidget {
  const NaradApp({super.key, this.api});
  final NaradApi? api;
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Narad',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff286458)),
      useMaterial3: true,
      scaffoldBackgroundColor: const Color(0xfff6f7f3),
      cardTheme: const CardThemeData(
        elevation: 0,
        color: Colors.white,
        margin: EdgeInsets.only(bottom: 12),
      ),
    ),
    home: Dashboard(api: api),
  );
}

class Dashboard extends StatefulWidget {
  const Dashboard({super.key, this.api});
  final NaradApi? api;
  @override
  State<Dashboard> createState() => _DashboardState();
}

class _DashboardState extends State<Dashboard> with WidgetsBindingObserver {
  late final TextEditingController _directory;
  final _port = TextEditingController(
    text: Platform.environment['NARAD_API_PORT'] ?? '45700',
  );
  AndroidBackend? _android;
  bool _starting = false;
  NaradApi? _api;
  AudioController? _audio;
  Map<String, dynamic> _data = {};
  Timer? _timer;
  bool _online = false, _busy = false, _refreshing = false;
  String? _error;
  int _page = 0;
  int _connectionGeneration = 0;
  static const _titles = ['Devices', 'Inbox', 'Transfers', 'Audio', 'Activity'];
  static const _icons = [
    Icons.devices_rounded,
    Icons.inbox_outlined,
    Icons.swap_vert_rounded,
    Icons.graphic_eq_rounded,
    Icons.monitor_heart_outlined,
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _directory = TextEditingController(
      text: Platform.environment['NARAD_STATE'] ?? '../../.narad',
    );
    if (widget.api != null) {
      _attach(widget.api!);
    } else if (Platform.isAndroid) {
      _android = AndroidBackend();
      unawaited(_startAndroid());
    } else {
      unawaited(_autoConnect());
    }
  }

  Future<void> _startAndroid() async {
    if (_starting) return;
    setState(() => _starting = true);
    try {
      final api = await _android!.start();
      if (!mounted) return;
      _directory.text = api.stateDirectory;
      _port.text = api.port.toString();
      _attach(api);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_android == null) return;
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      // Background availability is for control/files. Microphone capture stays foreground-only.
      if (_audio != null) {
        unawaited(
          _audio!.setEnabled(false).catchError((Object error) {
            if (mounted) _showError(error);
          }),
        );
      }
    }
    if (state == AppLifecycleState.resumed && !_online && !_starting) {
      unawaited(_startAndroid());
    }
  }

  Future<void> _autoConnect() async {
    if (await File('${_directory.text}/api-token').exists() && mounted) {
      _connect();
    }
  }

  void _attach(NaradApi api) {
    _connectionGeneration++;
    final previous = _audio;
    if (previous != null) unawaited(previous.dispose().catchError(_showError));
    _api = api;
    _audio = AudioController(api, _showError);
    unawaited(_refresh());
    _timer?.cancel();
    _timer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => unawaited(_refresh()),
    );
  }

  void _connect() {
    final port = int.tryParse(_port.text);
    if (port == null || port <= 0 || port > 65535) {
      _showError('Enter a valid local API port.');
      return;
    }
    _attach(DaemonApi(_directory.text, port));
  }

  List<Map<String, dynamic>> _items(String name) =>
      ((_data[name] as List?) ?? []).cast<Map<String, dynamic>>();
  Map<String, dynamic> get _paired =>
      (_data['paired'] as Map?)?.cast<String, dynamic>() ?? {};
  String _peerName(String id) =>
      (_paired[id] as Map?)?['peer']?['device_name'] as String? ??
      'Nearby device';
  String _short(String id) => id.length > 12 ? id.substring(0, 12) : id;

  Future<void> _refresh() async {
    if (_refreshing || _api == null) return;
    _refreshing = true;
    final generation = _connectionGeneration;
    final api = _api!;
    final audio = _audio;
    try {
      final data = await api.call({'op': 'status'});
      var more = data['has_more'] == true;
      var offset = 32;
      while (more && offset <= 512) {
        final page = await api.call({'op': 'status', 'offset': offset});
        for (final key in [
          'pairings',
          'transfers',
          'outbound',
          'sessions',
          'clipboard',
        ]) {
          (data[key] as List).addAll(page[key] as List);
        }
        for (final key in ['paired', 'permissions']) {
          (data[key] as Map).addAll(page[key] as Map);
        }
        more = page['has_more'] == true;
        offset += 32;
      }
      if (!mounted || generation != _connectionGeneration) return;
      setState(() {
        _data = data;
        _online = true;
        _error = null;
      });
      try {
        await audio?.tick(data);
      } catch (error) {
        _showError(error);
      }
    } catch (error) {
      if (mounted && generation == _connectionGeneration) {
        setState(() {
          _online = false;
          _error = error.toString();
        });
      }
      if (audio != null) {
        for (final id in audio.links.keys.toList()) {
          await audio.stop(id, notify: false);
        }
      }
    } finally {
      _refreshing = false;
    }
  }

  void _showError(Object error) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(error.toString()),
        backgroundColor: Theme.of(context).colorScheme.error,
      ),
    );
  }

  void _notice(String message) {
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
      await _refresh();
    } catch (error) {
      _showError(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _command(Map<String, dynamic> command) async {
    await _api!.call(command);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    if (_audio != null) unawaited(_audio!.dispose());
    _directory.dispose();
    _port.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, size) {
      final wide = size.maxWidth >= 780;
      return Scaffold(
        appBar: AppBar(
          title: Row(
            children: [
              Icon(
                Icons.hub_rounded,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(width: 12),
              const Text(
                'Narad',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            ],
          ),
          actions: [
            if (_online)
              Padding(
                padding: const EdgeInsets.only(right: 16),
                child: Chip(
                  avatar: const Icon(Icons.lan_outlined, size: 18),
                  label: Text(wide ? 'Local network · encrypted' : 'Local'),
                ),
              ),
          ],
        ),
        body: Row(
          children: [
            if (wide && _online)
              NavigationRail(
                selectedIndex: _page,
                labelType: NavigationRailLabelType.all,
                onDestinationSelected: (index) => setState(() => _page = index),
                destinations: List.generate(
                  _titles.length,
                  (i) => NavigationRailDestination(
                    icon: Icon(_icons[i]),
                    label: Text(_titles[i]),
                  ),
                ),
              ),
            Expanded(
              child: !_online
                  ? _connection()
                  : Column(
                      children: [
                        if (_busy) const LinearProgressIndicator(minHeight: 2),
                        Expanded(
                          child: Align(
                            alignment: Alignment.topCenter,
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 1080),
                              child: ListView(
                                padding: EdgeInsets.all(wide ? 32 : 16),
                                children: [
                                  Text(
                                    _titles[_page],
                                    style: Theme.of(context)
                                        .textTheme
                                        .headlineMedium
                                        ?.copyWith(fontWeight: FontWeight.w700),
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    _subtitle(),
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodyMedium
                                        ?.copyWith(color: Colors.black54),
                                  ),
                                  const SizedBox(height: 24),
                                  ...switch (_page) {
                                    0 => _devices(),
                                    1 => _inbox(),
                                    2 => _transfers(),
                                    3 => _audioPage(),
                                    _ => _activity(),
                                  },
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
            ),
          ],
        ),
        bottomNavigationBar: !wide && _online
            ? NavigationBar(
                selectedIndex: _page,
                onDestinationSelected: (index) => setState(() => _page = index),
                destinations: List.generate(
                  _titles.length,
                  (i) => NavigationDestination(
                    icon: Icon(_icons[i]),
                    label: _titles[i],
                  ),
                ),
              )
            : null,
      );
    },
  );

  String _subtitle() => switch (_page) {
    0 =>
      'Connect nearby devices. Pairing gives you trust; permissions stay in your hands.',
    1 => 'Review pairing, file, clipboard, and audio requests.',
    2 =>
      'Files travel directly between your devices. Interrupted transfers can resume.',
    3 => 'Send your microphone to a paired device’s speakers over your LAN.',
    _ => 'Connection details and recent decisions, kept on this device.',
  };

  Widget _connection() => _android != null
      ? Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.hub_rounded,
                  size: 56,
                  color: Color(0xff286458),
                ),
                const SizedBox(height: 20),
                Text(
                  _starting ? 'Starting Narad…' : 'Connect your devices',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 12),
                const Text(
                  'Use the same Wi-Fi network on each device. Narad keeps your identity and files privately on this device.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 20),
                if (_starting) const CircularProgressIndicator(),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Text(
                      _error!,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                if (!_starting)
                  FilledButton(
                    onPressed: () => _startAndroid(),
                    child: const Text('Start Narad'),
                  ),
              ],
            ),
          ),
        )
      : Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 540),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.hub_rounded,
                    size: 52,
                    color: Color(0xff286458),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    'Your devices, connected locally.',
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Start the Narad daemon, then connect this app to its local state directory. Devices communicate directly over your network.',
                  ),
                  const SizedBox(height: 20),
                  const SelectableText(
                    'cargo run -p narad -- serve --name "My laptop"',
                    style: TextStyle(fontFamily: 'monospace'),
                  ),
                  const SizedBox(height: 24),
                  TextField(
                    controller: _directory,
                    decoration: const InputDecoration(
                      labelText: 'Daemon state directory',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _port,
                    decoration: const InputDecoration(
                      labelText: 'Local API port',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  FilledButton.icon(
                    onPressed: _connect,
                    icon: const Icon(Icons.link),
                    label: const Text('Connect to Narad'),
                  ),
                ],
              ),
            ),
          ),
        );

  Widget _empty(String title, String detail, IconData icon) => Card(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        children: [
          Icon(icon, size: 36, color: Colors.black38),
          const SizedBox(height: 12),
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(
            detail,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.black54),
          ),
        ],
      ),
    ),
  );
  Widget _section(String title) => Padding(
    padding: const EdgeInsets.only(top: 16, bottom: 12),
    child: Text(title, style: Theme.of(context).textTheme.titleLarge),
  );
  Widget _card(
    IconData icon,
    String title,
    String subtitle,
    List<Widget> actions, {
    Widget? extra,
  }) => Card(
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: const TextStyle(color: Colors.black54),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (extra != null)
            Padding(padding: const EdgeInsets.only(top: 12), child: extra),
          if (actions.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 14),
              child: Wrap(spacing: 8, runSpacing: 8, children: actions),
            ),
        ],
      ),
    ),
  );
  Widget _button(
    String text,
    Future<void> Function() action, {
    bool primary = false,
  }) => primary
      ? FilledButton(
          onPressed: _busy ? null : () => _run(action),
          child: Text(text),
        )
      : OutlinedButton(
          onPressed: _busy ? null : () => _run(action),
          child: Text(text),
        );

  List<Widget> _devices() => [
    _card(
      Icons.computer_rounded,
      _data['device']['device_name'] as String,
      '${_data['device']['platform']} · This device',
      [
        _button('Create invitation', _invitation, primary: true),
        _button('Enter invitation', _enterInvitation),
        if (_android != null) _button('Scan invitation', _scanInvitation),
        if (_android != null) _button('Rename device', _renameDevice),
      ],
    ),
    _section('Paired devices'),
    if (_paired.isEmpty)
      _empty(
        'No paired devices yet',
        'Create an invitation on one device and enter it on the other.',
        Icons.link,
      ),
    for (final record in _paired.values)
      _pairedCard((record as Map)['peer'] as Map<String, dynamic>),
    _section('Nearby devices'),
    if (_items('discovered').isEmpty)
      _empty(
        'Looking on your local network',
        'Both devices need Narad running on the same LAN. Invitations also work when discovery is unavailable.',
        Icons.radar,
      ),
    for (final peer in _items('discovered'))
      if (!_paired.containsKey(peer['device_id']))
        _card(
          Icons.devices_other,
          peer['device_name'] as String,
          '${peer['platform']} · Discovered, awaiting pairing',
          [_button('Enter invitation', _enterInvitation)],
        ),
  ];
  Widget _pairedCard(Map<String, dynamic> peer) => _card(
    Icons.verified_user_outlined,
    peer['device_name'] as String,
    '${peer['platform']} · Paired',
    [
      _button(
        'Send file',
        () => _sendFile(peer['device_id'] as String),
        primary: true,
      ),
      _button(
        'Send clipboard',
        () => _sendClipboard(peer['device_id'] as String),
      ),
      _button('Permissions', () => _permissions(peer)),
      _button('Unpair', () => _unpair(peer)),
    ],
  );

  Future<void> _invitation() async {
    if (_android != null && _data['device']['address'] == '127.0.0.1') {
      throw StateError(
        'Connect to Wi-Fi or a local hotspot before creating an invitation.',
      );
    }
    final result = await _api!.call({'op': 'invite'});
    final invitation = jsonEncode(result['invitation']);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Pair another device'),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Share this invitation with the other device. Compare the verification code on both screens before approving. This invitation expires in five minutes.',
                ),
                const SizedBox(height: 16),
                QrImageView(
                  data: invitation,
                  size: 240,
                  backgroundColor: Colors.white,
                ),
                const SizedBox(height: 12),
                const Text(
                  'Copy the invitation and use “Enter invitation” on the other device.',
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: invitation));
              _notice('Invitation copied');
            },
            child: const Text('Copy invitation'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }

  Future<void> _scanInvitation() async {
    final text = await Navigator.of(
      context,
    ).push<String>(MaterialPageRoute(builder: (_) => const PairingScanner()));
    if (text != null) await _pairText(text);
  }

  Future<void> _renameDevice() async {
    final name = await _input(
      'Device name',
      'Choose a name for this device',
      initial: _data['device']['device_name'] as String,
    );
    if (name == null) return;
    await _command({'op': 'device_name', 'name': name});
    await _android!.setDeviceName(name);
  }

  Future<void> _pairText(String text) async {
    final raw = jsonDecode(text) as Map<String, dynamic>;
    final result = await _api!.call({
      'op': 'pair',
      'invitation': raw['invitation'] ?? raw,
    });
    _notice(
      'Compare code ${result['code']} on both devices, then approve in Inbox.',
    );
    if (mounted) setState(() => _page = 1);
  }

  Future<void> _enterInvitation() async {
    final text = await _input(
      'Enter invitation',
      'Paste the invitation from your other device',
      multiline: true,
    );
    if (text == null) return;
    await _pairText(text);
  }

  Future<String?> _input(
    String title,
    String label, {
    bool multiline = false,
    String initial = '',
  }) async {
    final controller = TextEditingController(text: initial);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 440,
          child: TextField(
            controller: controller,
            autofocus: true,
            maxLines: multiline ? 6 : 1,
            decoration: InputDecoration(
              labelText: label,
              border: const OutlineInputBorder(),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    // Let the dialog's closing animation release its text field first.
    await Future<void>.delayed(const Duration(milliseconds: 250));
    controller.dispose();
    return result;
  }

  Future<bool> _confirm(String title, String detail) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(detail),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Confirm'),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _permissions(Map<String, dynamic> peer) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text('Permissions · ${peer['device_name']}'),
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'File and audio sessions still require approval. Clipboard permission allows offers; each payload needs acceptance.',
                ),
                for (final entry in {
                  'file.transfer': 'Receive files',
                  'clipboard.sync': 'Receive clipboard offers',
                  'audio.output': 'Play shared audio',
                }.entries)
                  SwitchListTile(
                    title: Text(entry.value),
                    value:
                        ((_data['permissions']
                                    as Map?)?['${peer['device_id']}/${entry.key}'] ??
                                false)
                            as bool,
                    onChanged: (allow) async {
                      try {
                        await _command({
                          'op': 'permission',
                          'peer_id': peer['device_id'],
                          'capability': entry.key,
                          'allow': allow,
                        });
                        await _refresh();
                        if (context.mounted) update(() {});
                      } catch (error) {
                        _showError(error);
                      }
                    },
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Done'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _unpair(Map<String, dynamic> peer) async {
    if (await _confirm(
      'Unpair ${peer['device_name']}?',
      'This closes its sessions and removes capability permissions.',
    )) {
      await _command({'op': 'unpair', 'peer_id': peer['device_id']});
    }
  }

  List<Widget> _inbox() {
    final pairings = _items('pairings').where((p) => p['status'] == 'pending');
    final files = _items('transfers').where((t) => t['status'] == 'pending');
    final media = _items('sessions').where(
      (s) =>
          s['capability'] == 'audio.output' &&
          s['state'] == 'requested' &&
          !(_audio?.links[s['id']]?.outgoing ?? false),
    );
    final clipboard = _items('clipboard');
    if (pairings.isEmpty &&
        files.isEmpty &&
        media.isEmpty &&
        clipboard.isEmpty) {
      return [
        _empty(
          'You’re all caught up',
          'New device and capability requests appear here.',
          Icons.task_alt,
        ),
      ];
    }
    return [
      for (final pair in pairings)
        _card(
          Icons.link,
          'Pair with ${(pair['peer'] as Map)['device_name']}',
          'Compare this code on both devices: ${pair['code']}',
          [
            _button(
              pair['outgoing'] == true
                  ? 'Confirm both devices'
                  : 'Codes match · approve',
              () async {
                if (await _confirm(
                  'Do both devices show ${pair['code']}?',
                  'Approve only if you recognize this device and the codes match.',
                )) {
                  await _command({
                    'op': pair['outgoing'] == true
                        ? 'pair_confirm'
                        : 'pair_approve',
                    'id': pair['id'],
                    'code': pair['code'],
                  });
                }
              },
              primary: true,
            ),
            _button(
              'Decline',
              () => _command({'op': 'pair_deny', 'id': pair['id']}),
            ),
          ],
        ),
      for (final t in files)
        _card(
          Icons.file_download_outlined,
          t['file_name'] as String,
          '${_bytes(t['file_size'] as int)} from ${_peerName(t['peer_id'] as String)}',
          [
            _button(
              'Accept file',
              () => _command({'op': 'file_accept', 'id': t['id']}),
              primary: true,
            ),
            _button(
              'Decline',
              () => _command({'op': 'file_cancel', 'id': t['id']}),
            ),
          ],
        ),
      for (final c in clipboard)
        _card(
          Icons.content_paste,
          'Clipboard from ${_peerName(c['peer_id'] as String)}',
          c['preview'] as String,
          [
            _button('Copy to clipboard', () async {
              final result = await _api!.call({
                'op': 'clipboard_accept',
                'id': c['id'],
              });
              await Clipboard.setData(
                ClipboardData(text: result['text'] as String),
              );
              _notice('Clipboard updated');
            }, primary: true),
            _button(
              'Ignore',
              () => _command({'op': 'clipboard_deny', 'id': c['id']}),
            ),
          ],
        ),
      for (final s in media)
        _card(
          Icons.speaker_outlined,
          'Audio from ${_peerName(s['peer_id'] as String)}',
          'Allow this device’s microphone to play through your speakers?',
          [
            _button(
              'Allow audio',
              () => _command({'op': 'media_accept', 'id': s['id']}),
              primary: true,
            ),
            _button(
              'Decline',
              () => _command({'op': 'media_deny', 'id': s['id']}),
            ),
          ],
        ),
    ];
  }

  String _bytes(int bytes) => bytes >= 1024 * 1024
      ? '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB'
      : '${(bytes / 1024).toStringAsFixed(1)} KB';
  Future<void> _sendFile(String peer, {String? path, String? id}) async {
    if (path != null && !await File(path).exists()) {
      path = null;
      _notice('Select the original file again to resume the transfer.');
    }
    if (path == null) {
      final result = await FilePicker.pickFile();
      path = result?.path;
    }
    if (path == null) return;
    final result = await _api!.call({
      'op': 'send_file',
      'peer_id': peer,
      'path': path,
      'id': ?id,
    });
    _notice(
      result['status'] == 'pending'
          ? 'File offered. After the other device accepts, press Send / resume.'
          : 'Transfer ${result['status']}',
    );
    if (mounted) setState(() => _page = 2);
  }

  Future<void> _sendClipboard(String peer) async {
    final current = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted) return;
    final text = await _input(
      'Send clipboard',
      'Review text before sending',
      multiline: true,
      initial: current?.text ?? '',
    );
    if (text == null || text.isEmpty) return;
    await _command({'op': 'send_clipboard', 'peer_id': peer, 'text': text});
    _notice('Clipboard offered for approval');
  }

  List<Widget> _transfers() => [
    if (_items('transfers').isEmpty && _items('outbound').isEmpty)
      _empty(
        'No transfers yet',
        'Select a paired device and send a file. The receiver approves every offer.',
        Icons.folder_open,
      ),
    if (_items('outbound').isNotEmpty) _section('Sending'),
    for (final t in _items('outbound'))
      _card(
        Icons.upload_file,
        (t['path'] as String).split(RegExp(r'[/\\]')).last,
        '${_peerName(t['peer_id'] as String)} · ${t['status']}',
        [
          if (!['completed', 'cancelled'].contains(t['status']))
            _button(
              'Send / resume',
              () => _sendFile(
                t['peer_id'] as String,
                path: t['path'] as String,
                id: t['id'] as String,
              ),
              primary: true,
            ),
          if (['completed', 'cancelled'].contains(t['status']))
            _button(
              'Archive',
              () => _command({
                'op': 'archive_transfer',
                'id': t['id'],
                'outgoing': true,
              }),
            ),
        ],
        extra: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LinearProgressIndicator(
              value: (t['total'] as int) == 0
                  ? 1
                  : (t['sent'] as int) / (t['total'] as int),
            ),
            const SizedBox(height: 6),
            Text('${_bytes(t['sent'] as int)} / ${_bytes(t['total'] as int)}'),
          ],
        ),
      ),
    if (_items('transfers').isNotEmpty) _section('Receiving'),
    for (final t in _items('transfers'))
      _card(
        Icons.download_outlined,
        t['file_name'] as String,
        '${_peerName(t['peer_id'] as String)} · ${t['status']}',
        [
          if (t['status'] == 'pending')
            _button(
              'Accept',
              () => _command({'op': 'file_accept', 'id': t['id']}),
              primary: true,
            ),
          if (t['status'] == 'receiving')
            _button(
              'Allow resume',
              () => _command({'op': 'file_resume', 'id': t['id']}),
            ),
          if (['pending', 'receiving'].contains(t['status']))
            _button(
              'Cancel',
              () => _command({'op': 'file_cancel', 'id': t['id']}),
            ),
          if (t['status'] == 'completed')
            _button(
              _android != null ? 'Save to device' : 'Copy saved path',
              () async {
                if (_android != null) {
                  if (await _android!.saveFile(
                    t['id'] as String,
                    t['file_name'] as String,
                  )) {
                    _notice('File saved');
                  }
                  return;
                }
                await Clipboard.setData(
                  ClipboardData(
                    text:
                        '${_directory.text}/downloads/${t['id']}/${t['file_name']}',
                  ),
                );
                _notice('Saved path copied');
              },
            ),
          if (['completed', 'cancelled'].contains(t['status']))
            _button(
              'Archive',
              () => _command({
                'op': 'archive_transfer',
                'id': t['id'],
                'outgoing': false,
              }),
            ),
        ],
        extra: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LinearProgressIndicator(
              value: (t['file_size'] as int) == 0
                  ? (t['status'] == 'completed' ? 1 : 0)
                  : (t['received'] as int) / (t['file_size'] as int),
            ),
            const SizedBox(height: 6),
            Text(
              '${_bytes(t['received'] as int)} / ${_bytes(t['file_size'] as int)}',
            ),
          ],
        ),
      ),
  ];

  List<Widget> _audioPage() => [
    Card(
      child: SwitchListTile(
        title: const Text('Enable audio on this device'),
        subtitle: const Text(
          'Audio sessions require approval. Microphone capture starts after the other device accepts.',
        ),
        value: _audio?.enabled ?? false,
        onChanged: _busy
            ? null
            : (value) => _run(() async {
                await _audio!.setEnabled(value);
                if (mounted) setState(() {});
              }),
      ),
    ),
    if (_audio?.enabled == true) ...[
      _section('Send microphone audio'),
      if (_paired.isEmpty)
        _empty(
          'Pair a device first',
          'Your paired devices will appear here.',
          Icons.link,
        ),
      for (final record in _paired.values)
        _card(
          Icons.mic_none,
          (record as Map)['peer']['device_name'] as String,
          'Play your microphone through this device’s speakers.',
          [
            _button('Request audio', () async {
              await _audio!.start(record['peer']['device_id'] as String);
              _notice('Audio requested. Waiting for approval.');
            }, primary: true),
          ],
        ),
    ],
    _section('Audio sessions'),
    for (final s in _items('sessions').where(
      (s) =>
          s['capability'] == 'audio.output' &&
          !['closed', 'denied', 'failed'].contains(s['state']),
    ))
      _card(
        Icons.graphic_eq,
        _peerName(s['peer_id'] as String),
        '${s['state']}',
        [
          _button('Stop audio', () async {
            if (_audio!.links.containsKey(s['id'])) {
              await _audio!.stop(s['id'] as String);
            } else {
              await _command({
                'op': 'session_stop',
                'id': s['id'],
                'peer_id': s['peer_id'],
              });
            }
          }),
        ],
      ),
  ];

  List<Widget> _activity() => [
    _card(
      Icons.lan_outlined,
      'Connection',
      'Control TLS :${_data['device']['port']} · file TLS :${(_data['device']['port'] as int) + 1}',
      [],
      extra: SelectableText(
        'Device ${_short(_data['device']['device_id'] as String)}\nAddress ${_data['device']['address']}\nProtocol v${_data['device']['protocol_version']}\n${_paired.length} paired devices\nPrivate keys and clipboard contents stay out of the activity log.',
      ),
    ),
    _section('Recent activity'),
    for (final e in _items('events'))
      _card(
        Icons.history,
        (e['type'] as String).replaceAll('.', ' · '),
        DateTime.fromMillisecondsSinceEpoch(
          (e['timestamp'] as int) * 1000,
        ).toLocal().toString().split('.').first,
        [],
        extra: Text(
          jsonEncode(e['detail']),
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
        ),
      ),
  ];
}
