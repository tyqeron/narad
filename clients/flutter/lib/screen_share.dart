import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'api.dart';
import 'audio.dart' show validateMediaSdp;

class ScreenLink {
  ScreenLink(
    this.id,
    this.peer,
    this.outgoing, {
    this.stream,
    this.extended = false,
    this.releaseDisplay,
  });
  final createdAt = DateTime.now();
  final String id, peer;
  final bool outgoing, extended;
  final Future<void> Function()? releaseDisplay;
  MediaStream? stream;
  RTCPeerConnection? connection;
  RTCVideoRenderer? renderer;
  bool starting = false,
      remoteReady = false,
      connected = false,
      reportedConnected = false;
  final candidates = <RTCIceCandidate>[];
  Future<void> signals = Future<void>.value();
  int queuedSignals = 0;
}

class ScreenController extends ChangeNotifier {
  ScreenController(this.api, this.onError);
  final NaradApi api;
  final void Function(Object) onError;
  final links = <String, ScreenLink>{};
  bool enabled = true, _ticking = false, _disposed = false, _capturing = false;
  MediaStream? _mobileCapture;

  Future<void> setEnabled(bool value) async {
    enabled = value;
    if (!value) {
      for (final id in links.keys.toList()) {
        await stop(id);
      }
    }
    await api.call({'op': 'screen_ready', 'ready': value});
    _changed();
  }

  Future<String> send(
    String peer, {
    String? sourceId,
    bool extended = false,
    Future<void> Function()? releaseDisplay,
  }) async {
    if (_capturing) {
      throw StateError('Finish the current screen selection first');
    }
    _capturing = true;
    MediaStream? capture;
    try {
      if (!enabled) await setEnabled(true);
      await api.call({'op': 'screen_ready', 'ready': true});
      if (Platform.isAndroid && _mobileCapture != null) {
        capture = _mobileCapture;
      } else {
        if (Platform.isAndroid) {
          if (!await Helper.requestCapturePermission()) {
            throw StateError('Screen sharing was cancelled');
          }
          await const MethodChannel(
            'dev.narad/android',
          ).invokeMethod<void>('screenProjection', {'enabled': true});
        }
        capture = await navigator.mediaDevices.getDisplayMedia({
          'audio': false,
          'video': {
            if (sourceId != null) 'deviceId': {'exact': sourceId},
            'frameRate': 30,
            'mandatory': {'frameRate': 30.0},
          },
        });
        if (capture.getVideoTracks().isEmpty) {
          throw StateError('The selected screen has no video track');
        }
        if (Platform.isAndroid) _mobileCapture = capture;
      }
      if (_disposed) throw StateError('Screen sharing has stopped');
      final response = await api.call({
        'op': 'media_start',
        'peer_id': peer,
        'kind': 'screen',
      });
      final id = response['id'] as String;
      links[id] = ScreenLink(
        id,
        peer,
        true,
        stream: capture,
        extended: extended,
        releaseDisplay: releaseDisplay,
      );
      final source = capture;
      source!.getVideoTracks().first.onEnded = () {
        for (final link
            in links.values
                .where((l) => identical(l.stream, source))
                .toList()) {
          unawaited(stop(link.id).catchError(onError));
        }
      };
      _changed();
      return id;
    } catch (_) {
      if (capture != null &&
          !links.values.any((l) => identical(l.stream, capture))) {
        await _releaseCapture(capture);
      }
      if (Platform.isAndroid && _mobileCapture == null) {
        await const MethodChannel(
          'dev.narad/android',
        ).invokeMethod<void>('screenProjection', {'enabled': false});
      }
      rethrow;
    } finally {
      _capturing = false;
    }
  }

