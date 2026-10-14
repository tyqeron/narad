import 'dart:async';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'api.dart';

class AudioLink {
  AudioLink(this.id, this.peer, this.outgoing);
  final String id;
  final String peer;
  final bool outgoing;
  RTCPeerConnection? connection;
  MediaStream? microphone;
  RTCVideoRenderer? renderer;
  bool remoteReady = false;
  bool starting = false;
  final List<RTCIceCandidate> candidates = [];
}

class AudioController {
  AudioController(this.api, this.onError);
  final NaradApi api;
  final void Function(Object) onError;
  final Map<String, AudioLink> links = {};
  bool enabled = false;

  Future<void> setEnabled(bool value) async {
    if (!value) {
      enabled = false;
      for (final id in links.keys.toList()) {
        await stop(id, notify: false);
      }
    }
    await api.call({'op': 'media_ready', 'ready': value});
    enabled = value;
  }

  Future<String> start(String peer) async {
    if (!enabled) await setEnabled(true);
    final result = await api.call({'op': 'media_start', 'peer_id': peer});
    final id = result['id'] as String;
    links[id] = AudioLink(id, peer, true);
    return id;
  }

  Future<void> tick(Map<String, dynamic> status) async {
    if (!enabled) return;
    await api.call({'op': 'media_ready', 'ready': true});
    final sessions = (status['sessions'] as List).cast<Map<String, dynamic>>();
    final byId = {for (final s in sessions) s['id']: s};
    for (final link in links.values.toList()) {
      final session = byId[link.id];
      if (session == null ||
          ['closed', 'denied', 'failed'].contains(session['state'])) {
        await stop(link.id, notify: false);
        continue;
      }
      if (link.outgoing && link.connection == null && !link.starting) {
        final response = await api.call({
          'op': 'media_poll',
          'peer_id': link.peer,
          'id': link.id,
        });
        final state = (response['session'] as Map)['state'];
        if (state == 'authorized') {
          link.starting = true;
          unawaited(_startOutgoing(link));
        } else if (['closed', 'denied', 'failed'].contains(state)) {
          await stop(link.id, notify: false);
        }
      }
      if (links.containsKey(link.id)) {
        await api.call({'op': 'session_touch', 'id': link.id});
      }
    }
    final response = await api.call({'op': 'media_events'});
    for (final raw in response['signals'] as List) {
      final signal = raw as Map<String, dynamic>;
      final id = signal['session_id'] as String;
      final session = byId[id];
      if (session == null ||
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
        () => AudioLink(id, signal['peer_id'] as String, false),
      );
      try {
        await _receive(link, signal['data'] as Map<String, dynamic>);
      } catch (error) {
        await stop(id);
        onError(error);
      }
    }
  }

  Future<void> _startOutgoing(AudioLink link) async {
    try {
      await _connect(link);
      if (!links.containsKey(link.id)) return;
      final stream = await navigator.mediaDevices.getUserMedia({
        'audio': true,
        'video': false,
      });
      // A permission dialog can outlive a cancelled session.
      if (!links.containsKey(link.id)) {
        for (final track in stream.getTracks()) {
          await track.stop();
        }
        await stream.dispose();
        return;
      }
      link.microphone = stream;
      await api.call({'op': 'session_touch', 'id': link.id});
      for (final track in stream.getAudioTracks()) {
        await link.connection!.addTrack(track, stream);
      }
      if (!links.containsKey(link.id)) return;
      final offer = await link.connection!.createOffer({
        'offerToReceiveAudio': false,
        'offerToReceiveVideo': false,
      });
      await link.connection!.setLocalDescription(offer);
      await _signal(link, {'type': 'offer', 'sdp': offer.sdp});
    } catch (error) {
      final active = links.containsKey(link.id);
      await stop(link.id);
      if (active) onError(error);
    }
  }

