import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'api.dart';
import 'app_settings.dart';
import 'audio.dart';
import 'clipboard_sync.dart';
import 'meeting_page.dart';
import 'system_audio_page.dart';
import 'desktop_audio_routes.dart';
import 'camera_card.dart';
import 'find_device.dart';
import 'android_backend.dart';
import 'ios_backend.dart';
import 'device_widget_action.dart';
import 'device_actions_page.dart';
import 'phone_page.dart';
import 'phone_sync.dart';
import 'windows_backend.dart';
import 'desktop_integration.dart';
import 'pairing_scanner.dart';

void main() => runApp(const NaradApp());

class NaradApp extends StatefulWidget {
  const NaradApp({super.key, this.api, this.preferences});
  final NaradApi? api;
  final ThemePreferences? preferences;
  @override
  State<NaradApp> createState() => _NaradAppState();
}

class _NaradAppState extends State<NaradApp> {
  ThemeMode _mode = ThemeMode.system;
  late final ThemePreferences _preferences =
      widget.preferences ??
      (widget.api == null
          ? DeviceThemePreferences()
          : MemoryThemePreferences());
  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final mode = await _preferences.read();
      if (mounted) setState(() => _mode = mode);
    } catch (_) {
      /* Device theme remains the default if preferences are unavailable. */
    }
  }

  Future<void> _change(ThemeMode mode) async {
    await _preferences.write(mode);
    if (mounted) setState(() => _mode = mode);
  }

  ThemeData _theme(Brightness brightness) {
    final colors = ColorScheme.fromSeed(
      seedColor: const Color(0xff286458),
      brightness: brightness,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: colors,
      scaffoldBackgroundColor: colors.surface,
      cardTheme: CardThemeData(
        elevation: 0,
        color: colors.surfaceContainerLow,
        margin: const EdgeInsets.only(bottom: 12),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AppSettingsScope(
    mode: _mode,
    change: _change,
    child: MaterialApp(
      title: 'Narad',
      debugShowCheckedModeBanner: false,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      themeMode: _mode,
      home: Dashboard(api: widget.api),
    ),
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
  WindowsBackend? _windows;
  DesktopIntegration? _desktop;
  PhoneSync? _phoneSync;
  ClipboardSync? _clipboardSync;
  bool? _autostart;
  bool _starting = false;
  bool _widgetDispatching = false;
  FindDeviceController? _finder;
  bool _foreground = true;
  bool _restoredMedia = false;
  NaradApi? _api;
  AudioController? _audio;
  Map<String, dynamic> _data = {};
  Timer? _timer;
  bool _online = false, _busy = false, _refreshing = false;
  String? _error;
  int _page = 0;
  int _connectionGeneration = 0;
  static const _titles = ['Devices', 'Media', 'Activity', 'Settings'];
  final _status = ValueNotifier<Map<String, dynamic>>({});
  static const _icons = [
    Icons.devices_rounded,
    Icons.perm_media_outlined,
    Icons.monitor_heart_outlined,
    Icons.settings_outlined,
  ];

  void _openTab(int index) {
    Navigator.of(context).popUntil((route) => route.isFirst);
    if (mounted) setState(() => _page = index);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _directory = TextEditingController(
      text: Platform.environment['NARAD_STATE'] ?? '../../.narad',
    );
    if (widget.api == null && (Platform.isLinux || Platform.isWindows)) {
      _desktop = DesktopIntegration();
      _desktop!.onPrepareQuit(_shutdown);
      unawaited(
        _desktop!
            .autostart()
            .then((enabled) {
              if (mounted) setState(() => _autostart = enabled);
            })
            .catchError((Object e) {
              _showError(e);
            }),
      );
    }
    if (widget.api != null) {
      _attach(widget.api!);
    } else if (Platform.isAndroid || Platform.isIOS) {
      _android = Platform.isIOS ? IosBackend() : AndroidBackend();
      unawaited(_startAndroid());
    } else if (Platform.isWindows) {
      _windows = WindowsBackend();
      unawaited(_startWindows());
    } else {
      unawaited(_autoConnect());
    }
  }

  Future<void>? _quitting;
  Future<void> _shutdown() => _quitting ??= _shutdownNow();
  Future<void> _shutdownNow() async {
    _timer?.cancel();
    try {
      await _finder?.stop();
    } finally {
      try {
        await _audio?.dispose().timeout(const Duration(seconds: 6));
      } finally {
        try {
          await LinuxAudioRoutes.disposeAll();
        } finally {
          await _desktop?.quit();
        }
      }
    }
  }

  Future<void> _startWindows() async {
    if (_starting) return;
    setState(() => _starting = true);
    try {
      final api = await _windows!.start();
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
      // Android keeps the process-owned media engine and foreground service alive.
      _foreground = false;
      if (Platform.isIOS) unawaited(_finder?.stop());
      _restoredMedia = false;
      if (!Platform.isAndroid && _audio != null) {
        unawaited(
          _audio!.setCameraEnabled(false).catchError((Object e) {
            _showError(e);
          }),
        );
        unawaited(
          _audio!.setEnabled(false).catchError((Object error) {
            if (mounted) _showError(error);
          }),
        );
      }
    }
    if (state == AppLifecycleState.resumed) {
      _foreground = true;
      _restoredMedia = false;
    }
    if (state == AppLifecycleState.resumed &&
        (Platform.isIOS || !_online) &&
        !_starting) {
      unawaited(_startAndroid());
    }
  }

  Future<void> _autoConnect() async {
    if (await File('${_directory.text}/api-token').exists() && mounted) {
      _connect();
    }
  }

  void _attach(NaradApi api) {
    _phoneSync?.dispose();
    _clipboardSync?.dispose();
    if (_desktop != null) {
      _phoneSync = PhoneSync(
        api,
        _desktop!.phoneNotification,
        cancel: _desktop!.cancelPhoneNotification,
      );
      _desktop!.onNotificationAction = (id, action, reply) async {
        try {
          if (action == 'reply' && reply == null) {
            await _desktop!.show();
            if (!mounted) return;
            final text = TextEditingController();
            try {
              reply = await showDialog<String>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('Reply to notification'),
                  content: TextField(
                    controller: text,
                    maxLength: 2000,
                    autofocus: true,
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Cancel'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(context, text.text),
                      child: const Text('Send'),
                    ),
                  ],
                ),
              );
            } finally {
              text.dispose();
            }
          }
          await _phoneSync?.act(id, action, reply: reply);
        } catch (error) {
          if (mounted) _showError(error);
        }
      };
    }
    _connectionGeneration++;
    _restoredMedia = false;
    final oldFinder = _finder;
    if (oldFinder != null) unawaited(oldFinder.stop().catchError(_showError));
    _finder = Platform.isAndroid ? null : FindDeviceController(api);
    final previous = _audio;
    if (previous != null) unawaited(previous.dispose().catchError(_showError));
    _api = api;
    _clipboardSync = ClipboardSync(api);
    _audio = AudioController(api, _showError);
    unawaited(_refresh());
    _timer?.cancel();
    _timer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => unawaited(_refresh()),
    );
  }

  void _connect() {
    if (_windows != null) {
      unawaited(_startWindows());
      return;
    }
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
        for (final key in ['paired', 'permissions', 'automatic_permissions']) {
          (data[key] as Map?)?.addAll(page[key] as Map? ?? {});
        }
        more = page['has_more'] == true;
        offset += 32;
      }
      if (!mounted || generation != _connectionGeneration) return;
      setState(() {
        _data = data;
        _status.value = Map<String, dynamic>.from(data);
        _online = true;
        _error = null;
      });
      if (_phoneSync != null) unawaited(_phoneSync!.tick(data));
      if (_android != null && !_busy && !_widgetDispatching && _foreground) {
        final pending = await _android!.takeDeviceAction();
        if (pending != null && mounted) {
          _widgetDispatching = true;
          unawaited(
            _run(
              () => _dispatchWidgetAction(DeviceWidgetAction.parse(pending)),
            ).whenComplete(() => _widgetDispatching = false),
          );
        }
      }
      try {
        if (!Platform.isAndroid) {
          for (final offer
              in (data['clipboard'] as List).cast<Map<String, dynamic>>().where(
                (c) => c['status'] == 'automatic',
              )) {
            final accepted = await api.call({
              'op': 'clipboard_accept',
              'id': offer['id'],
            });
            await Clipboard.setData(
              ClipboardData(text: accepted['text'] as String),
            );
          }
        }
        if (_foreground && !_restoredMedia && audio != null) {
          _restoredMedia = true;
          final grants = (data['automatic_permissions'] as Map?) ?? {};
          if (grants.entries.any(
            (e) =>
                e.key.toString().endsWith('/audio.output') && e.value == true,
          )) {
            await audio.setEnabled(true);
          }
          if (grants.entries.any(
            (e) => e.key.toString().endsWith('/audio.input') && e.value == true,
          )) {
            await audio.setMicrophoneEnabled(true);
          }
          if (grants.entries.any(
            (e) =>
                e.key.toString().endsWith('/camera.stream') && e.value == true,
          )) {
            await audio.setCameraEnabled(true);
          }
        }
        unawaited(
          _clipboardSync?.tick(
            enabled: data['clipboard_sync'] == true,
            canRead: _foreground || !(Platform.isAndroid || Platform.isIOS),
          ),
        );
        await _finder?.poll();
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

  Future<void> _dispatchWidgetAction(DeviceWidgetAction action) async {
    final peer = action.peerFrom(_data);
    switch (action.action) {
      case 'phone':
        if (mounted) {
          await Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => PhonePage(api: _api!, peer: peer),
            ),
          );
        }
      case 'find':
        await _deviceAction(action.peerId, 'find');
      case 'file':
        await _sendFile(action.peerId);
      case 'clipboard':
        await _sendClipboard(action.peerId);
      case 'audio':
        await _audio!.start(action.peerId);
        if (mounted) _openTab(1);
      case 'microphone':
        await _audio!.requestMicrophone(action.peerId);
        if (mounted) _openTab(1);
      case 'camera':
        await _viewCamera(action.peerId);
      case 'browse':
        await _browseFiles(peer);
      case 'command':
        await _runCommand(peer);
      case 'lock':
        await _deviceAction(action.peerId, 'lock');
      case 'unlock':
        await _deviceAction(action.peerId, 'unlock');
      case 'settings':
        await _permissions(peer);
      case 'unpair':
        await _unpair(peer);
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
    if (_finder != null) unawaited(_finder!.stop());
    if (_audio != null) unawaited(_audio!.dispose());
    _phoneSync?.dispose();
    _clipboardSync?.dispose();
    _status.dispose();
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
            IconButton(
              tooltip: 'Settings',
              icon: const Icon(Icons.settings_outlined),
              onPressed: () => _openTab(3),
            ),
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
                    icon: _navigationIcon(i),
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
                                  if (_finder?.ringing == true)
                                    Card(
                                      child: ListTile(
                                        leading: const Icon(
                                          Icons.notifications_active,
                                        ),
                                        title: const Text(
                                          'A paired device is finding this device',
                                        ),
                                        trailing: TextButton(
                                          onPressed: () => _run(() async {
                                            await _finder!.stop();
                                          }),
                                          child: const Text('Stop ringing'),
                                        ),
                                      ),
                                    ),
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
                                        ?.copyWith(
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.onSurfaceVariant,
                                        ),
                                  ),
                                  const SizedBox(height: 24),
                                  ...switch (_page) {
                                    0 => [
                                      if (_hasRequests) ...[
                                        _section('Requests'),
                                        ..._inbox(),
                                      ],
                                      ..._devices(),
                                    ],
                                    1 => _audioPage(),
                                    2 => [
                                      _section('File transfers'),
                                      ..._transfers(),
                                      ..._activity(),
                                    ],
                                    _ => _settingsContent(context),
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
                    icon: _navigationIcon(i),
                    label: _titles[i],
                  ),
                ),
              )
            : null,
      );
    },
  );

  Widget _navigationIcon(int index) {
    final count = _items(
      'pairings',
    ).where((p) => p['outgoing'] != true && p['status'] == 'pending').length;
    return index == 0 && count > 0
        ? Badge.count(count: count, child: Icon(_icons[index]))
        : Icon(_icons[index]);
  }

  String _time(int seconds) {
    final date = DateTime.fromMillisecondsSinceEpoch(seconds * 1000).toLocal();
    return '${date.day}/${date.month} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
  }

  List<Widget> _settingsContent(BuildContext context) {
    final settings = AppSettingsScope.of(context);
    return [
      _section('Clipboard'),
      SwitchListTile(
        title: const Text('Automatic clipboard sync'),
        subtitle: const Text(
          'Send newly copied text to online devices that enabled sync and gave this device clipboard permission. Android and iOS can read the clipboard only while Narad is in the foreground.',
        ),
        value: _data['clipboard_sync'] == true,
        onChanged: (enabled) =>
            _run(() => _command({'op': 'clipboard_sync', 'enabled': enabled})),
      ),
      Text('Appearance', style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 12),
      SegmentedButton<ThemeMode>(
        segments: const [
          ButtonSegment(
            value: ThemeMode.system,
            icon: Icon(Icons.brightness_auto),
            label: Text('Device'),
          ),
          ButtonSegment(
            value: ThemeMode.light,
            icon: Icon(Icons.light_mode_outlined),
            label: Text('Light'),
          ),
          ButtonSegment(
            value: ThemeMode.dark,
            icon: Icon(Icons.dark_mode_outlined),
            label: Text('Dark'),
          ),
        ],
        selected: {settings.mode},
        onSelectionChanged: (m) async {
          try {
            await settings.change(m.single);
          } catch (e) {
            _showError(e);
          }
        },
      ),
      const Padding(
        padding: EdgeInsets.only(top: 12, bottom: 24),
        child: Text(
          'Device follows your system appearance. Your choice is saved on this device.',
        ),
      ),
      if (_desktop != null) ...[
        _section('Background operation'),
        const Text(
          'Closing the window keeps Narad connected in the background. Reopen it from the application menu or tray. Use Quit Narad to stop it.',
        ),
        SwitchListTile(
          title: const Text('Start after login'),
          subtitle: const Text('Run quietly after reboot when you sign in'),
          value: _autostart ?? false,
          onChanged: _autostart == null
              ? null
              : (enabled) async {
                  try {
                    await _desktop!.setAutostart(enabled);
                    if (mounted) setState(() => _autostart = enabled);
                    if (mounted) setState(() {});
                  } catch (e) {
                    _showError(e);
                  }
                },
        ),
        _button('Quit Narad', _shutdown),
      ],
      if (_android != null) ...[
        _section('Phone integration'),
        ListTile(
          leading: const Icon(Icons.smartphone),
          title: const Text('Notifications, SMS and calls'),
          subtitle: Text(
            Platform.isIOS
                ? 'View Android phone data; learn about iOS source limitations'
                : 'Choose Android access and optional default-dialer role',
          ),
          onTap: () => _android!.phoneSetup(),
        ),
        if (!Platform.isIOS) _section('Home-screen device actions'),
        if (!Platform.isIOS)
          const Text(
            'Long-press your Android home screen, choose Widgets → Narad Devices, then select a paired device. Its actions appear as a scrollable list. Each action uses the same permissions and pickers as the app.',
          ),
      ],
      if (_online) ...[
        if (!Platform.isIOS) ...[
          _section('Command presets'),
          const Text(
            'Devices with command permission can run only the presets configured here. Commands run as your user on Linux/Windows and inside Narad’s app sandbox on Android.',
          ),
          for (final raw in (_data['commands'] as List? ?? []))
            ListTile(
              title: Text(raw['label'] as String),
              subtitle: const Text('Available to permitted devices'),
              trailing: IconButton(
                tooltip: 'Remove command',
                icon: const Icon(Icons.delete_outline),
                onPressed: () async {
                  await _run(
                    () => _command({'op': 'command_remove', 'id': raw['id']}),
                  );
                  if (context.mounted) if (mounted) setState(() {});
                },
              ),
            ),
          _button('Add command preset', () async {
            await _addCommand();
            if (mounted) setState(() {});
          }),
        ],
        _section('Connection details'),
        SelectableText(
          'This device: ${_data['device']['device_name']}\nLocal address: ${_data['device']['address']}\n${_paired.length} paired devices',
        ),
      ],
    ];
  }

  Future<void> _addCommand() async {
    final label = await _input(
      'Command name',
      'A recognizable name, for example “Disk space”',
    );
    if (label == null) return;
    final script = await _input(
      'Command preset',
      'Shell command to run on this device',
      multiline: true,
    );
    if (script == null) return;
    await _command({'op': 'command_set', 'label': label, 'script': script});
    await _refresh();
    _notice('Command preset saved. Grant access in Device settings.');
  }

  Future<void> _shareDirectory({String? peerId}) async {
    String? path, label;
    final native = Platform.isAndroid || Platform.isIOS;
    if (native) {
      final selected = await MethodChannel(
        Platform.isIOS ? 'dev.narad/ios' : 'dev.narad/android',
      ).invokeMapMethod<String, dynamic>('chooseSharedDirectory');
      if (selected == null) return;
      path = selected['path'] as String;
      label = selected['label'] as String;
    } else {
      path = await FilePicker.getDirectoryPath(
        dialogTitle: 'Choose a folder to share',
      );
      if (path == null) return;
      label =
          path
              .split(Platform.pathSeparator)
              .where((p) => p.isNotEmpty)
              .lastOrNull ??
          'Shared folder';
    }
    await _command({
      'op': 'share_add',
      'peer_id': peerId,
      'path': path,
      'label': label,
      'documents': native,
      'upload': false,
    });
    _notice(
      peerId == null
          ? 'Folder added. Choose which devices can access it.'
          : 'Folder shared with ${_peerName(peerId)}. Device browse permission is also required.',
    );
  }

  Future<void> _addSharedFile() async {
    final entry = await FilePicker.pickFile();
    if (entry == null) return;
    final name = entry.name;
    if (name.isEmpty ||
        name.contains('/') ||
        name.contains('\\') ||
        name.contains('\u0000') ||
        name == '.' ||
        name == '..') {
      throw StateError('Invalid file name');
    }
    final root = Directory(_data['shared_directory'] as String);
    await root.create(recursive: true);
    var target = File('${root.path}/$name');
    if (await target.exists()) {
      target = File(
        '${root.path}/${DateTime.now().millisecondsSinceEpoch}-$name',
      );
    }
    await File(entry.path!).copy(target.path);
    _notice('Added to Shared folder');
  }

  Future<void> _localSharedFiles() async {
    final root = Directory(_data['shared_directory'] as String);
    await root.create(recursive: true);
    final names = await root
        .list()
        .map((f) => f.path.split(Platform.pathSeparator).last)
        .toList();
    names.sort();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Shared folder'),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Text(
              names.isEmpty
                  ? 'No shared files yet. Add a file to make it available.'
                  : names.join('\n'),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }

  Future<void> _runCommand(Map<String, dynamic> peer) async {
    final response = await _api!.call({
      'op': 'list_commands',
      'peer_id': peer['device_id'],
    });
    final commands = (response['commands'] as List)
        .cast<Map<String, dynamic>>();
    if (!mounted) return;
    final chosen = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text('Commands · ${peer['device_name']}'),
        children: [
          if (commands.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text('No command presets configured on that device.'),
            ),
          for (final command in commands)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, command),
              child: Text(command['label'] as String),
            ),
        ],
      ),
    );
    if (chosen == null) return;
    final result = await _api!.call({
      'op': 'run_command',
      'peer_id': peer['device_id'],
      'id': chosen['id'],
    });
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(chosen['label'] as String),
        content: SizedBox(
          width: 600,
          child: SingleChildScrollView(
            child: SelectableText(
              'Exit code: ${result['exit_code']}\n\n${result['stdout']}${result['stderr']}\n${result['truncated'] == true ? 'Output shortened.' : ''}',
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }

  Future<void> _deviceAction(String peer, String kind) async {
    var result = await _api!.call({
      'op': 'device_action',
      'peer_id': peer,
      'kind': kind,
    });
    final id = result['id'];
    if (id != null) {
      for (
        var attempt = 0;
        attempt < 8 && ['pending', 'dispatched'].contains(result['status']);
        attempt++
      ) {
        await Future<void>.delayed(const Duration(seconds: 2));
        result = await _api!.call({
          'op': 'device_action_status',
          'peer_id': peer,
          'id': id,
        });
      }
      if (result['status'] == 'failed') {
        throw StateError(result['message'] as String);
      }
      _notice(
        (result['message'] as String?)?.isNotEmpty == true
            ? result['message'] as String
            : 'Device request sent',
      );
    } else {
      if (result['exit_code'] != 0) {
        throw StateError(
          result['stderr'] as String? ?? 'Device control unavailable',
        );
      }
      _notice(
        kind == 'lock'
            ? 'Lock request sent'
            : 'Unlock requested. The device may require authentication.',
      );
    }
  }

  Future<void> _viewCamera(String peer, {bool withAudio = false}) async {
    await _audio!.startCamera(peer, withAudio: withAudio);
    if (mounted) _openTab(1);
    _notice(
      withAudio
          ? 'Camera and microphone requested. Enable both on the source device and grant microphone permission.'
          : 'Camera requested. The other app must have camera sharing enabled.',
    );
  }

  Future<void> _browseFiles(Map<String, dynamic> peer) async {
    var path = '';
    var labels = <String>[];
    var result = await _api!.call({
      'op': 'browse_peer',
      'peer_id': peer['device_id'],
      'path': path,
    });
    var downloading = false;
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text('Shared files · ${peer['device_name']}'),
          content: SizedBox(
            width: 600,
            height: 420,
            child: Column(
              children: [
                Row(
                  children: [
                    IconButton(
                      tooltip: 'Parent folder',
                      onPressed: path.isEmpty || downloading
                          ? null
                          : () async {
                              final parts = path.split('/')..removeLast();
                              final parent = parts.join('/');
                              try {
                                final next = await _api!.call({
                                  'op': 'browse_peer',
                                  'peer_id': peer['device_id'],
                                  'path': parent,
                                });
                                if (context.mounted) {
                                  update(() {
                                    path = parent;
                                    labels = labels
                                        .take(labels.length - 1)
                                        .toList();
                                    result = next;
                                  });
                                }
                              } catch (e) {
                                _showError(e);
                              }
                            },
                      icon: const Icon(Icons.arrow_upward),
                    ),
                    Expanded(
                      child: Text(
                        labels.isEmpty ? 'Shared folders' : labels.join(' / '),
                      ),
                    ),
                    IconButton(
                      tooltip: result['upload'] == true
                          ? 'Upload here'
                          : 'Upload permission required',
                      icon: const Icon(Icons.upload_file_outlined),
                      onPressed: downloading || result['upload'] != true
                          ? null
                          : () async {
                              final file = await FilePicker.pickFile();
                              if (file?.path == null || !context.mounted) {
                                return;
                              }
                              update(() => downloading = true);
                              try {
                                await _api!.call({
                                  'op': 'upload_shared',
                                  'peer_id': peer['device_id'],
                                  'path': path,
                                  'source': file!.path,
                                });
                                final next = await _api!.call({
                                  'op': 'browse_peer',
                                  'peer_id': peer['device_id'],
                                  'path': path,
                                });
                                if (context.mounted) {
                                  update(() => result = next);
                                }
                                _notice('File uploaded');
                              } catch (e) {
                                _showError(e);
                              } finally {
                                if (context.mounted) {
                                  update(() => downloading = false);
                                }
                              }
                            },
                    ),
                  ],
                ),
                if (downloading) const LinearProgressIndicator(),
                Expanded(
                  child: ListView(
                    children: [
                      if (result['truncated'] == true)
                        const ListTile(
                          title: Text(
                            'Showing the first files in this large folder.',
                          ),
                        ),
                      if ((result['entries'] as List).isEmpty)
                        const ListTile(title: Text('This folder is empty')),
                      for (final entry in result['entries'] as List)
                        ListTile(
                          leading: Icon(
                            entry['directory'] == true
                                ? Icons.folder_outlined
                                : Icons.insert_drive_file_outlined,
                          ),
                          title: Text(entry['name'] as String),
                          subtitle: entry['directory'] == true
                              ? null
                              : Text(_bytes(entry['size'] as int)),
                          trailing: entry['directory'] == true
                              ? const Icon(Icons.chevron_right)
                              : const Icon(Icons.download),
                          onTap: downloading
                              ? null
                              : () async {
                                  try {
                                    if (entry['directory'] == true) {
                                      final next = await _api!.call({
                                        'op': 'browse_peer',
                                        'peer_id': peer['device_id'],
                                        'path': entry['path'],
                                      });
                                      if (context.mounted) {
                                        update(() {
                                          path = entry['path'] as String;
                                          labels = [
                                            ...labels,
                                            entry['name'] as String,
                                          ];
                                          result = next;
                                        });
                                      }
                                    } else {
                                      update(() => downloading = true);
                                      final download = await _api!.call({
                                        'op': 'download_shared',
                                        'peer_id': peer['device_id'],
                                        'path': entry['path'],
                                      });
                                      if (_android != null) {
                                        await _android!.saveFile(
                                          download['id'] as String,
                                          download['name'] as String,
                                        );
                                      } else {
                                        _notice(
                                          'Downloaded to ${download['path']}',
                                        );
                                      }
                                      await _refresh();
                                    }
                                  } catch (e) {
                                    _showError(e);
                                  } finally {
                                    if (context.mounted) {
                                      update(() => downloading = false);
                                    }
                                  }
                                },
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: downloading ? null : () => Navigator.pop(context),
              child: const Text('Done'),
            ),
          ],
        ),
      ),
    );
  }

  String _subtitle() => switch (_page) {
    0 =>
      'Your nearby, paired and available devices. Review connection requests here.',
    1 => 'Cameras, sound and shared folders across your devices.',
    2 => 'Transfers and recent activity, grouped for easy review.',
    _ => 'Appearance, clipboard sync and preferences for this device.',
  };

  bool get _hasRequests =>
      _items('pairings').any(
        (p) =>
            p['status'] == 'pending' ||
            (p['nearby'] == true && p['status'] == 'denied'),
      ) ||
      _items('transfers').any((t) => t['status'] == 'pending') ||
      _items('clipboard').isNotEmpty ||
      _items('sessions').any(
        (m) =>
            m['state'] == 'requested' &&
            !(_audio?.links[m['id']]?.outgoing ?? false),
      );

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
          Icon(icon, size: 36, color: Theme.of(context).colorScheme.outline),
          const SizedBox(height: 12),
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(
            detail,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
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
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
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
    bool enabled = true,
    bool showProgress = true,
  }) => primary
      ? FilledButton(
          onPressed: _busy || !enabled
              ? null
              : () => showProgress
                    ? _run(action)
                    : action().catchError(_showError),
          child: Text(text),
        )
      : OutlinedButton(
          onPressed: _busy || !enabled
              ? null
              : () => showProgress
                    ? _run(action)
                    : action().catchError(_showError),
          child: Text(text),
        );

  bool _isOnline(String id) =>
      (_data['presence'] as Map?)?[id]?['online'] == true;
  String _presenceText(String id) {
    final presence = (_data['presence'] as Map?)?[id] as Map?;
    if (presence == null) return 'Checking connection';
    if (presence['online'] == true) return 'Online';
    final seen = presence['last_seen'] as int?;
    return seen == null ? 'Offline' : 'Offline · Last seen ${_time(seen)}';
  }

  List<Map<String, dynamic>> get _pairedPeers =>
      _paired.values
          .map((r) => (r as Map)['peer'] as Map<String, dynamic>)
          .toList()
        ..sort(
          (a, b) => (a['device_name'] as String).toLowerCase().compareTo(
            (b['device_name'] as String).toLowerCase(),
          ),
        );
  List<Widget> _devices() => [
    Card(
      child: ExpansionTile(
        leading: const Icon(Icons.hub_rounded),
        title: Text(_data['device']['device_name'] as String),
        subtitle: const Text('This device'),
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _button('Create invitation', _invitation),
                _button('Enter invitation', _enterInvitation),
                if (_android != null)
                  _button('Scan invitation', _scanInvitation),
                if (_android != null) _button('Rename device', _renameDevice),
              ],
            ),
          ),
        ],
      ),
    ),
    _section('Nearby devices'),
    if (_items(
      'discovered',
    ).where((p) => !_paired.containsKey(p['device_id'])).isEmpty)
      _empty(
        'Looking on your local network',
        'Open Narad on both devices using the same Wi-Fi. Invitations also work when discovery is unavailable.',
        Icons.radar,
      ),
    for (final peer in _items('discovered'))
      if (!_paired.containsKey(peer['device_id']))
        _card(
          Icons.devices_other,
          peer['device_name'] as String,
          '${peer['platform']} · Ready to pair',
          [
            if (_items('pairings').any(
              (p) =>
                  p['outgoing'] == true &&
                  p['nearby'] == true &&
                  p['status'] == 'pending' &&
                  p['peer']['device_id'] == peer['device_id'],
            ))
              const OutlinedButton(onPressed: null, child: Text('Request sent'))
            else
              _button(
                'Send pairing request',
                () => _requestPairing(peer),
                primary: true,
              ),
          ],
        ),
    _section('Paired devices'),
    if (_paired.isEmpty)
      _empty(
        'No paired devices yet',
        'Send a pairing request to a nearby device, or use an invitation.',
        Icons.link,
      ),
    if (_paired.isNotEmpty) ...[
      _section(
        'Online (${_pairedPeers.where((p) => _isOnline(p['device_id'] as String)).length})',
      ),
      if (!_pairedPeers.any((p) => _isOnline(p['device_id'] as String)))
        const Padding(
          padding: EdgeInsets.only(bottom: 12),
          child: Text('No paired devices online'),
        ),
      for (final peer in _pairedPeers.where(
        (p) => _isOnline(p['device_id'] as String),
      ))
        _pairedCard(peer),
      ExpansionTile(
        key: const PageStorageKey('offline-devices'),
        tilePadding: EdgeInsets.zero,
        title: Text(
          'Offline (${_pairedPeers.where((p) => !_isOnline(p['device_id'] as String)).length})',
        ),
        children: [
          if (_pairedPeers.every((p) => _isOnline(p['device_id'] as String)))
            const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: Text('No paired devices offline'),
            ),
          for (final peer in _pairedPeers.where(
            (p) => !_isOnline(p['device_id'] as String),
          ))
            _pairedCard(peer),
        ],
      ),
    ],
  ];
  Map<String, (IconData, Future<void> Function())> _deviceActions(
    Map<String, dynamic> peer,
  ) {
    final id = peer['device_id'] as String;
    final actions = <String, (IconData, Future<void> Function())>{
      'Find device': (
        Icons.notifications_active_outlined,
        () => _deviceAction(id, 'find'),
      ),
      'Stop ringing': (
        Icons.notifications_off_outlined,
        () => _deviceAction(id, 'find_stop'),
      ),
      'Send file': (Icons.upload_file, () => _sendFile(id)),
      'Send clipboard': (Icons.content_paste, () => _sendClipboard(id)),
      'Send audio': (
        Icons.mic_outlined,
        () async {
          await _audio!.start(id);
          if (mounted) _openTab(1);
        },
      ),
      'Use microphone': (
        Icons.mic_external_on_outlined,
        () async {
          await _audio!.requestMicrophone(id);
          if (mounted) _openTab(1);
        },
      ),
      if (Platform.isLinux || Platform.isWindows)
        'Send laptop audio': (
          Icons.speaker_outlined,
          () async {
            await Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => SystemAudioPage(
                  audio: _audio!,
                  peer: id,
                  name: peer['device_name'] as String,
                ),
              ),
            );
          },
        ),
      if (Platform.isLinux || Platform.isWindows)
        'Use for meeting': (
          Icons.video_call_outlined,
          () async {
            await Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => MeetingPage(
                  audio: _audio!,
                  peer: id,
                  name: peer['device_name'] as String,
                ),
              ),
            );
          },
        ),
      'View camera': (Icons.videocam_outlined, () => _viewCamera(id)),
      if (peer['platform'] == 'android' || peer['platform'] == 'ios')
        'Phone companion': (
          Icons.smartphone,
          () async {
            if (mounted) {
              await Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => PhonePage(api: _api!, peer: peer),
                ),
              );
            }
          },
        ),
      'Browse files': (Icons.folder_open, () => _browseFiles(peer)),
      if (peer['platform'] != 'ios')
        'Run command': (Icons.terminal, () => _runCommand(peer)),
      if (peer['platform'] != 'ios')
        'Lock': (Icons.lock_outline, () => _deviceAction(id, 'lock')),
      if (peer['platform'] != 'windows' && peer['platform'] != 'ios')
        'Request unlock': (Icons.lock_open, () => _deviceAction(id, 'unlock')),
      'Unpair': (Icons.link_off, () => _unpair(peer)),
    };
    return actions;
  }

  Widget _pairedCard(Map<String, dynamic> peer) {
    final id = peer['device_id'] as String;
    final online = _isOnline(id);
    return Card(
      child: ListTile(
        key: ValueKey('device-$id'),
        leading: Icon(
          online ? Icons.check_circle_outline : Icons.cloud_off_outlined,
        ),
        title: Text(peer['device_name'] as String),
        subtitle: Text('${peer['platform']} · ${_presenceText(id)}'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => DeviceActionsPage(
              peerId: id,
              name: peer['device_name'] as String,
              status: _status,
              settings: () => _permissions(peer).catchError(_showError),
              actions: [
                for (final entry in _deviceActions(peer).entries)
                  DeviceAction(
                    entry.key,
                    entry.value.$1,
                    () => _run(entry.value.$2),
                    requiresOnline: entry.key != 'Unpair',
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _requestPairing(Map<String, dynamic> peer) async {
    await _api!.call({'op': 'pair_nearby', 'peer': peer});
    if (!mounted) return;
    _openTab(0);
    _notice(
      'Request sent to ${peer['device_name']}. Accept it on their Devices tab to connect.',
    );
  }

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
                  backgroundColor: Colors.white,
                  size: 240,
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
    if (mounted) _openTab(0);
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

  List<String> _folderDeviceIds(String id) {
    if (id == 'default') {
      return (_data['default_share_devices'] as List? ?? []).cast<String>();
    }
    final folders = (_data['shared_folders'] as List? ?? []).cast<Map>();
    final folder = folders.where((f) => f['id'] == id).firstOrNull;
    return (folder?['devices'] as List? ?? []).cast<String>();
  }

  String _folderAudience(Map folder) {
    final names = _folderDeviceIds(
      folder['id'] as String,
    ).where(_paired.containsKey).map(_peerName).toList();
    return names.isEmpty
        ? 'Not shared with any device'
        : 'Shared with ${names.join(', ')}';
  }

  Widget _folderAccessTile(
    String id,
    String label,
    Map peer,
    BuildContext dialogContext,
    StateSetter update,
  ) => CheckboxListTile(
    title: Text(label),
    value: _folderDeviceIds(id).contains(peer['device_id']),
    onChanged: (allow) => _run(() async {
      await _command({
        'op': 'share_access',
        'id': id,
        'peer_id': peer['device_id'],
        'allow': allow == true,
      });
      await _refresh();
      if (dialogContext.mounted) update(() {});
    }),
  );

  Future<void> _folderDevices(String id, String label) async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, update) => AlertDialog(
          title: Text('Share $label with'),
          scrollable: true,
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Only selected devices can browse this folder. Each device also needs shared-folder permission.',
                ),
                if (_pairedPeers.isEmpty) const Text('Pair a device first.'),
                for (final peer in _pairedPeers)
                  _folderAccessTile(
                    id,
                    peer['device_name'] as String,
                    peer,
                    dialogContext,
                    update,
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Done'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _permissions(Map<String, dynamic> peer) async {
    if (!mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          appBar: AppBar(title: const Text('Device settings')),
          body: StatefulBuilder(
            builder: (context, update) => SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Card(
                    child: ListTile(
                      leading: const CircleAvatar(
                        child: Icon(Icons.devices_outlined),
                      ),
                      title: Text(peer['device_name'] as String),
                      subtitle: Text('${peer['platform']} · Paired device'),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
                    child: Text(
                      'Permissions',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.fromLTRB(4, 0, 4, 8),
                    child: Text(
                      'Choose what this device can do. These grants are remembered, so approved actions do not need another prompt.',
                    ),
                  ),
                  for (final entry in {
                    if (_data['device']['platform'] == 'android') ...{
                      'contacts.read': 'Share contacts',
                      'notification.read': 'Share phone notifications',
                      'notification.manage': 'Dismiss phone notifications',
                      'notification.reply': 'Reply to phone notifications',
                      'notification.action':
                          'Use phone notification action buttons',
                      'sms.read': 'Read SMS messages',
                      'sms.send': 'Send SMS through this phone',
                      'calls.read': 'Read call history and live call state',
                      'calls.control': 'Place, answer and end calls',
                    },
                    if (_data['device']['platform'] == 'ios') ...{
                      'contacts.read': 'Share permitted iPhone contacts',
                      'sms.send': 'Open SMS composer here (confirm on iPhone)',
                      'calls.control':
                          'Open call requests here (confirm on iPhone)',
                    },
                    'device.find': 'Ring this device (Find device)',
                    'file.transfer': 'Receive files automatically',
                    'clipboard.sync': 'Apply shared clipboard automatically',
                    'audio.output': 'Play shared audio',
                    'audio.input': 'Share this device’s microphone',
                    'camera.stream': 'Share this device’s camera',
                    'file.browse': 'Browse and download shared folders',
                    'file.upload': 'Upload files into shared folders',
                    if (_data['device']['platform'] != 'ios')
                      'command.run': 'Run configured command presets',
                    if (_data['device']['platform'] != 'ios')
                      'device.lock': 'Lock this device',
                    if (_data['device']['platform'] != 'windows' &&
                        _data['device']['platform'] != 'ios')
                      'device.unlock':
                          'Request unlock (device authentication required)',
                  }.entries)
                    Card(
                      child: SwitchListTile(
                        title: Text(entry.value),
                        value:
                            ((_data['automatic_permissions']
                                        as Map?)?['${peer['device_id']}/${entry.key}'] ??
                                    false)
                                as bool,
                        onChanged: (allow) async {
                          try {
                            if (allow &&
                                entry.key == 'camera.stream' &&
                                _android != null &&
                                !await _android!.ensureCameraPermission()) {
                              _notice(
                                'Camera permission is required to share this camera.',
                              );
                              return;
                            }
                            if (allow &&
                                entry.key == 'device.lock' &&
                                _android != null &&
                                !await _android!.ensureDeviceAdmin()) {
                              _notice(
                                'Device administrator access is required to lock Android.',
                              );
                              return;
                            }
                            await _command({
                              'op': 'permission',
                              'peer_id': peer['device_id'],
                              'capability': entry.key,
                              'allow': allow,
                            });
                            if (allow && entry.key == 'audio.output') {
                              await _audio?.setEnabled(true);
                            }
                            if (allow && entry.key == 'audio.input') {
                              await _audio?.setMicrophoneEnabled(true);
                            }
                            if (allow && entry.key == 'camera.stream') {
                              await _audio?.setCameraEnabled(true);
                            }
                            await _refresh();
                            if (context.mounted) update(() {});
                          } catch (error) {
                            _showError(error);
                          }
                        },
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 24, 4, 8),
                    child: Text(
                      'Shared directories',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.fromLTRB(4, 0, 4, 8),
                    child: Text(
                      'Only directories selected below are visible to this device. File browsing and upload permissions must also be enabled above.',
                    ),
                  ),
                  _folderAccessTile(
                    'default',
                    'App Shared folder',
                    peer,
                    context,
                    update,
                  ),
                  for (final folder
                      in (_data['shared_folders'] as List? ?? []).cast<Map>())
                    _folderAccessTile(
                      folder['id'] as String,
                      folder['label'] as String,
                      peer,
                      context,
                      update,
                    ),
                  OutlinedButton.icon(
                    onPressed: () => _run(() async {
                      await _shareDirectory(
                        peerId: peer['device_id'] as String,
                      );
                      await _refresh();
                      if (context.mounted) update(() {});
                    }),
                    icon: const Icon(Icons.create_new_folder_outlined),
                    label: const Text('Share a directory with this device'),
                  ),
                ],
              ),
            ),
          ),
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
    final endedRequests = _items('pairings').where(
      (p) =>
          p['nearby'] == true &&
          p['outgoing'] == true &&
          p['status'] == 'denied',
    );
    final files = _items('transfers').where((t) => t['status'] == 'pending');
    final media = _items('sessions').where(
      (s) =>
          [
            'audio.output',
            'audio.input',
            'camera.stream',
          ].contains(s['capability']) &&
          s['state'] == 'requested' &&
          !(_audio?.links[s['id']]?.outgoing ?? false),
    );
    final clipboard = _items(
      'clipboard',
    ).where((c) => c['status'] != 'automatic');
    if (pairings.isEmpty &&
        endedRequests.isEmpty &&
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
          pair['nearby'] == true && pair['outgoing'] == true
              ? 'Waiting for acceptance on the other device. Verification code: ${pair['code']}'
              : 'Compare this code on both devices: ${pair['code']}',
          [
            if (!(pair['nearby'] == true && pair['outgoing'] == true))
              _button(
                pair['nearby'] == true
                    ? 'Accept request'
                    : pair['outgoing'] == true
                    ? 'Confirm both devices'
                    : 'Codes match · approve',
                () async {
                  if (pair['nearby'] == true ||
                      await _confirm(
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
              pair['nearby'] == true && pair['outgoing'] == true
                  ? 'Cancel request'
                  : 'Decline',
              () => _command({'op': 'pair_deny', 'id': pair['id']}),
            ),
          ],
        ),
      for (final pair in endedRequests)
        _card(
          Icons.link_off,
          'Request declined',
          '${(pair['peer'] as Map)['device_name']} declined your pairing request.',
          [],
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
          '${s['capability'] == 'camera.stream'
              ? 'Camera request'
              : s['capability'] == 'audio.input'
              ? 'Microphone request'
              : 'Audio'} from ${_peerName(s['peer_id'] as String)}',
          s['capability'] == 'camera.stream'
              ? (s['with_audio'] == true
                    ? 'Allow the requesting device to view this device’s camera and listen to its microphone?'
                    : 'Allow the requesting device to view this device’s camera?')
              : s['capability'] == 'audio.input'
              ? 'Allow the requesting device to listen to this device’s microphone?'
              : 'Allow the requesting device to play audio through this device’s speakers?',
          [
            _button(
              s['capability'] == 'camera.stream'
                  ? 'Allow camera'
                  : s['capability'] == 'audio.input'
                  ? 'Allow microphone'
                  : 'Allow audio',
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
    if (mounted) _openTab(2);
  }

  Future<void> _sendClipboard(String peer) async {
    final current = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted) return;
    final text = current?.text;
    if (text == null || text.isEmpty) {
      _notice('No text is available in the current clipboard');
      return;
    }
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
    _section('Camera'),
    SwitchListTile(
      title: const Text('Camera sharing'),
      subtitle: Text(
        Platform.isAndroid
            ? 'Enable here to allow permitted devices to use the camera in the background. A persistent notification stays visible.'
            : 'Available while this app is open, only to devices you allowed.',
      ),
      value: _audio?.cameraEnabled ?? false,
      onChanged: (value) => _run(() async {
        await _audio!.setCameraEnabled(value);
        setState(() {});
      }),
    ),
    if (!_pairedPeers.any((p) => _isOnline(p['device_id'] as String)))
      const ListTile(
        leading: Icon(Icons.videocam_off_outlined),
        title: Text('No cameras online'),
        subtitle: Text('Connect a paired device to use its camera here.'),
      ),
    for (final peer in _pairedPeers.where(
      (p) => _isOnline(p['device_id'] as String),
    ))
      _card(
        Icons.videocam_outlined,
        peer['device_name'] as String,
        'Use this device’s camera. Audio also requires its microphone permission.',
        [
          _button(
            'View camera',
            () => _viewCamera(peer['device_id'] as String),
          ),
          _button(
            'Camera with audio',
            () => _viewCamera(peer['device_id'] as String, withAudio: true),
          ),
        ],
      ),
    for (final link
        in _audio?.links.values.where((l) => l.camera) ?? <AudioLink>[])
      CameraCard(
        key: ValueKey(link.id),
        controller: _audio!,
        link: link,
        name: _peerName(link.peer),
      ),
    for (final tools in _audio?.savedCameras ?? [])
      for (final path in tools.completed.toList())
        Card(
          child: ListTile(
            title: const Text('Camera recording ready to save'),
            subtitle: const Text(
              'The camera session ended. Save or discard before closing Narad.',
            ),
            trailing: Wrap(
              children: [
                IconButton(
                  tooltip: 'Save recorded video',
                  icon: const Icon(Icons.save_alt),
                  onPressed: () => _run(() async {
                    await saveCameraRecording(tools, path);
                    if (mounted) setState(() {});
                  }),
                ),
                IconButton(
                  tooltip: 'Discard recording',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => _run(() async {
                    await tools.discard(path);
                    if (mounted) setState(() {});
                  }),
                ),
              ],
            ),
          ),
        ),

    _section('Speaker and microphone'),
    SwitchListTile(
      title: const Text('Microphone sharing'),
      subtitle: const Text(
        'Only devices with microphone permission can listen. Enable while Narad is visible before using it in the background.',
      ),
      value: _audio?.microphoneEnabled ?? false,
      onChanged: (value) => _run(() async {
        await _audio!.setMicrophoneEnabled(value);
        if (mounted) setState(() {});
      }),
    ),
    if (Platform.isAndroid || Platform.isIOS)
      SwitchListTile(
        title: const Text('Use loudspeaker'),
        value: _audio?.speakerphone ?? true,
        onChanged: (value) => _run(() async {
          await _audio!.setSpeakerphone(value);
          if (mounted) setState(() {});
        }),
      ),
    Card(
      child: SwitchListTile(
        title: const Text('Audio playback'),
        subtitle: const Text(
          'Allow permitted devices to play sound through this device. This does not enable its microphone.',
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
    if (!_pairedPeers.any((p) => _isOnline(p['device_id'] as String)))
      const ListTile(
        leading: Icon(Icons.speaker_outlined),
        title: Text('No audio devices online'),
        subtitle: Text(
          'Connect a paired device to use its speaker or microphone.',
        ),
      ),
    for (final peer in _pairedPeers.where(
      (p) => _isOnline(p['device_id'] as String),
    ))
      _card(
        Icons.speaker_outlined,
        peer['device_name'] as String,
        'Choose which microphone or speaker to use.',
        [
          _button(
            'Use microphone',
            () => _audio!
                .requestMicrophone(peer['device_id'] as String)
                .then((_) {}),
          ),
          _button(
            'Send microphone',
            () => _audio!.start(peer['device_id'] as String).then((_) {}),
          ),
          if (Platform.isLinux || Platform.isWindows)
            _button('Send laptop audio', () async {
              await Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => SystemAudioPage(
                    audio: _audio!,
                    peer: peer['device_id'] as String,
                    name: peer['device_name'] as String,
                  ),
                ),
              );
            }),
        ],
      ),
    _section('Audio sessions'),
    for (final s in _items('sessions').where(
      (s) =>
          ['audio.output', 'audio.input'].contains(s['capability']) &&
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
    _section('Shared folders'),
    const Text(
      'Choose directories, then select which paired devices can access each one. Device permissions also apply.',
    ),
    _button('Share a directory', _shareDirectory, primary: true),
    for (final folder in (_data['shared_folders'] as List? ?? []).cast<Map>())
      Card(
        child: Column(
          children: [
            ListTile(
              leading: const Icon(Icons.folder_shared_outlined),
              title: Text(folder['label'] as String),
              subtitle: Text(_folderAudience(folder)),
              onTap: () => _folderDevices(
                folder['id'] as String,
                folder['label'] as String,
              ),
              trailing: IconButton(
                tooltip: 'Stop sharing folder',
                icon: const Icon(Icons.link_off),
                onPressed: () => _run(
                  () => _command({'op': 'share_remove', 'id': folder['id']}),
                ),
              ),
            ),
            TextButton.icon(
              onPressed: () => _folderDevices(
                folder['id'] as String,
                folder['label'] as String,
              ),
              icon: const Icon(Icons.devices_outlined),
              label: const Text('Choose devices'),
            ),
            SwitchListTile(
              title: const Text('Allow uploads'),
              subtitle: const Text(
                'Devices also need upload permission. Existing files are kept.',
              ),
              value: folder['upload'] == true,
              onChanged: (enabled) => _run(
                () => _command({
                  'op': 'share_uploads',
                  'id': folder['id'],
                  'enabled': enabled,
                }),
              ),
            ),
          ],
        ),
      ),
    TextButton.icon(
      label: const Text('Choose devices for app Shared folder'),
      icon: const Icon(Icons.devices_outlined),
      onPressed: () => _folderDevices('default', 'App Shared folder'),
    ),
    _button('Add file to Shared folder', _addSharedFile),
    _button('View Shared folder', _localSharedFiles),
  ];

  String _activityCategory(String kind) {
    if (kind.startsWith('file.') || kind.startsWith('browse.')) return 'Files';
    if (kind.startsWith('clipboard.')) return 'Clipboard';
    if (kind.startsWith('media.') || kind.startsWith('camera.')) {
      return 'Audio and camera';
    }
    if (kind.startsWith('permission.')) return 'Permissions';
    if (kind.startsWith('command.')) return 'Commands';
    if (kind.startsWith('browse.')) return 'Shared files';
    if (['device.requested', 'device.completed'].contains(kind)) {
      return 'Device controls';
    }
    return 'Connections';
  }

  String _activityMessage(Map<String, dynamic> event) {
    final detail = event['detail'] as Map? ?? {};
    final peer = detail['peer_id'] is String
        ? _peerName(detail['peer_id'] as String)
        : 'Device';
    return switch (event['type']) {
      'device.online' => '$peer is online',
      'device.offline' => '$peer went offline',
      'pairing.requested' => 'Pairing request received',
      'pairing.sent' => 'Pairing request sent',
      'pairing.approved' => 'Pairing approved',
      'pairing.completed' => '$peer connected',
      'device.unpaired' => 'Device unpaired',
      'permission.changed' =>
        '${detail['capability'].toString().replaceAll('.', ' ')} ${detail['allow'] == true ? 'allowed' : 'disabled'} for $peer',
      'file.offered' => 'File transfer offered',
      'file.accepted' => 'File transfer accepted',
      'file.completed' => 'File transfer completed',
      'file.progress' =>
        'Transferring ${_bytes(detail['sent'] as int? ?? 0)} of ${_bytes(detail['total'] as int? ?? 0)}',
      'clipboard.offered' => 'Clipboard text received',
      'clipboard.accepted' => 'Clipboard accepted',
      'clipboard.applied' => 'Clipboard updated automatically',
      'clipboard.failed' => 'System clipboard update was blocked',
      'media.requested' => 'Media connection requested',
      'browse.opened' => '$peer browsed the Shared folder',
      'browse.uploaded' => 'File uploaded to a shared folder',
      'browse.downloaded' => 'Downloaded ${detail['name'] ?? 'shared file'}',
      'command.completed' => 'Command finished on this device',
      'device.requested' => '$peer requested ${detail['kind']}',
      'device.completed' => 'Device control completed',
      'daemon.started' => 'Narad started',
      'daemon.stopped' => 'Narad stopped',
      'request.rejected' => 'A request was blocked',
      _ => (event['type'] as String).replaceAll('.', ' '),
    };
  }

  List<Widget> _activity() {
    final groups = <String, List<Map<String, dynamic>>>{};
    final progress = <String>{};
    final today = DateTime.now();
    for (final event in _items('events')) {
      final kind = event['type'] as String;
      if (kind == 'file.progress' &&
          !progress.add((event['detail'] as Map)['id'].toString())) {
        continue;
      }
      final date = DateTime.fromMillisecondsSinceEpoch(
        (event['timestamp'] as int) * 1000,
      ).toLocal();
      final day = DateTime(date.year, date.month, date.day);
      final difference = DateTime(
        today.year,
        today.month,
        today.day,
      ).difference(day).inDays;
      final label = difference == 0
          ? 'Today'
          : difference == 1
          ? 'Yesterday'
          : '${date.day}/${date.month}/${date.year}';
      groups
          .putIfAbsent('$label|${_activityCategory(kind)}', () => [])
          .add(event);
    }
    if (groups.isEmpty) {
      return [
        _empty(
          'No activity yet',
          'Connections and shared activity will appear here.',
          Icons.history,
        ),
      ];
    }
    String? previousDay;
    final widgets = <Widget>[];
    for (final group in groups.entries) {
      final parts = group.key.split('|');
      if (parts[0] != previousDay) {
        widgets.add(_section(parts[0]));
        previousDay = parts[0];
      }
      widgets.add(
        Card(
          child: ExpansionTile(
            title: Text(parts[1]),
            subtitle: Text(
              '${group.value.length} ${group.value.length == 1 ? 'event' : 'events'}',
            ),
            children: [
              for (final event in group.value)
                ListTile(
                  leading: const Icon(Icons.history, size: 20),
                  title: Text(_activityMessage(event)),
                  subtitle: Text(_time(event['timestamp'] as int)),
                ),
            ],
          ),
        ),
      );
    }
    return widgets;
  }
}
