/// KhataPro · the CRDT envelope that travels with every replicated row.
///
/// `(hlc, node_id, rev)` — three columns, added to every mutable replicated
/// table by the migrations. `hlc` alone would be enough for the maths; `rev`
/// exists because humans and diagnostics need a "how many times has this row
/// been touched" counter, and because a per-writer revision sequence lets the
/// merge detect a rolled-back replica (a phone restored from a stale backup)
/// instead of quietly accepting its ancient write.
///
/// Pure Dart, no `package:` imports.
library;

import 'hlc.dart';

/// A row's causal position: the hybrid clock reading plus the writer's own
/// revision counter.
final class CrdtStamp implements Comparable<CrdtStamp> {
  const CrdtStamp({required this.hlc, required this.rev});

  final Hlc hlc;

  /// Monotonically increasing per (row, writer). Descriptive for ordering —
  /// the authoritative order is [hlc] — but load-bearing as a *consistency
  /// check*: for one writer, rev must grow with hlc, and a violation means the
  /// peer's state was rolled back.
  final int rev;

  String get nodeId => hlc.nodeId;

  /// Ordering is by HLC **only**. `rev` is deliberately excluded: revision
  /// counters from two different writers are not comparable, and a comparator
  /// that mixed them would give different answers on different devices — the
  /// exact failure mode a CRDT must not have.
  @override
  int compareTo(CrdtStamp other) => hlc.compareTo(other.hlc);

  bool operator <(CrdtStamp other) => compareTo(other) < 0;
  bool operator >(CrdtStamp other) => compareTo(other) > 0;
  bool operator <=(CrdtStamp other) => compareTo(other) <= 0;
  bool operator >=(CrdtStamp other) => compareTo(other) >= 0;

  /// Same writing device (used by the revision-monotonicity guard).
  bool sameWriter(CrdtStamp other) => hlc.nodeId == other.hlc.nodeId;

  /// The stamp to write when this device updates the row.
  CrdtStamp bump(HlcClock clock, int nowMs) =>
      CrdtStamp(hlc: clock.tick(nowMs), rev: rev + 1);

  /// Fresh stamp for a brand-new row.
  static CrdtStamp create(HlcClock clock, int nowMs) =>
      CrdtStamp(hlc: clock.tick(nowMs), rev: 1);

  CrdtStamp withHlc(Hlc newHlc) => CrdtStamp(hlc: newHlc, rev: rev);

  /// Column values as they appear in the database.
  Map<String, Object?> toColumns() => {
        'hlc': hlc.encode(),
        'node_id': hlc.nodeId,
        'rev': rev,
      };

  /// Rebuilds a stamp from a query row. Accepts either an encoded string or a
  /// pre-parsed [Hlc] so both DAO styles work.
  static CrdtStamp fromColumns(Map<String, Object?> row) {
    final rawHlc = row['hlc'];
    final hlc = rawHlc is Hlc ? rawHlc : Hlc.parse(rawHlc as String);
    final rawRev = row['rev'];
    // `value` below is a switch PATTERN variable, not a local — it cannot be
    // declared final, and the lint (a known false positive for patterns) is
    // silenced on the arm rather than for the file.
    final rev = switch (rawRev) {
      // ignore: prefer_final_locals
      int value => value,
      // ignore: prefer_final_locals
      String value => int.parse(value),
      null => 1,
      _ => throw FormatException('rev must be an integer, got ${rawRev.runtimeType}'),
    };
    if (rev < 1) throw FormatException('rev must be >= 1, got $rev');
    return CrdtStamp(hlc: hlc, rev: rev);
  }

  @override
  // ignore: avoid_equals_and_hash_code_on_mutable_classes
  // A value type: every field is final and instances are compared by
  // value. The class stays free of package imports so it can run in a
  // bare Dart process (see tool/crdt_verify.dart).
  bool operator ==(Object other) =>
      other is CrdtStamp && other.hlc == hlc && other.rev == rev;

  @override
  // ignore: avoid_equals_and_hash_code_on_mutable_classes
  // A value type: every field is final and instances are compared by
  // value. The class stays free of package imports so it can run in a
  // bare Dart process (see tool/crdt_verify.dart).
  int get hashCode => Object.hash(hlc, rev);

  @override
  String toString() => '${hlc.encode()}#$rev';
}

/// A replicated row: identity, causal position, payload.
///
/// [values] holds the domain columns only. The CRDT bookkeeping columns
/// (`hlc`, `node_id`, `rev`, `updated_at`) are excluded from [payload] so that
/// "did the content change?" comparisons, and the per-field conflict receipts
/// written to `conflict_log`, are not polluted by the stamp itself — every
/// stamp differs from every other by definition.
final class StampedRow {
  const StampedRow({
    required this.rowId,
    required this.stamp,
    required this.values,
    this.deletedAt,
    this.tableName,
  });