  Future<void> _connect(AudioLink link) async {
    await api.call({
      'op': 'media_state',
      'id': link.id,
      'state': 'negotiating',
    });
    // Host candidates only: no STUN, TURN, account, or cloud signaling.
    final pc = await createPeerConnection({
      'iceServers': [],
      'sdpSemantics': 'unified-plan',
    });
    if (!links.containsKey(link.id)) {
      await pc.close();
      await pc.dispose();
      throw StateError('Audio session ended');
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
          }).catchError((Object error) async {
            onError(error);
            await stop(link.id);
          }),
        );
      }
    };
    pc.onTrack = (event) async {
      if (event.streams.isEmpty || !links.containsKey(link.id)) return;
      final renderer = RTCVideoRenderer();
      try {
        await renderer.initialize();
        if (!links.containsKey(link.id)) {
          await renderer.dispose();
          return;
        }
        await link.renderer?.dispose();
        link.renderer = renderer;
        renderer.srcObject = event.streams.first;
      } catch (error) {
        await renderer.dispose();
        onError(error);
      }
    };
    pc.onConnectionState = (state) async {
      if (!links.containsKey(link.id)) return;
      try {
        if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
          await api.call({
            'op': 'media_state',
            'id': link.id,
            'state': 'connected',
          });
          await api.call({
            'op': 'media_state',
            'id': link.id,
            'state': 'active',
          });
        } else if ([
          RTCPeerConnectionState.RTCPeerConnectionStateFailed,
          RTCPeerConnectionState.RTCPeerConnectionStateDisconnected,
        ].contains(state)) {
          await stop(link.id);
        }
      } catch (error) {
        onError(error);
        await stop(link.id);
      }
    };
  }

  Future<void> _receive(AudioLink link, Map<String, dynamic> data) async {
    if (data['type'] == 'candidate') {
      final candidate = RTCIceCandidate(
        data['candidate'] as String?,
        data['sdpMid'] as String?,
        data['sdpMLineIndex'] as int?,
      );
      if (!link.remoteReady) {
        if (link.candidates.length >= 128) {
          throw StateError('Too many ICE candidates');
        }
        link.candidates.add(candidate);
      } else {
        await link.connection!.addCandidate(candidate);
      }
      return;
    }
    if (data['type'] == 'offer') {
      if (link.outgoing || link.connection != null) {
        throw StateError('Unexpected audio offer');
      }
      await _connect(link);
      await link.connection!.setRemoteDescription(
        RTCSessionDescription(data['sdp'] as String, 'offer'),
      );
      link.remoteReady = true;
      await _drain(link);
      final answer = await link.connection!.createAnswer();
      await link.connection!.setLocalDescription(answer);
      await _signal(link, {'type': 'answer', 'sdp': answer.sdp});
    } else if (data['type'] == 'answer') {
      if (!link.outgoing || link.connection == null || link.remoteReady) {
        throw StateError('Unexpected audio answer');
      }
      await link.connection!.setRemoteDescription(
        RTCSessionDescription(data['sdp'] as String, 'answer'),
      );
      link.remoteReady = true;
      await _drain(link);
    } else {
      throw StateError('Unsupported audio signal');
    }
  }

  Future<void> _drain(AudioLink link) async {
    for (final candidate in link.candidates) {
      await link.connection!.addCandidate(candidate);
    }
    link.candidates.clear();
  }

  Future<void> _signal(AudioLink link, Map<String, dynamic> data) async {
    if (!links.containsKey(link.id)) return;
    await api.call({
      'op': 'media_send',
      'id': link.id,
      'peer_id': link.peer,
      'data': data,
    });
  }

  Future<void> stop(String id, {bool notify = true}) async {
    final link = links.remove(id);
    if (link == null) return;
    // Stop capture and playback before waiting for network teardown.
    try {
      for (final track
          in link.microphone?.getTracks() ?? <MediaStreamTrack>[]) {
        await track.stop();
      }
    } finally {
      try {
        await link.connection?.close();
        await link.connection?.dispose();
      } finally {
        await link.microphone?.dispose();
        await link.renderer?.dispose();
      }
    }
    if (notify) {
      try {
        await api.call({'op': 'session_stop', 'id': id, 'peer_id': link.peer});
      } catch (_) {}
    }
    link.candidates.clear();
  }

  Future<void> dispose() async {
    enabled = false;
    for (final id in links.keys.toList()) {
      await stop(id, notify: false);
    }
    try {
      await api.call({'op': 'media_ready', 'ready': false});
    } catch (_) {}
  }
}
