/// Analyzer stub for `package:flutter_webrtc` 1.6.2+hotfix.4.
///
/// Signatures transcribed from the package and from `webrtc_interface` 1.5.1, which
/// is where these types actually live and which `flutter_webrtc` re-exports. Three
/// members here are worth pointing at, because each was a live bug in this project:
///
///  * `setLocalDescription` returns **`Future<void>`** — it does not hand back a
///    description, so a caller that wants the gathered candidates must call
///    `getLocalDescription()` (also on this stub, and also `Future`-returning);
///  * `getBufferedAmount()` is **asynchronous**, because the value lives in the
///    native peer connection;
///  * `RTCSessionDescription` takes **positional** arguments.
library;

import 'dart:typed_data';

class RTCSessionDescription {
  RTCSessionDescription(this.sdp, this.type);

  String? sdp;
  String? type;

  Map<String, dynamic> toMap() => {'sdp': sdp, 'type': type};
}

class RTCIceCandidate {
  RTCIceCandidate(this.candidate, this.sdpMid, this.sdpMLineIndex);

  final String? candidate;
  final String? sdpMid;
  final int? sdpMLineIndex;
}

class RTCDataChannelInit {
  bool ordered = true;
  int maxRetransmitTime = -1;
  int maxRetransmits = -1;
  String protocol = 'sctp';
  bool negotiated = false;
  int id = 0;
}

class RTCDataChannelMessage {
  RTCDataChannelMessage(String text) : _data = text, _isBinary = false;

  RTCDataChannelMessage.fromBinary(Uint8List binary)
      : _data = binary,
        _isBinary = true;

  final dynamic _data;
  final bool _isBinary;

  bool get isBinary => _isBinary;
  String get text => _data;
  Uint8List get binary => _data;
}

abstract class RTCDataChannel {
  String? get label;
  int? get id;
  int? get bufferedAmount;
  Future<int> getBufferedAmount() => throw UnimplementedError('stub');
  int? bufferedAmountLowThreshold;
  Function(RTCDataChannelState state)? onDataChannelState;
  Function(RTCDataChannelMessage data)? onMessage;
  Function(int currentAmount)? onBufferedAmountLow;
  Future<void> send(RTCDataChannelMessage message);
  Future<void> close();
}

abstract class RTCPeerConnection {
  RTCDataChannelState? get connectionState;
  RTCIceGatheringState? get iceGatheringState;
  Function(RTCPeerConnectionState state)? onConnectionState;
  Function(RTCIceGatheringState state)? onIceGatheringState;
  Function(RTCIceCandidate candidate)? onIceCandidate;
  Function(RTCDataChannel channel)? onDataChannel;
  Future<RTCSessionDescription> createOffer([Map<String, dynamic> constraints]);
  Future<RTCSessionDescription> createAnswer([Map<String, dynamic> constraints]);
  Future<void> setLocalDescription(RTCSessionDescription description);
  Future<void> setRemoteDescription(RTCSessionDescription description);
  Future<RTCSessionDescription?> getLocalDescription();
  Future<RTCSessionDescription?> getRemoteDescription();
  Future<void> addCandidate(RTCIceCandidate candidate);
  Future<RTCDataChannel> createDataChannel(String label, [RTCDataChannelInit? dataChannelInit]);
  Future<void> close();
}

Future<RTCPeerConnection> createPeerConnection(
  Map<String, dynamic> configuration, [
  Map<String, dynamic> constraints = const {},
]) =>
    throw UnimplementedError('stub');

enum RTCDataChannelState { connecting, open, closing, closed }

enum RTCIceGatheringState {
  RTCIceGatheringStateNew,
  RTCIceGatheringStateGathering,
  RTCIceGatheringStateComplete,
}

enum RTCPeerConnectionState {
  RTCPeerConnectionStateClosed,
  RTCPeerConnectionStateFailed,
  RTCPeerConnectionStateDisconnected,
  RTCPeerConnectionStateNew,
  RTCPeerConnectionStateConnecting,
  RTCPeerConnectionStateConnected,
}
