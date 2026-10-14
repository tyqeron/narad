import 'dart:async';
import 'dart:convert';
import 'dart:io';

abstract class NaradApi {
  Future<Map<String, dynamic>> call(Map<String, dynamic> command);
}

class DaemonApi implements NaradApi {
  DaemonApi(this.stateDirectory, this.port);
  final String stateDirectory;
  final int port;

  @override
  Future<Map<String, dynamic>> call(Map<String, dynamic> command) async {
    final token = await File('$stateDirectory/api-token').readAsString();
    final socket = await Socket.connect(
      '127.0.0.1',
      port,
      timeout: const Duration(seconds: 3),
    );
    try {
      socket.write('${jsonEncode({'token': token, 'command': command})}\n');
      await socket.flush();
      // Bound the local response before decoding it.
      final bytes = <int>[];
      final response = await (() async {
        await for (final chunk in socket) {
          for (final byte in chunk) {
            if (byte == 10) {
              return jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
            }
            if (bytes.length >= 512 * 1024) {
              throw const FormatException('Daemon response exceeds size limit');
            }
            bytes.add(byte);
          }
        }
        throw const SocketException('Daemon disconnected before responding');
      })().timeout(const Duration(minutes: 10));
      if (response['ok'] != true) {
        throw StateError(response['error'] as String? ?? 'Command failed');
      }
      return response;
    } finally {
      socket.destroy();
    }
  }
}
