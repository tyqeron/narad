import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

class PairingScanner extends StatefulWidget {
  const PairingScanner({super.key});
  @override
  State<PairingScanner> createState() => _PairingScannerState();
}

class _PairingScannerState extends State<PairingScanner> {
  final _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  bool _handled = false;
  String? _error;
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Scan pairing invitation')),
    body: Stack(
      children: [
        MobileScanner(
          controller: _controller,
          onDetect: (capture) async {
            if (_handled) return;
            for (final barcode in capture.barcodes) {
              final text = barcode.rawValue;
              if (text == null) continue;
              try {
                final decoded = jsonDecode(text);
                if (decoded is! Map<String, dynamic>) {
                  throw const FormatException();
                }
                final invitation = decoded['invitation'] ?? decoded;
                if (invitation is! Map ||
                    invitation['peer'] is! Map ||
                    invitation['nonce'] is! String ||
                    invitation['expires_at'] is! int) {
                  throw const FormatException();
                }
                _handled = true;
                await _controller.stop();
                if (context.mounted) Navigator.pop(context, text);
                return;
              } catch (_) {
                if (mounted) {
                  setState(
                    () => _error =
                        'This is not a Narad invitation. Scan the code shown on the other device.',
                  );
                }
              }
            }
          },
          errorBuilder: (context, error) => Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'Camera unavailable. Allow camera permission in Android settings, or paste an invitation.\n${error.errorCode.name}',
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ),
        Align(
          alignment: Alignment.bottomCenter,
          child: Container(
            width: double.infinity,
            color: Colors.black87,
            padding: const EdgeInsets.all(24),
            child: SafeArea(
              top: false,
              child: Text(
                _error ??
                    'Point the camera at the invitation on your other device. Both devices must use the same local network.',
                style: const TextStyle(color: Colors.white),
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ),
      ],
    ),
  );
}
