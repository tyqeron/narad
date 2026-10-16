import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'api.dart';

String contactVcard(Map<String, dynamic> contact) {
  String escape(Object? value) => (value ?? '')
      .toString()
      .replaceAll('\\', '\\\\')
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .replaceAll('\n', r'\n')
      .replaceAll(';', r'\;')
      .replaceAll(',', r'\,');
  final lines = [
    'BEGIN:VCARD',
    'VERSION:3.0',
    'FN:${escape(contact['name'])}',
    for (final phone in contact['phones'] as List? ?? [])
      'TEL:${escape(phone)}',
    for (final email in contact['emails'] as List? ?? [])
      'EMAIL:${escape(email)}',
    'END:VCARD',
  ];
  // Fold by UTF-8 octets without splitting a Unicode scalar.
  return '${lines.map((line) {
    var width = 0;
    final out = StringBuffer();
    for (final rune in line.runes) {
      final char = String.fromCharCode(rune), size = utf8.encode(String.fromCharCode(rune)).length;
      if (width + size > 75) {
        out.write('\r\n ');
        width = 1;
      }
      out.write(char);
      width += size;
    }
    return out.toString();
  }).join('\r\n')}\r\n';
}

class ContactsPage extends StatefulWidget {
  const ContactsPage({
    super.key,
    required this.api,
    required this.peer,
    this.onSms,
    this.onCall,
  });
  final NaradApi api;
  final Map<String, dynamic> peer;
  final Future<void> Function(String)? onSms, onCall;
  @override
  State<ContactsPage> createState() => _ContactsPageState();
}

class _ContactsPageState extends State<ContactsPage>
    with WidgetsBindingObserver {
  List<Map<String, dynamic>> _items = [];
  String? _after, _next, _error;
  bool _busy = false, _active = true;
  int _generation = 0;
  Timer? _timer;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_load());
    _timer = Timer.periodic(const Duration(seconds: 10), (_) => _load());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _active = state == AppLifecycleState.resumed;
    _generation++;
    if (!_active) {
      setState(() => _items = []);
    } else {
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    if (_busy || !_active) return;
    _busy = true;
    final generation = _generation;
    try {
      final result = await widget.api.call({
        'op': 'phone_request',
        'peer_id': widget.peer['device_id'],
        'kind': 'contacts_list',
        'args': {if (_after != null) 'after': _after},
      });
      if (mounted && _active && generation == _generation) {
        setState(() {
          _items = (result['items'] as List)
              .map((e) => Map<String, dynamic>.from(e as Map))
              .toList();
          _next = result['next_after']?.toString();
          _error = null;
        });
      }
    } catch (e) {
      if (mounted && generation == _generation) {
        setState(() {
          _error = e.toString();
          _items = [];
          _next = null;
        });
      }
    } finally {
      _busy = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _save(Map<String, dynamic> item) async {
    try {
      if (Platform.isAndroid || Platform.isIOS) {
        await MethodChannel(
          Platform.isIOS ? 'dev.narad/ios' : 'dev.narad/android',
        ).invokeMethod<void>('importContact', item);
      } else {
        await FilePicker.saveFile(
          dialogTitle: 'Save contact for your address book',
          fileName: 'Narad-contact.vcf',
          type: FileType.custom,
          allowedExtensions: ['vcf'],
          bytes: Uint8List.fromList(utf8.encode(contactVcard(item))),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _items = [];
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text('Contacts · ${widget.peer['device_name']}'),
      actions: [
        IconButton(
          onPressed: _busy ? null : _load,
          icon: const Icon(Icons.refresh),
          tooltip: 'Refresh contacts',
        ),
      ],
    ),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'Live contacts from this device. Save opens your contact editor, or exports a vCard on desktop. Review before saving; existing contacts are not merged or overwritten.',
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              '$_error\nEnable contacts access and allow this device in the source device’s settings.',
            ),
          ),
        if (_busy) const LinearProgressIndicator(),
        for (final item in _items)
          Card(
            child: ListTile(
              leading: const Icon(Icons.person_outline),
              title: Text(item['name']?.toString() ?? ''),
              subtitle: SelectableText(
                [
                  ...(item['phones'] as List? ?? []),
                  ...(item['emails'] as List? ?? []),
                ].join('\n'),
              ),
              trailing: PopupMenuButton<String>(
                tooltip: 'Contact actions',
                onSelected: (action) {
                  if (action == 'save') {
                    unawaited(_save(item));
                  } else if (action == 'sms') {
                    unawaited(
                      widget.onSms!((item['phones'] as List).first.toString()),
                    );
                  } else if (action == 'call') {
                    unawaited(
                      widget.onCall!((item['phones'] as List).first.toString()),
                    );
                  }
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(
                    value: 'save',
                    child: Text('Save contact'),
                  ),
                  if ((item['phones'] as List? ?? []).isNotEmpty &&
                      widget.onSms != null)
                    const PopupMenuItem(value: 'sms', child: Text('Send SMS')),
                  if ((item['phones'] as List? ?? []).isNotEmpty &&
                      widget.onCall != null)
                    const PopupMenuItem(value: 'call', child: Text('Call')),
                ],
              ),
            ),
          ),
        if (_next != null)
          TextButton(
            onPressed: _busy
                ? null
                : () {
                    _after = _next;
                    unawaited(_load());
                  },
            child: const Text('Next contacts'),
          ),
        if (_after != null)
          TextButton(
            onPressed: _busy
                ? null
                : () {
                    _after = null;
                    unawaited(_load());
                  },
            child: const Text('First contacts'),
          ),
        if (_items.isEmpty && _error == null && !_busy)
          const Text('No contacts to show'),
      ],
    ),
  );
}