  Future<void> tick(Map<String, dynamic> status) async {
    if (_ticking || _disposed) return;
    _ticking = true;
    try {
      await api.call({'op': 'screen_ready', 'ready': enabled});
      final sessions = {
        for (final s in (status['sessions'] as List? ?? const []))
          s['id']: s as Map,
      };
      for (final link in links.values.toList()) {
        final session = sessions[link.id];
        if (session == null &&
            DateTime.now().difference(link.createdAt).inSeconds < 10) {
          continue;
        }
        if (session == null ||
            ['closed', 'denied', 'failed'].contains(session['state'])) {
          await stop(link.id, notify: false);
          continue;
        }
        await api.call({'op': 'session_touch', 'id': link.id});
        if (link.outgoing && link.connection == null && !link.starting) {
          final response = await api.call({
            'op': 'media_poll',
            'peer_id': link.peer,
            'id': link.id,
          });
          final state = response['session']['state'];
          if (state == 'authorized') {
            link.starting = true;
            unawaited(_offer(link));
          } else if (['closed', 'denied', 'failed'].contains(state)) {
            await stop(link.id, notify: false);
          }
        }
      }
      final events = await api.call({'op': 'media_events', 'kind': 'screen'});
      final signals = events['signals'] as List? ?? const [];
      // A request can arrive after the dashboard fetched its status but before
      // this consumer drains signals. Refresh once instead of losing its offer.
      if (signals.any(
        (signal) => !sessions.containsKey(signal['session_id']),
      )) {
        final current = await api.call({'op': 'status'});
        for (final session in current['sessions'] as List? ?? const []) {
          sessions[session['id']] = session as Map;
        }
      }
      for (final signal in signals) {
        final id = signal['session_id'] as String;
        final session = sessions[id];
        if (!enabled ||
            session == null ||
            session['capability'] != 'screen.view' ||
            [
              'requested',
              'closed',
              'denied',
              'failed',
            ].contains(session['state'])) {
          continue;
        }
        final link = links.putIfAbsent(
          id,
          () => ScreenLink(id, signal['peer_id'] as String, false),
        );
        try {
          await _receive(
            link,
            Map<String, dynamic>.from(signal['data'] as Map),
          );
        } catch (error) {
          await stop(id);
          onError(error);
        }
      }
    } catch (error) {
      if (!_disposed) onError(error);
    } finally {
      _ticking = false;
    }
  }

