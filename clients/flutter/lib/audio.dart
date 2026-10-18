import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'api.dart';
import 'dart:io';
import 'camera_tools.dart';

class AudioLink {
  AudioLink(
    this.id,
    this.peer,
    this.outgoing, {
    this.camera = false,
    this.withAudio = false,
    this.remoteMicrophone = false,
    this.inputDeviceId,
    this.systemAudio = false,
  });
  final String id;
  final String peer;
  final bool outgoing;
  final bool camera;
  final bool withAudio;
  final bool remoteMicrophone;
  final String? inputDeviceId;
  final bool systemAudio;
  RTCPeerConnection? connection;
  MediaStream? microphone;
  MediaStream? cameraOriginalAudio;
  RTCVideoRenderer? renderer;
  CameraTools? tools;
  MediaStreamTrack? cameraVideo, cameraAudio;
  bool switching = false;
  String? cameraDevice;
  bool remoteReady = false;
  bool starting = false;
  final List<RTCIceCandidate> candidates = [];
}

class AudioController {
  AudioController(this.api, this.onError) {
    if (Platform.isAndroid) {
      const MethodChannel('dev.narad/media').setMethodCallHandler((call) async {
        if (call.method == 'stopped') {
          enabled = false;
          cameraEnabled = false;
          microphoneEnabled = false;
          for (final id in links.keys.toList()) {
            await stop(id, notify: false);
          }
        }
      });
    }
  }
  final NaradApi api;
  final void Function(Object) onError;
  final Map<String, AudioLink> links = {};
  final List<CameraTools> savedCameras = [];
  bool enabled = false;
  bool cameraEnabled = false;
  bool microphoneEnabled = false;
  String? playbackDeviceId;
  bool speakerphone = true;

  Future<void> setSpeakerphone(bool value) async {
    await Helper.setSpeakerphoneOn(value);
    speakerphone = value;
  }

  Future<void> selectPlaybackDevice(String id) async {
    await Helper.selectAudioOutput(id);
    playbackDeviceId = id;
  }

  CameraTools cameraTools(AudioLink link) {
    if (!link.camera || !link.outgoing) {
      throw StateError(
        'Camera viewing tools are available only on the requesting device',
      );
    }
    return link.tools ??= CameraTools(
      () {
        if (link.cameraVideo != null) return link.cameraVideo!;
        final tracks =
            (link.microphone ?? link.renderer?.srcObject)?.getVideoTracks() ??
            [];
        if (tracks.isEmpty) throw StateError('Wait for camera video');
        return tracks.first;
      },
      onError,
      audioTrack: link.withAudio
          ? () {
              if (link.cameraAudio == null) {
                throw StateError('Wait for camera audio');
              }
              return link.cameraAudio!;
            }
          : null,
    );
  }

  Future<void> switchCamera(String id) async {
    final link = links[id];
    if (link == null || !link.camera || link.connection == null) {
      throw StateError('Camera is not connected');
    }
    if (link.outgoing) {
      await _signal(link, {'type': 'camera_switch'});
      return;
    }
    if (link.switching) return;
    if (link.tools?.recording == true) {
      throw StateError('Stop recording before switching the source camera');
    }
    link.switching = true;
    try {
      final stream = link.microphone;
      if (stream == null) throw StateError('Camera is not capturing');
      if (Platform.isAndroid || Platform.isIOS) {
        await Helper.switchCamera(stream.getVideoTracks().first);
      } else {
        final devices = (await navigator.mediaDevices.enumerateDevices())
            .where((d) => d.kind == 'videoinput')
            .toList();
        if (devices.length < 2) {
          throw StateError('No other camera is available');
        }
        final current =
            link.cameraDevice ??
            stream.getVideoTracks().first.getSettings()['deviceId']?.toString();
        var index = devices.indexWhere((d) => d.deviceId == current);
        if (index < 0) index = 0;
        final next = devices[(index + 1) % devices.length];
        final replacement = await navigator.mediaDevices.getUserMedia({
          'audio': false,
          'video': {'deviceId': next.deviceId},
        });
        try {
          if (!links.containsKey(id)) throw StateError('Camera session ended');
          final sender = (await link.connection!.getSenders()).firstWhere(
            (s) => s.track?.kind == 'video',
          );
          await sender.replaceTrack(replacement.getVideoTracks().first);
          link.microphone = replacement;
          link.cameraDevice = next.deviceId;
          for (final track in stream.getVideoTracks()) {
            await track.stop();
          }
          if (link.withAudio && stream.getAudioTracks().isNotEmpty) {
            link.cameraOriginalAudio = stream;
          } else {
            await stream.dispose();
          }
        } catch (_) {
          for (final track in replacement.getTracks()) {
            await track.stop();
          }
          await replacement.dispose();
          rethrow;
        }
      }
    } finally {
      link.switching = false;
    }
  }

