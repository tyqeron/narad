import 'dart:convert';
import 'dart:typed_data';

/// A bounded PNG from a paired phone, never a remote URI or arbitrary image size.
Uint8List? notificationIcon(Object? encoded) {
  if (encoded is! String || encoded.isEmpty || encoded.length > 8192) {
    return null;
  }
  try {
    final bytes = base64Decode(encoded);
    const signature = [137, 80, 78, 71, 13, 10, 26, 10];
    if (bytes.length < 33 || bytes.length > 6144) return null;
    for (var i = 0; i < signature.length; i++) {
      if (bytes[i] != signature[i]) return null;
    }
    final header = ByteData.sublistView(bytes);
    if (header.getUint32(8) != 13 ||
        header.getUint32(12) != 0x49484452 ||
        header.getUint32(16) != 32 ||
        header.getUint32(20) != 32) {
      return null;
    }
    return bytes;
  } on FormatException {
    return null;
  }
}
