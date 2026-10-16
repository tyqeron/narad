import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:path_provider/path_provider.dart';

/// The plugin uses one temporary PNG path: serialize captures and remove that file.
class CameraFrames {
  static Future<void> _tail = Future<void>.value();
  static Future<Uint8List> capture(MediaStreamTrack track) {
    final result = Completer<Uint8List>();
    _tail = _tail
        .then((_) async {
          try {
            final bytes = (await track.captureFrame()).asUint8List();
            // Android's plugin labels this .png but encodes JPEG. Normalize the public format.
            final codec = await ui.instantiateImageCodec(bytes);
            ui.Image? image;
            try {
              image = (await codec.getNextFrame()).image;
              final png = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              if (png == null) {
                throw StateError('Unable to encode camera image');
              }
              result.complete(
                png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
              );
            } finally {
              image?.dispose();
              codec.dispose();
            }
          } catch (e, st) {
            result.completeError(e, st);
          } finally {
            final file = File(
              '${(await getTemporaryDirectory()).path}/captureFrame.png',
            );
            if (await file.exists()) await file.delete();
          }
        })
        .catchError((Object _) {});
    return result.future;
  }
}

/// An explicitly started, loopback-only OBS Browser source; never a LAN server.
class CameraFeed {
  HttpServer? _server;
  Uint8List? frame;
  late String _token;
  String? get url =>
      _server == null ? null : 'http://127.0.0.1:${_server!.port}/$_token/';
  Future<String> start() async {
    if (url != null) return url!;
    _token = base64Url
        .encode(List<int>.generate(32, (_) => Random.secure().nextInt(256)))
        .replaceAll('=', '');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    server.listen((request) async {
      final response = request.response;
      response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      response.headers.set('X-Content-Type-Options', 'nosniff');
      // Reject DNS rebinding and cross-origin embedding. The random path is a local capability.
      if (request.method != 'GET' ||
          request.headers.value('host') != '127.0.0.1:${server.port}' ||
          !['/$_token/', '/$_token/frame.png'].contains(request.uri.path)) {
        response.statusCode = HttpStatus.notFound;
      } else if (request.uri.path.endsWith('frame.png')) {
        if (frame == null) {
          response.statusCode = HttpStatus.serviceUnavailable;
        } else {
          response.headers.contentType = ContentType('image', 'png');
          response.add(frame!);
        }
      } else {
        response.headers.contentType = ContentType.html;
        response.write(
          '''<!doctype html><html><head><meta name="referrer" content="no-referrer"><style>html,body{margin:0;background:black;width:100%;height:100%;overflow:hidden}img{width:100%;height:100%;object-fit:contain}</style></head><body><img id="camera"><script>const image=document.getElementById('camera');async function next(){try{const r=await fetch('frame.png',{cache:'no-store'});if(r.ok){const u=URL.createObjectURL(await r.blob());await new Promise(resolve=>{image.onload=()=>{URL.revokeObjectURL(u);resolve()};image.onerror=()=>{URL.revokeObjectURL(u);resolve()};image.src=u;});}else image.removeAttribute('src');}catch(e){image.removeAttribute('src');}setTimeout(next,125)}next();</script></body></html>''',
        );
      }
      try {
        await response.close();
      } catch (_) {}
    });
    return url!;
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    frame = null;
    await server?.close(force: true);
  }
}

class CameraTools {
  CameraTools(this.track, this.onError, {this.capture});
  final Future<Uint8List> Function()? capture;
  final MediaStreamTrack Function() track;
  final void Function(Object) onError;
  final feed = CameraFeed();
  MediaRecorder? _native;
  Process? _encoder;
  Directory? _directory;
  String? recordingPath;
  DateTime? recordingStarted;
  bool get recording => recordingPath != null;
  Timer? _pump, _limit;
  bool _capturing = false, _disposed = false;
  final List<String> completed = [];
  String _encoderError = '';
  int _encodedFrames = 0;

  Future<Uint8List> photo() => capture?.call() ?? CameraFrames.capture(track());
  Future<String> startFeed() async {
    if (_disposed) throw StateError('Camera session ended');
    final url = await feed.start();
    _ensurePump();
    return url;
  }

  Future<void> stopFeed() async {
    await feed.stop();
    _stopIdlePump();
  }

  void _ensurePump() {
    _pump ??= Timer.periodic(
      const Duration(milliseconds: 125),
      (_) => unawaited(_frame()),
    );
  }

  void _stopIdlePump() {
    if (feed.url == null && _encoder == null) {
      _pump?.cancel();
      _pump = null;
    }
  }

