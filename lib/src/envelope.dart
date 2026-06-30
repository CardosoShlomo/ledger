import 'msg.dart';

/// Where a value/message came from — the app's OPEN, GLOBAL provenance. Extend
/// it with your own enum (`enum AppSource implements Source { remote, hive, … }`);
/// [CommonSource] ships the usual ones. Global, NOT per-registry: how a message
/// ARRIVED is one fact, identical for every registry that consumes it — so the
/// app wires its own set once, here, not per store.
///
/// Provenance is NOT the overlay's optimistic routing (that's the fixed
/// [Envelope.optimistic] flag) and NOT the closed lifecycle [Stability].
abstract class Source {}

/// The common provenances. Use these, or your own `implements Source` enum.
enum CommonSource implements Source { remote, optimistic, local, replay, cached }

/// The lifecycle position of a stored datum — CLOSED and derived, never set by
/// a consumer. The screen-entry trigger switches over it exhaustively.
enum Stability { missing, loading, pending, confirmed, stale, failed }

/// A message wrapped with its transit metadata. `dispatch` produces one; guards
/// transform it; a store reads `source` into its flags sidecar. [optimistic] is
/// the canon-owned overlay-routing signal — separate from `source`, because the
/// base can't read the app's open provenance type to detect an optimistic emit.
/// `correlationId` ties an optimistic dispatch to its later remote confirmation.
class Envelope {
  Envelope(this.msg,
      {required this.source, this.optimistic = false, this.correlationId});
  final Msg msg;
  final Source source;
  final bool optimistic;
  final String? correlationId;

  Envelope copyWith(
          {Msg? msg, Source? source, bool? optimistic, String? correlationId}) =>
      Envelope(
        msg ?? this.msg,
        source: source ?? this.source,
        optimistic: optimistic ?? this.optimistic,
        correlationId: correlationId ?? this.correlationId,
      );
}

/// The per-key sidecar a store keeps BESIDE the value: where it came from and how
/// settled it is. Kept separate so a value-only read never rebuilds on a flag
/// flip (a freshness/confirm change that leaves the value untouched).
class Flags {
  const Flags({required this.source, required this.stability});
  final Source source;
  final Stability stability;

  Flags copyWith({Source? source, Stability? stability}) =>
      Flags(source: source ?? this.source, stability: stability ?? this.stability);

  @override
  bool operator ==(Object other) =>
      other is Flags && other.source == source && other.stability == stability;
  @override
  int get hashCode => Object.hash(source, stability);
}