  Future<void> _prepareBackground(
    bool camera,
    bool microphone, {
    bool? playback,
  }) async {
    if (Platform.isAndroid) {
      await const MethodChannel('dev.narad/media').invokeMethod<void>(
        'prepare',
        {
          'camera': camera,
          'audio': microphone,
          'playback': playback ?? enabled,
        },
      );
    }
  }

  Future<void> _advertise() async {
    await api.call({
      'op': 'media_ready',
      'ready': enabled || cameraEnabled,
      'audio_ready': enabled,
      'microphone_ready': microphoneEnabled,
      'camera_ready': cameraEnabled,
    });
  }

  Future<void> setEnabled(bool value) async {
    if (value) {
      await _prepareBackground(
        cameraEnabled,
        microphoneEnabled,
        playback: true,
      );
    }
    enabled = value;
    if (!value) {
      microphoneEnabled = false;
      for (final link
          in links.values
              .where((l) => !l.camera || l.outgoing || l.withAudio)
              .toList()) {
        await stop(link.id);
      }
    }
    try {
      await _advertise();
    } finally {
      if (!value) {
        await _prepareBackground(cameraEnabled, false, playback: false);
      }
    }
  }

  Future<void> setMicrophoneEnabled(bool value) async {
    if (value) {
      await _prepareBackground(cameraEnabled, true, playback: true);
      enabled = true;
    }
    microphoneEnabled = value;
    if (!value) {
      for (final link
          in links.values
              .where(
                (l) =>
                    (l.withAudio && !l.outgoing) ||
                    (!l.camera &&
                        ((l.remoteMicrophone && !l.outgoing) ||
                            (!l.remoteMicrophone &&
                                l.outgoing &&
                                !l.systemAudio))),
              )
              .toList()) {
        await stop(link.id);
      }
    }
    try {
      await _advertise();
    } finally {
      if (!value) await _prepareBackground(cameraEnabled, false);
    }
  }

  Future<void> setCameraEnabled(bool value) async {
    if (value) await _prepareBackground(true, microphoneEnabled);
    cameraEnabled = value;
    if (!value) {
      for (final link
          in links.values.where((l) => l.camera && !l.outgoing).toList()) {
        await stop(link.id);
      }
    }
    try {
      await _advertise();
    } finally {
      if (!value) await _prepareBackground(false, microphoneEnabled);
    }
  }

  Future<String> startCamera(String peer, {bool withAudio = false}) async {
    if (!enabled) await setEnabled(true);
    final result = await api.call({
      'op': 'media_start',
      'peer_id': peer,
      'kind': 'camera',
      'with_audio': withAudio,
    });
    final id = result['id'] as String;
    links[id] = AudioLink(id, peer, true, camera: true, withAudio: withAudio);
    return id;
  }

  Future<String> start(
    String peer, {
    String? inputDeviceId,
    bool systemAudio = false,
  }) async {
    if (systemAudio && (inputDeviceId == null || inputDeviceId.isEmpty)) {
      throw StateError('Select an explicit system audio capture device first');
    }
    if (links.values.any(
      (l) => l.outgoing && !l.camera && !l.remoteMicrophone,
    )) {
      throw StateError(
        'Stop the current audio send before changing its capture source',
      );
    }
    if (!enabled) await setEnabled(true);
    if (!systemAudio && !microphoneEnabled) await setMicrophoneEnabled(true);
    final result = await api.call({'op': 'media_start', 'peer_id': peer});
    final id = result['id'] as String;
    links[id] = AudioLink(
      id,
      peer,
      true,
      inputDeviceId: inputDeviceId,
      systemAudio: systemAudio,
    );
    return id;
  }