  Future<void> _frame() async {
    if (_capturing || _disposed) return;
    _capturing = true;
    try {
      final bytes = await photo();
      if (_disposed) return;
      if (feed.url != null) feed.frame = bytes;
      final encoder = _encoder;
      if (encoder != null) {
        // Preserve elapsed video time even when capture produces fewer than 8 fps.
        // Duplicate the latest frame with bounded catch-up and real backpressure.
        final expected = max(
          1,
          DateTime.now().difference(recordingStarted!).inMilliseconds ~/ 125,
        );
        final target = min(expected, _encodedFrames + 16);
        while (_encodedFrames < target && identical(encoder, _encoder)) {
          encoder.stdin.add(bytes);
          await encoder.stdin.flush();
          _encodedFrames++;
        }
      }
    } catch (e) {
      await stopFeed();
      if (recording) {
        try {
          await stopRecording();
        } catch (_) {}
      }
      onError(e);
    } finally {
      _capturing = false;
    }
  }

  Future<void> startRecording() async {
    if (_disposed || recording) {
      throw StateError('Camera unavailable or already recording');
    }
    _directory ??= await Directory.systemTemp.createTemp('narad-camera-');
    final path =
        '${_directory!.path}/${DateTime.now().microsecondsSinceEpoch}.mp4';
    try {
      if (Platform.isAndroid || Platform.isIOS) {
        final recorder = MediaRecorder();
        await recorder.start(path, videoTrack: track());
        _native = recorder;
      } else {
        // Native desktop WebRTC has no recorder. Bound the preview recording to 8 fps.
        final encoder = await Process.start('ffmpeg', [
          '-hide_banner',
          '-loglevel',
          'error',
          '-nostdin',
          '-f',
          'image2pipe',
          '-framerate',
          '8',
          '-vcodec',
          'png',
          '-i',
          'pipe:0',
          '-an',
          '-vf',
          'scale=trunc(iw/2)*2:trunc(ih/2)*2',
          '-c:v',
          'libx264',
          '-preset',
          'ultrafast',
          '-pix_fmt',
          'yuv420p',
          '-movflags',
          '+faststart',
          '-y',
          path,
        ], runInShell: false);
        _encoder = encoder;
        _encoderError = '';
        _encodedFrames = 0;
        encoder.stdout.drain<void>();
        encoder.stderr.transform(utf8.decoder).listen((text) {
          if (_encoderError.length < 2000) _encoderError += text;
        });
        _ensurePump();
      }
      if (_disposed) {
        await _native?.stop();
        _native = null;
        _encoder?.kill();
        _encoder = null;
        throw StateError('Camera session ended');
      }
      recordingPath = path;
      recordingStarted = DateTime.now();
      _limit = Timer.periodic(const Duration(seconds: 2), (_) async {
        if (!recording) return;
        if (DateTime.now().difference(recordingStarted!).inMinutes >= 10 ||
            (await File(path).exists() &&
                await File(path).length() > 128 * 1024 * 1024)) {
          try {
            await stopRecording();
            onError(
              StateError(
                'Recording stopped at the 10-minute / 128 MB limit. Save it below.',
              ),
            );
          } catch (e) {
            onError(e);
          }
        }
      });
    } catch (e) {
      recordingPath = null;
      _native = null;
      _encoder?.kill();
      _encoder = null;
      _stopIdlePump();
      rethrow;
    }
  }

  Future<String?> stopRecording() async {
    final path = recordingPath;
    if (path == null) return null;
    recordingPath = null;
    recordingStarted = null;
    _limit?.cancel();
    _limit = null;
    final native = _native;
    _native = null;
    final encoder = _encoder;
    _encoder = null;
    _stopIdlePump();
    try {
      if (native != null) await native.stop();
      if (encoder != null) {
        await encoder.stdin.close();
        final exit = await encoder.exitCode.timeout(
          const Duration(seconds: 15),
          onTimeout: () {
            encoder.kill();
            return -1;
          },
        );
        if (exit != 0) {
          throw StateError(
            'Video encoding failed. Check FFmpeg with libx264. $_encoderError',
          );
        }
      }
      if (!await File(path).exists() || await File(path).length() == 0) {
        throw StateError('No recorded video frames');
      }
      completed.add(path);
      return path;
    } catch (e) {
      if (await File(path).exists()) await File(path).delete();
      rethrow;
    }
  }

  Future<void> discard(String path) async {
    completed.remove(path);
    final f = File(path);
    if (await f.exists()) await f.delete();
  }

  void quiesce() {
    _disposed = true;
    _pump?.cancel();
    _pump = null;
  }

  Future<void> stop() async {
    quiesce();
    _pump?.cancel();
    _pump = null;
    await stopFeed();
    if (recording) {
      try {
        await stopRecording();
      } catch (e) {
        onError(e);
      }
    }
  }

  Future<void> dispose() async {
    await stop();
    completed.clear();
    if (_directory != null && await _directory!.exists()) {
      await _directory!.delete(recursive: true);
    }
  }
}