  final String rowId;
  final CrdtStamp stamp;
  final Map<String, Object?> values;

  /// Epoch-ms tombstone. Non-null means "deleted", and the delete itself is
  /// just another LWW write — a delete that arrives after a newer edit loses,
  /// which is how a party restored on one device is not killed again by a
  /// stale tombstone from another.
  final int? deletedAt;

  /// For conflict receipts and the oplog (`party`, `item`, `document`, …).
  final String? tableName;

  bool get isDeleted => deletedAt != null;

  /// Columns that every replicated row carries but that never constitute a
  /// *content* difference.
  static const Set<String> bookkeepingFields = <String>{
    'hlc',
    'node_id',
    'rev',
    'updated_at',
    'created_at',
    'id',
  };

  /// Domain columns only, tombstone included when present.
  Map<String, Object?> get payload {
    final map = <String, Object?>{};
    for (final entry in values.entries) {
      if (bookkeepingFields.contains(entry.key)) continue;
      map[entry.key] = entry.value;
    }
    if (deletedAt != null) map['deleted_at'] = deletedAt;
    return map;
  }

  /// Deterministic serialisation of the payload — the basis of the
  /// "did anything actually change?" test that keeps the conflict log honest.
  String canonicalPayload() => canonicalJson(payload);

  /// True when the two rows carry the same content (stamps may differ).
  bool sameContent(StampedRow other) =>
      isDeleted == other.isDeleted && canonicalPayload() == other.canonicalPayload();

  StampedRow copyWith({Map<String, Object?>? values, int? deletedAt, CrdtStamp? stamp}) =>
      StampedRow(
        rowId: rowId,
        stamp: stamp ?? this.stamp,
        values: values ?? this.values,
        deletedAt: deletedAt ?? this.deletedAt,
        tableName: tableName,
      );

  @override
  String toString() => 'StampedRow(${tableName ?? '?'}/$rowId @ $stamp)';
}

/// Canonical JSON: sorted keys, no whitespace, integers only.
///
/// "Canonical" here means *byte-identical on every platform and every Dart
/// version*, which is what lets two devices compare payloads for equality.
/// `jsonEncode` alone is not enough — a `Map` iterates in insertion order, and
/// two devices will have built their maps in different orders.
///
/// Doubles are **rejected**, not rounded: a double in a payload means a float
/// leaked into money or quantities somewhere upstream, and this is the last
/// line of defence that catches it before it reaches the sync wire.
String canonicalJson(Object? value) {
  final buffer = StringBuffer();
  _writeCanonical(buffer, value);
  return buffer.toString();
}

void _writeCanonical(StringBuffer buffer, Object? value) {
  switch (value) {
    case null:
      buffer.write('null');
    case bool():
      buffer.write(value ? 'true' : 'false');
    case int():
      buffer.write(value.toString());
    case String():
      buffer.write(_encodeString(value));
    case List<Object?>():
      buffer.write('[');
      for (var i = 0; i < value.length; i++) {
        if (i > 0) buffer.write(',');
        _writeCanonical(buffer, value[i]);
      }
      buffer.write(']');
    case Map<Object?, Object?>():
      final keys = value.keys.map((k) => k.toString()).toList()..sort();
      buffer.write('{');
      for (var i = 0; i < keys.length; i++) {
        if (i > 0) buffer.write(',');
        final key = keys[i];
        buffer
          ..write(_encodeString(key))
          ..write(':');
        _writeCanonical(buffer, value[key]);
      }
      buffer.write('}');
    default:
      throw ArgumentError(
        'canonicalJson: unsupported type ${value.runtimeType}. Payloads must be '
        'composed of null, bool, int, String, List and Map — money and '
        'quantities are integers of minor units, never doubles.',
      );
  }
}

/// JSON string escaping (RFC 8259) for the subset of characters Dart strings
/// can contain. Hand-rolled rather than delegated to `jsonEncode` so this file
/// keeps zero package dependencies and its behaviour is pinned by tests.
String _encodeString(String value) {
  final buffer = StringBuffer('"');
  for (final unit in value.codeUnits) {
    switch (unit) {
      case 0x22:
        buffer.write(r'\"');
      case 0x5C:
        buffer.write(r'\\');
      case 0x08:
        buffer.write(r'\b');
      case 0x0C:
        buffer.write(r'\f');
      case 0x0A:
        buffer.write(r'\n');
      case 0x0D:
        buffer.write(r'\r');
      case 0x09:
        buffer.write(r'\t');
      default:
        if (unit < 0x20) {
          buffer.write('\\u${unit.toRadixString(16).padLeft(4, '0')}');
        } else {
          buffer.writeCharCode(unit);
        }
    }
  }
  buffer.write('"');
  return buffer.toString();
}
