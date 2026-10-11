/// KhataPro · SDP surgery, as pure text.
///
/// A QR code has to carry a whole WebRTC description, and a full one is a few
/// kilobytes of codec offers for media neither phone will ever send. Cutting it down
/// is therefore not an optimisation — it is what makes the pairing code scannable.
///
/// It is also the most dangerous text handling in the project, because the failure is
/// silent: a description missing `a=sctp-port` still *looks* like an SDP, still
/// encodes into a ticket, still scans, and then the data channel never opens. There is
/// no error message anywhere in that path; the phones just sit there. So:
///
///  * the keep-list is explicit and commented per line, and
///  * the result is **validated** — [minimiseDataChannelSdp] refuses to return a
///    description that cannot carry a data channel, and
///  * the whole file is pure Dart, so `tool/sync_verify.dart` runs it against real
///    SDP text (recorded from a Chrome/libwebrtc data-channel session) instead of
///    trusting it.
///
/// Two rules about the direction of travel: descriptions are minimised on the way
/// *into a ticket* only. `setLocalDescription`/`setRemoteDescription` must always get
/// the stack's own text — handing libwebrtc a hand-edited description is how you get a
/// connection that pretends to negotiate and then times out.
library;

import '../../core/errors/khata_exception.dart';

/// The session-level and data-channel lines a non-trickle, data-only description
/// needs. Everything else is media noise or a renegotiation affordance we do not use.
const List<String> _keepPrefixes = [
  'v=', // SDP version — a description without it is not parseable.
  'o=', // origin, including the session id the far side echoes back.
  's=', // session name; must be present even when empty.
  't=', // timing; "0 0" means unbounded.
  'a=group:BUNDLE', // the m-line is bundled into one transport.
  'm=application', // the data channel's media line. Without this there is no channel.
  'c=', // connection line, required per m-section on some stacks.
  'a=ice-ufrag',
  'a=ice-pwd',
  'a=fingerprint', // the DTLS certificate hash — the actual identity of the peer.
  'a=setup',
  'a=mid',
  'a=sctp-port', // <-- the one everybody forgets. No SCTP port, no data channel.
  'a=max-message-size',
  'a=candidate',
  'a=end-of-candidates',
];

/// Labels for the lines that must survive, used by the validator.
const List<String> _requiredPrefixes = ['m=application', 'a=sctp-port', 'a=ice-ufrag', 'a=fingerprint'];

/// The failure for a description that cannot carry a data channel. A pairing ticket
/// is never produced from one, so a broken description fails at the phone in the hand
/// rather than at the phone across the room — and it carries a code (`PAIR-6`) because
/// "pairing produced a description that cannot carry a data channel" is a bug report
/// somebody has to be able to file.
InvariantViolation _sdpFailure(String message) =>
    InvariantViolation(invariantCode: 'PAIR-6', message: message);

/// Keeps only the lines a data-channel-only connection needs, in order.
///
/// Refuses (rather than silently degrades) when a required line is missing: a
/// description without `a=sctp-port` or `a=fingerprint` is not a smaller description,
/// it is a broken one.
String minimiseDataChannelSdp(String sdp) {
  final kept = <String>[];
  for (final line in _lines(sdp)) {
    if (_keepPrefixes.any(line.startsWith)) kept.add(line);
  }
  final result = kept.join('\r\n');
  for (final required in _requiredPrefixes) {
    if (!kept.any((line) => line.startsWith(required))) {
      throw _sdpFailure(
        'the description has no "$required" line, so it cannot carry a data channel. '
        'The connection would negotiate and then never open.',
      );
    }
  }
  return result;
}

/// The host candidate lines in a description. Host-only is the point: a reflexive or
/// relayed candidate means a STUN/TURN server was involved, and this app has none.
List<String> hostCandidates(String sdp) => [
      for (final line in _lines(sdp))
        if (line.startsWith('a=candidate') && line.contains(' typ host')) line,
    ];

/// Appends [candidates] to [sdp] unless they are already there, then closes the
/// section with `a=end-of-candidates`.
///
/// Idempotent by construction: the offerer may see the same candidate twice (once
/// from `getLocalDescription`, once from the `onIceCandidate` callback) and a
/// duplicated candidate line is a description some stacks reject.
String mergeCandidates(String sdp, List<String> candidates) {
  final lines = _lines(sdp).toList();
  final present = lines.where((line) => line.startsWith('a=candidate')).toSet();
  for (final candidate in candidates) {
    if (present.contains(candidate)) continue;
    lines.add(candidate);
  }
  if (!lines.any((line) => line.startsWith('a=end-of-candidates'))) {
    lines.add('a=end-of-candidates');
  }
  return lines.join('\r\n');
}

/// True when a description has the shape of a data-channel description. Used by the
/// ticket decoder to reject a scanned code that is not one.
bool looksLikeDataChannelSdp(String sdp) =>
    _requiredPrefixes.every((prefix) => _lines(sdp).any((line) => line.startsWith(prefix)));

/// SDP is CRLF-delimited, but a description that has been through a QR encoder, a
/// JSON round trip or a clipboard may arrive with bare newlines — and a `\r\n` split
/// on `\n`-only text yields one enormous line, which would then fail every prefix
/// test and look like a missing SCTP port.
Iterable<String> _lines(String sdp) => sdp
    .split('\n')
    .map((line) => line.endsWith('\r') ? line.substring(0, line.length - 1) : line)
    .where((line) => line.trim().isNotEmpty);
