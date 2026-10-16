/// Validated widget routing shared with the Android native action contract.
class DeviceWidgetAction {
  DeviceWidgetAction(this.peerId, this.action);
  final String peerId;
  final String action;
  static const actions = {
    'file',
    'clipboard',
    'audio',
    'camera',
    'browse',
    'command',
    'lock',
    'unlock',
    'settings',
    'unpair',
  };
  factory DeviceWidgetAction.parse(Map<String, dynamic> value) {
    final peer = value['peer_id'];
    final action = value['action'];
    if (peer is! String ||
        peer.isEmpty ||
        action is! String ||
        !actions.contains(action)) {
      throw const FormatException('Invalid device widget action');
    }
    return DeviceWidgetAction(peer, action);
  }
  Map<String, dynamic> peerFrom(Map<String, dynamic> status) {
    final peer = (status['paired'] as Map?)?[peerId]?['peer'];
    if (peer is! Map) {
      throw StateError(
        'This device is no longer paired. Choose another device in the widget.',
      );
    }
    if (action == 'unlock' && peer['platform'] == 'windows') {
      throw StateError('Unlock this Windows device locally.');
    }
    if (action != 'settings' &&
        action != 'unpair' &&
        (status['presence'] as Map?)?[peerId]?['online'] != true) {
      throw StateError(
        'This device is offline. Open Narad on both devices and retry.',
      );
    }
    return Map<String, dynamic>.from(peer);
  }
}