  Future<String> requestMicrophone(String peer) async {
    if (!enabled) await setEnabled(true);
    final result = await api.call({
      'op': 'media_start',
      'peer_id': peer,
      'kind': 'microphone',
    });
    final id = result['id'] as String;
    links[id] = AudioLink(id, peer, true, remoteMicrophone: true);
    return id;
  }

  Future<void> tick(Map<String, dynamic> status) async {
    if (!enabled && !cameraEnabled) return;
    await _advertise();
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
        () => AudioLink(
          id,
          signal['peer_id'] as String,
          false,
          camera: session['capability'] == 'camera.stream',
          withAudio: session['with_audio'] == true,
          remoteMicrophone: session['capability'] == 'audio.input',
        ),
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
      if (!link.camera && !link.remoteMicrophone) {
        if (link.inputDeviceId != null) {
          final devices = await navigator.mediaDevices.enumerateDevices();
          if (!devices.any(
            (d) => d.kind == 'audioinput' && d.deviceId == link.inputDeviceId,
          )) {
            throw StateError(
              'Selected capture device disappeared. Refresh audio devices before retrying.',
            );
          }
        }
        final stream = await navigator.mediaDevices.getUserMedia({
          'audio': audioCaptureConstraints(
            inputDeviceId: link.inputDeviceId,
            systemAudio: link.systemAudio,
          ),
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
        // Keep the explicitly selected route when additional capture starts.
        if (playbackDeviceId != null) {
          await Helper.selectAudioOutput(playbackDeviceId!);
        }
        await api.call({'op': 'session_touch', 'id': link.id});
        for (final track in stream.getAudioTracks()) {
          await link.connection!.addTrack(track, stream);
        }
        for (final transceiver in await link.connection!.getTransceivers()) {
          await transceiver.setDirection(TransceiverDirection.SendOnly);
        }
      } else {
        await link.connection!.addTransceiver(
          kind: link.camera
              ? RTCRtpMediaType.RTCRtpMediaTypeVideo
              : RTCRtpMediaType.RTCRtpMediaTypeAudio,
          init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
        );
      }
      if (link.withAudio) {
        await link.connection!.addTransceiver(
          kind: RTCRtpMediaType.RTCRtpMediaTypeAudio,
          init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
        );
      }
      if (!links.containsKey(link.id)) return;
      final offer = await link.connection!.createOffer({
        'offerToReceiveAudio': link.remoteMicrophone || link.withAudio,
        'offerToReceiveVideo': link.camera,
      });
      validateMediaSdp(
        offer.sdp ?? '',
        video: link.camera,
        withAudio: link.withAudio,
        direction: (link.camera || link.remoteMicrophone)
            ? 'recvonly'
            : 'sendonly',
      );
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
    var trackEvents = Future<void>.value();
    pc.onTrack = (event) {
      trackEvents = trackEvents
          .then((_) async {
            if (!links.containsKey(link.id)) return;
            final receives = (link.camera || link.remoteMicrophone)
                ? link.outgoing
                : !link.outgoing;
            if (!receives ||
                !(event.track.kind == (link.camera ? 'video' : 'audio') ||
                    (link.withAudio && event.track.kind == 'audio'))) {
              await event.track.stop();
              await stop(link.id);
              onError(StateError('Unexpected media track for this permission'));
              return;
            }
            if (event.streams.isEmpty) return;
            if (link.camera) {
              if (event.track.kind == 'video') link.cameraVideo = event.track;
              if (event.track.kind == 'audio') link.cameraAudio = event.track;
              if (event.track.kind == 'audio' &&
                  link.cameraVideo != null &&
                  link.renderer != null) {
                if (playbackDeviceId != null) {
                  await Helper.selectAudioOutput(playbackDeviceId!);
                }
                if (Platform.isAndroid || Platform.isIOS) {
                  await Helper.setSpeakerphoneOn(speakerphone);
                }
                return;
              }
            }
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
              if ((!link.camera || link.withAudio) &&
                  playbackDeviceId != null) {
                await Helper.selectAudioOutput(playbackDeviceId!);
              }
              if ((!link.camera || link.withAudio) &&
                  (Platform.isAndroid || Platform.isIOS)) {
                await Helper.setSpeakerphoneOn(speakerphone);
              }
            } catch (error) {
              await renderer.dispose();
              onError(error);
            }
          })
          .catchError((Object error) {
            if (links.containsKey(link.id)) onError(error);
          });
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
    if (data['type'] == 'camera_switch') {
      if (!link.camera || link.outgoing) {
        throw StateError('Invalid camera control direction');
      }
      try {
        await switchCamera(link.id);
        await _signal(link, {'type': 'camera_control_result', 'ok': true});
      } catch (e) {
        await _signal(link, {
          'type': 'camera_control_result',
          'ok': false,
          'error': e.toString(),
        });
      }
      return;
    }
    if (data['type'] == 'camera_control_result') {
      if (!link.camera || !link.outgoing) {
        throw StateError('Unexpected camera control response');
      }
      if (data['ok'] != true) {
        onError(
          StateError(data['error']?.toString() ?? 'Camera switch failed'),
        );
      }
      return;
    }
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
      validateMediaSdp(
        data['sdp'] as String,
        video: link.camera,
        withAudio: link.withAudio,
        direction: (link.camera || link.remoteMicrophone)
            ? 'recvonly'
            : 'sendonly',
      );
      await _connect(link);
      await link.connection!.setRemoteDescription(
        RTCSessionDescription(data['sdp'] as String, 'offer'),
      );
      if (link.camera || link.remoteMicrophone) {
        if ((link.remoteMicrophone || link.withAudio) && !microphoneEnabled) {
          throw StateError('Microphone sharing is disabled');
        }
        if (link.camera && !cameraEnabled) {
          throw StateError('Camera sharing is disabled');
        }
        final stream = await navigator.mediaDevices.getUserMedia({
          'audio': (link.remoteMicrophone || link.withAudio)
              ? audioCaptureConstraints()
              : false,
          'video': link.camera ? {'facingMode': 'environment'} : false,
        });
        if ((link.camera ? stream.getVideoTracks() : stream.getAudioTracks())
            .isEmpty) {
          for (final track in stream.getTracks()) {
            await track.stop();
          }
          await stream.dispose();
          throw StateError(
            'No usable capture device was found. Connect a device and allow Narad '
            'camera access in your device settings, then retry.',
          );
        }
        if (!links.containsKey(link.id)) {
          for (final track in stream.getTracks()) {
            await track.stop();
          }
          await stream.dispose();
          return;
        }
        link.microphone = stream;
        // Keep the explicitly selected route when additional capture starts.
        if (playbackDeviceId != null) {
          await Helper.selectAudioOutput(playbackDeviceId!);
        }
        await api.call({'op': 'session_touch', 'id': link.id});
        if (link.withAudio && stream.getAudioTracks().isEmpty) {
          for (final track in stream.getTracks()) {
            await track.stop();
          }
          await stream.dispose();
          throw StateError('No microphone track available');
        }
        for (final track
            in link.withAudio
                ? stream.getTracks()
                : link.camera
                ? stream.getVideoTracks()
                : stream.getAudioTracks()) {
          await link.connection!.addTrack(track, stream);
        }
      }
      link.remoteReady = true;
      await _drain(link);
      final answer = await link.connection!.createAnswer();
      validateMediaSdp(
        answer.sdp ?? '',
        video: link.camera,
        withAudio: link.withAudio,
        direction: (link.camera || link.remoteMicrophone)
            ? 'sendonly'
            : 'recvonly',
      );
      await link.connection!.setLocalDescription(answer);
      await _signal(link, {'type': 'answer', 'sdp': answer.sdp});
    } else if (data['type'] == 'answer') {
      if (!link.outgoing || link.connection == null || link.remoteReady) {
        throw StateError('Unexpected audio answer');
      }
      validateMediaSdp(
        data['sdp'] as String,
        video: link.camera,
        withAudio: link.withAudio,
        direction: (link.camera || link.remoteMicrophone)
            ? 'sendonly'
            : 'recvonly',
      );
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

  Future<void> _signalTail = Future<void>.value();
  int _pendingSignals = 0;
  Future<void> _signal(AudioLink link, Map<String, dynamic> data) {
    if (!links.containsKey(link.id)) return Future<void>.value();
    if (_pendingSignals >= 128) {
      return Future<void>.error(StateError('Too many pending media signals'));
    }
    _pendingSignals++;
    // Multiple peer connections gather ICE simultaneously. Keep this burst within
    // the daemon's bounded local API capacity, preserving offer/candidate order.
    final task = _signalTail
        .then((_) async {
          if (!links.containsKey(link.id)) return;
          await api.call({
            'op': 'media_send',
            'id': link.id,
            'peer_id': link.peer,
            'data': data,
          });
        })
        .whenComplete(() => _pendingSignals--);
    _signalTail = task.catchError((Object _) {});
    return task;
  }

  Future<void> stop(String id, {bool notify = true}) async {
    final link = links.remove(id);
    if (link == null) return;
    link.tools?.quiesce();
    await link.tools?.stopFeed();
    // Stop capture and playback before waiting for network teardown.
    try {
      for (final track
          in link.microphone?.getTracks() ?? <MediaStreamTrack>[]) {
        await track.stop();
      }
    } finally {
      if (link.tools != null) {
        await link.tools!.stop();
        if (link.tools!.completed.isNotEmpty) {
          savedCameras.add(link.tools!);
        } else {
          await link.tools!.dispose();
        }
      }
      try {
        await link.connection?.close();
        await link.connection?.dispose();
      } finally {
        await link.microphone?.dispose();
        for (final track
            in link.cameraOriginalAudio?.getTracks() ?? <MediaStreamTrack>[]) {
          await track.stop();
        }
        await link.cameraOriginalAudio?.dispose();
        await link.renderer?.dispose();
      }
    }
    if (notify) {
      try {
        await api
            .call({'op': 'session_stop', 'id': id, 'peer_id': link.peer})
            .timeout(const Duration(seconds: 2));
      } catch (_) {}
    }
    link.candidates.clear();
  }

  Future<void> dispose() async {
    enabled = false;
    cameraEnabled = false;
    microphoneEnabled = false;
    for (final id in links.keys.toList()) {
      try {
        await stop(id);
      } catch (error) {
        onError(error);
      }
    }
    try {
      for (final tools in savedCameras) {
        await tools.dispose();
      }
      savedCameras.clear();
      await _prepareBackground(false, false, playback: false);
      await api.call({'op': 'media_ready', 'ready': false});
    } catch (_) {}
  }
}

/// The native desktop plugin uses optional.sourceId for recording selection;
/// audio.deviceId means a playback endpoint there, so never put input IDs in it.
Map<String, dynamic> audioCaptureConstraints({
  String? inputDeviceId,
  bool systemAudio = false,
}) => {
  if (inputDeviceId != null)
    'optional': [
      {'sourceId': inputDeviceId},
    ],
  'echoCancellation': !systemAudio,
  'noiseSuppression': !systemAudio,
  'autoGainControl': !systemAudio,
};

/// A video-only or one-way audio grant must not negotiate additional capture or
/// playback. Validate before the native peer can create a receiver/decoder.
void validateMediaSdp(
  String sdp, {
  required bool video,
  bool withAudio = false,
  required String direction,
}) {
  final lines = sdp.split(RegExp(r'\r?\n'));
  final indices = <int>[];
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].startsWith('m=')) indices.add(i);
  }
  final expected = video
      ? <String>['video', if (withAudio) 'audio']
      : <String>['audio'];
  final actual = indices
      .map((i) => lines[i].substring(2).split(' ').first)
      .toList();
  if (indices.length != expected.length ||
      actual.toSet().length != expected.length ||
      !actual.toSet().containsAll(expected)) {
    throw StateError('Media description does not match the authorized tracks');
  }
  const modes = {'a=recvonly', 'a=sendonly', 'a=sendrecv', 'a=inactive'};
  for (var n = 0; n < indices.length; n++) {
    final index = indices[n];
    final end = n + 1 < indices.length ? indices[n + 1] : lines.length;
    var directions = lines
        .sublist(index + 1, end)
        .where(modes.contains)
        .toSet();
    if (directions.isEmpty) {
      directions = lines.take(indices.first).where(modes.contains).toSet();
    }
    if (directions.length != 1 || directions.single != 'a=$direction') {
      throw StateError('Media direction does not match this permission');
    }
  }
}
