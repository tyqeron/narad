import 'package:flutter/material.dart';

class ShareUrlDialog extends StatefulWidget {
  const ShareUrlDialog({super.key, required this.deviceName});
  final String deviceName;

  @override
  State<ShareUrlDialog> createState() => _ShareUrlDialogState();
}

class _ShareUrlDialogState extends State<ShareUrlDialog> {
  final _controller = TextEditingController();
  final _form = GlobalKey<FormState>();

  void _submit() {
    if (_form.currentState!.validate()) {
      Navigator.of(context).pop(_controller.text.trim());
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Share link with ${widget.deviceName}'),
    content: Form(
      key: _form,
      child: TextFormField(
        controller: _controller,
        autofocus: true,
        keyboardType: TextInputType.url,
        textInputAction: TextInputAction.send,
        decoration: const InputDecoration(
          labelText: 'Web address',
          hintText: 'https://example.com',
        ),
        validator: (value) {
          final text = value?.trim() ?? '';
          if (text.isEmpty) return 'Enter a web address';
          final uri = Uri.tryParse(text);
          if (uri == null ||
              !['http', 'https'].contains(uri.scheme) ||
              uri.host.isEmpty ||
              text.contains(RegExp(r'\s'))) {
            return 'Enter a valid http:// or https:// link';
          }
          return null;
        },
        onFieldSubmitted: (_) => _submit(),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _submit, child: const Text('Share')),
    ],
  );
}