  Future<void> _connect(ScreenLink link) async {
    if (link.connection != null) return;
    await api.call({
      'op': 'media_state',
      'id': link.id,
      'state': 'negotiating',
    });
    final pc = await createPeerConnection({
      'iceServers': [],
      'sdpSemantics': 'unified-plan',
    });
    if (!links.containsKey(link.id)) {
      await pc.close();
      await pc.dispose();
      return;
    }
    link.connection = pc;
    pc.onIceCandidate = (candidate) {
      if (candidate.candidate?.isNotEmpty == true) {
        unawaited(
          _signal(link, {
            'type': 'candidate',
            'candidate': candidate.candidate,
            'sdpMid': candidate.sdpMid,
            'sdpMLineIndex': candidate.sdpMLineIndex,
          }).catchError(onError),
        );
      }
    };
    pc.onTrack = (event) {
      if (link.outgoing || event.track.kind != 'video') {
        unawaited(event.track.stop());
        unawaited(stop(link.id));
        return;
      }
      if (event.streams.isNotEmpty) {
        unawaited(_render(link, event.streams.first).catchError(onError));
      }
    };
    pc.onConnectionState = (state) {
      link.connected =
          state == RTCPeerConnectionState.RTCPeerConnectionStateConnected;
      if (link.connected && !link.reportedConnected) {
        link.reportedConnected = true;
        unawaited(
          api
              .call({'op': 'media_state', 'id': link.id, 'state': 'connected'})
              .catchError((Object error) {
                onError(error);
                return <String, dynamic>{};
              }),
        );
      }
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        unawaited(stop(link.id));
        onError(StateError('Screen connection failed'));
      }
      _changed();
    };
  }

  Future<void> _render(ScreenLink link, MediaStream stream) async {
    final renderer = RTCVideoRenderer();
    await renderer.initialize();
    if (!links.containsKey(link.id)) {
      await renderer.dispose();
      return;
    }
    await link.renderer?.dispose();
    link.renderer = renderer;
    renderer.srcObject = stream;
    _changed();
  }

  Future<void> _offer(ScreenLink link) async {
    try {
      await _connect(link);
      if (!links.containsKey(link.id)) return;
      for (final track in link.stream!.getVideoTracks()) {
        await link.connection!.addTrack(track, link.stream!);
      }
      for (final t in await link.connection!.getTransceivers()) {
        await t.setDirection(TransceiverDirection.SendOnly);
      }
      final offer = await link.connection!.createOffer({
        'offerToReceiveAudio': false,
        'offerToReceiveVideo': false,
      });
      validateMediaSdp(offer.sdp ?? '', video: true, direction: 'sendonly');
      await link.connection!.setLocalDescription(offer);
      await _signal(link, {'type': 'offer', 'sdp': offer.sdp});
    } catch (error) {
      await stop(link.id);
      if (!_disposed) onError(error);
    }
  }

  Future<void> _receive(ScreenLink link, Map<String, dynamic> signal) async {
    if (signal['type'] == 'candidate') {
      final candidate = RTCIceCandidate(
        signal['candidate'] as String?,
        signal['sdpMid'] as String?,
        signal['sdpMLineIndex'] as int?,
      );
      if (link.remoteReady) {
        await link.connection!.addCandidate(candidate);
      } else {
        if (link.candidates.length >= 128) {
          throw StateError('Screen candidate queue full');
        }
        link.candidates.add(candidate);
      }
      return;
    }
    final type = signal['type'];
    if ((type == 'offer' && link.outgoing) ||
        (type == 'answer' && !link.outgoing) ||
        !['offer', 'answer'].contains(type)) {
      throw StateError('Invalid screen signal direction');
    }
    final sdp = signal['sdp'] as String;
    validateMediaSdp(
      sdp,
      video: true,
      direction: link.outgoing ? 'recvonly' : 'sendonly',
    );
    await _connect(link);
    await link.connection!.setRemoteDescription(
      RTCSessionDescription(sdp, type as String),
    );
    link.remoteReady = true;
    for (final candidate in link.candidates) {
      await link.connection!.addCandidate(candidate);
    }
    link.candidates.clear();
    if (!link.outgoing) {
      for (final t in await link.connection!.getTransceivers()) {
        await t.setDirection(TransceiverDirection.RecvOnly);
      }
      final answer = await link.connection!.createAnswer();
      validateMediaSdp(answer.sdp ?? '', video: true, direction: 'recvonly');
      await link.connection!.setLocalDescription(answer);
      await _signal(link, {'type': 'answer', 'sdp': answer.sdp});
    }
    _changed();
  }

  Future<void> _signal(ScreenLink link, Map<String, dynamic> data) {
    if (!links.containsKey(link.id)) return Future.value();
    if (link.queuedSignals >= 128) {
      return Future.error(StateError('Screen signal queue full'));
    }
    link.queuedSignals++;
    final task = link.signals
        .then((_) async {
          if (links.containsKey(link.id)) {
            await api.call({
              'op': 'media_send',
              'peer_id': link.peer,
              'id': link.id,
              'data': data,
            });
          }
        })
        .whenComplete(() {
          link.queuedSignals--;
        });
    link.signals = task.catchError((Object _) {});
    return task;
  }

  Future<void> _releaseCapture(MediaStream capture) async {
    if (identical(_mobileCapture, capture)) _mobileCapture = null;
    for (final track in capture.getTracks()) {
      track.onEnded = null;
      await track.stop();
    }
    await capture.dispose();
  }

  Future<void> stop(String id, {bool notify = true}) async {
    final link = links.remove(id);
    if (link == null) return;
    await link.connection?.close();
    await link.connection?.dispose();
    await link.renderer?.dispose();
    final capture = link.stream;
    if (capture != null &&
        !links.values.any((l) => identical(l.stream, capture))) {
      await _releaseCapture(capture);
    }
    if (Platform.isAndroid && _mobileCapture == null) {
      await const MethodChannel(
        'dev.narad/android',
      ).invokeMethod<void>('screenProjection', {'enabled': false});
    }
    await link.releaseDisplay?.call();
    if (notify) {
      try {
        await api.call({'op': 'session_stop', 'peer_id': link.peer, 'id': id});
      } catch (_) {}
    }
    _changed();
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void>? _shutdown;
  Future<void> shutdown() => _shutdown ??= _shutdownNow();
  Future<void> _shutdownNow() async {
    for (final id in links.keys.toList()) {
      await stop(id);
    }
    enabled = false;
    await api.call({'op': 'screen_ready', 'ready': false});
    _disposed = true;
    super.dispose();
  }
}
