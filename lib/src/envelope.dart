import 'package:meta/meta.dart';

import 'msg.dart';

/// The lifecycle position of a stored datum — CLOSED and derived, never set by
/// a consumer. The screen-entry trigger switches over it exhaustively.
/// `reverted` = the last word here was a FAILED optimism: the value is the
/// confirmed base again after a rollback snapped an overlay away, and no newer
/// fact has spoken. The next fold that touches the datum overwrites it.
/// `amended` = the server settled an approved write to a THIRD value —
/// neither the prediction nor the old world (a clamp, a sanitization).
enum Stability {
  missing, loading, pending, confirmed, stale, failed, reverted, amended
}

/// A message wrapped with its transit metadata. `dispatch` produces one;
/// guards transform it. There is NO provenance tag: where a fact came from is
/// said by its TYPE and its store (a cache is a local store answering through
/// a merge edge). [optimistic] is the overlay-routing signal; `correlationId`
/// ties an optimistic dispatch to its later confirmation.
@immutable
class Envelope {
  Envelope(this.msg, {this.optimistic = false, this.correlationId});
  final Msg msg;
  final bool optimistic;
  final String? correlationId;

  Envelope copyWith({Msg? msg, bool? optimistic, String? correlationId}) =>
      Envelope(
        msg ?? this.msg,
        optimistic: optimistic ?? this.optimistic,
        correlationId: correlationId ?? this.correlationId,
      );
}

/// The per-key sidecar a store keeps BESIDE the value: where it came from and how
/// settled it is. Kept separate so a value-only read never rebuilds on a flag
/// flip (a freshness/confirm change that leaves the value untouched).
@immutable
class Flags {
  const Flags({required this.stability, this.tampered = false});
  final Stability stability;

  /// While a prediction is PENDING: some fact touched the predicted values
  /// with a state that neither confirms nor reverts it — contested until the
  /// settling fact or the deadline decides.
  final bool tampered;

  Flags copyWith({Stability? stability, bool? tampered}) => Flags(
      stability: stability ?? this.stability,
      tampered: tampered ?? this.tampered);

  @override
  bool operator ==(Object other) =>
      other is Flags &&
      other.stability == stability &&
      other.tampered == tampered;
  @override
  int get hashCode => Object.hash(stability, tampered);
}
