import 'dart:async';
import 'package:flutter/material.dart';

class RemoteInputPage extends StatefulWidget {
  const RemoteInputPage({super.key, required this.name, required this.send});
  final String name;
  final Future<void> Function(Map<String, dynamic>) send;
  @override
  State<RemoteInputPage> createState() => _RemoteInputPageState();
}

class _RemoteInputPageState extends State<RemoteInputPage> {
  final _text = TextEditingController();
  double _x = 0, _y = 0;
  bool _sending = false;
  Future<void> _queue = Future<void>.value();
  Future<void> _send(Map<String, dynamic> event) async {
    final previous = _queue;
    final done = Completer<void>();
    _queue = done.future;
    await previous;
    if (mounted) setState(() => _sending = true);
    try {
      await widget.send(event);
    } catch (error) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$error')));
    } finally {
      done.complete();
      if (mounted && identical(_queue, done.future))
        setState(() => _sending = false);
    }
  }

  void _move(DragUpdateDetails details) {
    _x += details.delta.dx * 2.4;
    _y += details.delta.dy * 2.4;
    if (_x.abs() >= 1 || _y.abs() >= 1) {
      final x = _x.round(), y = _y.round();
      _x -= x;
      _y -= y;
      _send({'type': 'move', 'x': x, 'y': y});
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text('Control ${widget.name}')),
    body: SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Use this device as a touchpad and keyboard. The other device needs to allow “Keyboard and mouse control”. Linux currently requires an X11 session with xdotool installed.',
            ),
            const SizedBox(height: 16),
            Expanded(
              child: GestureDetector(
                onPanUpdate: _move,
                onTap: () => _send({'type': 'click', 'button': 'left'}),
                onLongPress: () => _send({'type': 'click', 'button': 'right'}),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Theme.of(
                      context,
                    ).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.touch_app, size: 42),
                        SizedBox(height: 8),
                        Text(
                          'Touchpad · tap to click · long-press for right-click',
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  tooltip: 'Scroll up',
                  onPressed: () => _send({'type': 'scroll', 'x': 0, 'y': -3}),
                  icon: const Icon(Icons.keyboard_arrow_up),
                ),
                IconButton(
                  tooltip: 'Scroll down',
                  onPressed: () => _send({'type': 'scroll', 'x': 0, 'y': 3}),
                  icon: const Icon(Icons.keyboard_arrow_down),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _text,
                    enabled: !_sending,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _sendText(),
                    decoration: const InputDecoration(
                      labelText: 'Type on the other device',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                IconButton.filled(
                  tooltip: 'Send text',
                  onPressed: _sending ? null : _sendText,
                  icon: const Icon(Icons.send),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
  void _sendText() {
    final value = _text.text;
    if (value.isNotEmpty) {
      _text.clear();
      _send({'type': 'text', 'text': value});
    }
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }
}
