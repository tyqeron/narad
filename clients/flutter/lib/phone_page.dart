import 'dart:async';
import 'package:flutter/material.dart';
import 'api.dart';
import 'contacts_page.dart';

/// Content is kept only while this screen is open. Side effects require a user tap.
class PhonePage extends StatefulWidget {
  const PhonePage({super.key, required this.api, required this.peer});
  final NaradApi api;
  final Map<String, dynamic> peer;
  @override
  State<PhonePage> createState() => _PhonePageState();
}

class _PhonePageState extends State<PhonePage> with WidgetsBindingObserver {
  Timer? _timer;
  int _tab = 0;
  bool _loading = false, _acting = false, _foreground = true;
  String? _error;
  List<Map<String, dynamic>> _items = [], _calls = [];
  Map<String, dynamic> _support = {};
  String? _before, _thread;
  int _generation = 0;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_load());
    _timer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (_foreground) unawaited(_load());
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground && mounted) {
      setState(() {
        _items = [];
        _calls = [];
      });
    }
    if (_foreground) unawaited(_load());
  }

  Future<Map<String, dynamic>> _request(
    String kind, [
    Map<String, dynamic> args = const {},
  ]) => widget.api.call({
    'op': 'phone_request',
    'peer_id': widget.peer['device_id'],
    'kind': kind,
    'args': args,
  });
  Future<void> _load() async {
    if (_loading || _acting || !_foreground) return;
    _loading = true;
    final generation = _generation;
    try {
      final support = await _request('support');
      final kind = ['notifications', 'sms_list', 'calls_list'][_tab];
      Object? partialError;
      var result = <String, dynamic>{'items': <dynamic>[]};
      try {
        if (widget.peer['platform'] == 'ios') {
          partialError = StateError(
            'This iPhone can open SMS and call requests for confirmation. iOS does not let Narad read its SMS inbox, call history or general system notifications.',
          );
        } else {
          result = await _request(kind, {
            if (_before != null) 'before': int.parse(_before!),
            if (_thread != null) 'thread_id': int.parse(_thread!),
          });
        }
      } catch (e) {
        if (_tab != 2) rethrow;
        partialError = e;
      }
      var calls = <Map<String, dynamic>>[];
      if (_tab == 2 && (support['support'] as Map?)?['call_control'] == true) {
        try {
          calls = ((await _request('call_state'))['items'] as List? ?? [])
              .map((e) => Map<String, dynamic>.from(e as Map))
              .toList();
        } catch (e) {
          partialError = e;
        }
      }
      if (mounted && generation == _generation && _foreground) {
        setState(() {
          _support = Map<String, dynamic>.from(
            support['support'] as Map? ?? {},
          );
          _items = (result['items'] as List? ?? [])
              .map((e) => Map<String, dynamic>.from(e as Map))
              .toList();
          _calls = calls;
          _next = result['next_before']?.toString();
          _error = partialError?.toString();
        });
      }
    } catch (e) {
      if (mounted && generation == _generation) {
        setState(() {
          _error = e.toString();
          _items = [];
          _calls = [];
        });
      }
    } finally {
      _loading = false;
      if (mounted) setState(() {});
    }
  }

  String? _next;
  Future<void> _action(String kind, Map<String, dynamic> args) async {
    if (_acting) return;
    setState(() => _acting = true);
    try {
      final result = await _request(kind, args);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(result['message']?.toString() ?? 'Request completed'),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = e.toString());
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.toString())));
      }
    } finally {
      if (mounted) setState(() => _acting = false);
    }
    await _load();
  }

  Future<void> _compose({String? number, String? notification}) async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) =>
          _PhoneComposeDialog(number: number, notification: notification),
    );
    if (result != null && mounted) {
      await _action(
        notification == null ? 'sms_send' : 'notification_reply',
        result,
      );
    }
  }

  Future<void> _dial([String? initial]) async {
    final number = await showDialog<String>(
      context: context,
      builder: (_) => _PhoneDialDialog(initial: initial),
    );
    if (number != null && mounted) await _action('dial', {'number': number});
  }

  String _date(dynamic value) {
    final time = DateTime.fromMillisecondsSinceEpoch(
      int.tryParse(value.toString()) ?? 0,
    ).toLocal();
    return time.toString().substring(0, 16);
  }

  void _select(int value) {
    setState(() {
      _tab = value;
      _before = null;
      _thread = null;
      _next = null;
      _generation++;
      _items = [];
      _calls = [];
      _error = null;
    });
    unawaited(_load());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _items = [];
    _calls = [];
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text('Phone · ${widget.peer['device_name']}'),
      actions: [
        IconButton(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => ContactsPage(
                api: widget.api,
                peer: widget.peer,
                onSms: (number) => _compose(number: number),
                onCall: (number) => _dial(number),
              ),
            ),
          ),
          icon: const Icon(Icons.contacts_outlined),
          tooltip: 'Contacts',
        ),
        IconButton(
          onPressed: _loading ? null : _load,
          icon: const Icon(Icons.refresh),
          tooltip: 'Refresh',
        ),
      ],
    ),
    body: Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: SegmentedButton<int>(
            segments: const [
              ButtonSegment(
                value: 0,
                icon: Icon(Icons.notifications_outlined),
                label: Text('Alerts'),
              ),
              ButtonSegment(
                value: 1,
                icon: Icon(Icons.sms_outlined),
                label: Text('SMS'),
              ),
              ButtonSegment(
                value: 2,
                icon: Icon(Icons.call_outlined),
                label: Text('Calls'),
              ),
            ],
            selected: {_tab},
            onSelectionChanged: (s) => _select(s.single),
          ),
        ),
        if (_loading || _acting) const LinearProgressIndicator(),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (_error != null)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      '$_error\n\n${widget.peer['platform'] == 'ios' ? 'Keep Narad visible on iPhone to confirm SMS or call requests.' : 'On the phone, enable Phone integration and grant this device access in Device settings.'}',
                    ),
                  ),
                ),
              if (_tab == 1)
                Wrap(
                  spacing: 8,
                  children: [
                    FilledButton.icon(
                      onPressed: _acting ? null : () => _compose(),
                      icon: const Icon(Icons.edit_outlined),
                      label: const Text('New SMS'),
                    ),
                    if (_thread != null)
                      TextButton(
                        onPressed: () {
                          _thread = null;
                          _before = null;
                          unawaited(_load());
                        },
                        child: const Text('All messages'),
                      ),
                  ],
                ),
              if (_tab == 2) ...[
                FilledButton.icon(
                  onPressed: _acting ? null : () => _dial(),
                  icon: const Icon(Icons.dialpad),
                  label: const Text('Make call'),
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    'Answer, end and mute controls require Narad as the phone’s default dialer. Audio stays on the phone or an OS-provided Bluetooth route. Narad does not set up desktop cellular-call audio.',
                  ),
                ),
                for (final call in _calls)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${call['number']} · ${call['state']}',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          Wrap(
                            spacing: 8,
                            children: [
                              if (call['state'] == 'ringing') ...[
                                FilledButton.icon(
                                  onPressed: _acting
                                      ? null
                                      : () => _action('answer', {
                                          'call_id': call['id'],
                                        }),
                                  icon: const Icon(Icons.call),
                                  label: const Text('Answer'),
                                ),
                                TextButton(
                                  onPressed: _acting
                                      ? null
                                      : () => _action('reject', {
                                          'call_id': call['id'],
                                        }),
                                  child: const Text('Decline'),
                                ),
                              ] else
                                FilledButton.icon(
                                  onPressed: _acting
                                      ? null
                                      : () => _action('hangup', {
                                          'call_id': call['id'],
                                        }),
                                  icon: const Icon(Icons.call_end),
                                  label: const Text('End call'),
                                ),
                              TextButton(
                                onPressed: _acting
                                    ? null
                                    : () => _action('mute', {'muted': true}),
                                child: const Text('Mute'),
                              ),
                              TextButton(
                                onPressed: _acting
                                    ? null
                                    : () => _action('mute', {'muted': false}),
                                child: const Text('Unmute'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
              if (_items.isEmpty && _error == null && !_loading)
                const Padding(
                  padding: EdgeInsets.all(20),
                  child: Text('No items to show'),
                ),
              for (final item in _items)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _tab == 0
                              ? '${item['app']} · ${item['title']}'
                              : _tab == 1
                              ? '${item['address']}'
                              : '${item['name'] ?? ''} ${item['number']}',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        if (_tab == 0 || _tab == 1)
                          SelectableText(
                            (item[_tab == 0 ? 'text' : 'body'] ?? '')
                                .toString(),
                          ),
                        Text(_date(item[_tab == 0 ? 'time' : 'date'])),
                        if (_tab == 2)
                          Text(
                            '${item['type'] == '1'
                                ? 'Incoming'
                                : item['type'] == '2'
                                ? 'Outgoing'
                                : item['type'] == '3'
                                ? 'Missed'
                                : 'Call'} · ${item['duration']} seconds',
                          ),
                        Wrap(
                          spacing: 8,
                          children: [
                            if (_tab == 0 && item['reply'] == true)
                              TextButton.icon(
                                onPressed: _acting
                                    ? null
                                    : () => _compose(
                                        notification: item['key'] as String,
                                      ),
                                icon: const Icon(Icons.reply),
                                label: const Text('Reply'),
                              ),
                            if (_tab == 0 && item['dismissible'] == true)
                              TextButton(
                                onPressed: _acting
                                    ? null
                                    : () => _action('notification_dismiss', {
                                        'key': item['key'],
                                      }),
                                child: const Text('Dismiss on phone'),
                              ),
                            if (_tab == 1) ...[
                              TextButton(
                                onPressed: _acting
                                    ? null
                                    : () => _compose(
                                        number: item['address']?.toString(),
                                      ),
                                child: const Text('Reply by SMS'),
                              ),
                              TextButton(
                                onPressed: () {
                                  _thread = item['thread_id'].toString();
                                  _before = null;
                                  _generation++;
                                  unawaited(_load());
                                },
                                child: const Text('Conversation'),
                              ),
                            ],
                            if (_tab == 2)
                              TextButton(
                                onPressed: _acting
                                    ? null
                                    : () => _dial(item['number']?.toString()),
                                child: const Text('Call back'),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              if (_next != null)
                TextButton(
                  onPressed: () {
                    _before = _next;
                    _generation++;
                    unawaited(_load());
                  },
                  child: const Text('Older items'),
                ),
              if (_before != null)
                TextButton(
                  onPressed: () {
                    _before = null;
                    _generation++;
                    unawaited(_load());
                  },
                  child: const Text('Latest items'),
                ),
              if (_support['enabled'] == true)
                const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: Text(
                    'Phone content is shown live and is not saved in Narad activity history.',
                  ),
                ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _PhoneComposeDialog extends StatefulWidget {
  const _PhoneComposeDialog({this.number, this.notification});
  final String? number, notification;
  @override
  State<_PhoneComposeDialog> createState() => _PhoneComposeDialogState();
}

class _PhoneComposeDialogState extends State<_PhoneComposeDialog> {
  late final recipient = TextEditingController(text: widget.number);
  final text = TextEditingController();
  @override
  void dispose() {
    recipient.dispose();
    text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      widget.notification != null ? 'Reply to notification' : 'Send SMS',
    ),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.notification == null)
            TextField(
              controller: recipient,
              decoration: const InputDecoration(labelText: 'Phone number'),
              keyboardType: TextInputType.phone,
            ),
          TextField(
            controller: text,
            decoration: const InputDecoration(labelText: 'Message'),
            maxLines: 5,
            maxLength: widget.notification != null ? 2000 : 1600,
          ),
          if (widget.notification == null)
            const Text(
              'Sent through the phone’s default SMS SIM. Carrier charges may apply.',
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () {
          if (text.text.trim().isEmpty) return;
          Navigator.pop(context, <String, dynamic>{
            if (widget.notification != null)
              'key': widget.notification
            else
              'number': recipient.text.trim(),
            'text': text.text,
          });
        },
        child: const Text('Send'),
      ),
    ],
  );
}

class _PhoneDialDialog extends StatefulWidget {
  const _PhoneDialDialog({this.initial});
  final String? initial;
  @override
  State<_PhoneDialDialog> createState() => _PhoneDialDialogState();
}

class _PhoneDialDialogState extends State<_PhoneDialDialog> {
  late final number = TextEditingController(text: widget.initial);
  @override
  void dispose() {
    number.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Call through phone'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          controller: number,
          decoration: const InputDecoration(labelText: 'Phone number'),
          keyboardType: TextInputType.phone,
        ),
        const Text(
          'Call audio stays on the phone or its Bluetooth hands-free connection. Narad does not carry cellular audio over Wi-Fi.',
        ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () {
          if (number.text.trim().isNotEmpty) {
            Navigator.pop(context, number.text.trim());
          }
        },
        child: const Text('Call'),
      ),
    ],
  );
}
