import 'package:identifiable/identifiable.dart';

import 'msg.dart';
import 'store.dart';

/// Pure sugar over a UNIT's post-fold event stream — the recurring effect
/// idioms as verbs. Extensions on the STREAM (not the memory), so they
/// compose after any filter and over replayed feeds alike.
extension UnitEventStream<S, M extends Msg> on Stream<UnitEvent<S, M>> {
  /// Events where the state actually moved — optionally only where the
  /// [of] projection moved (`transitions((s) => s.phase)`).
  Stream<UnitEvent<S, M>> transitions([Object? Function(S state)? of]) =>
      of == null
          ? where((e) => e.before != e.after)
          : where((e) => of(e.before) != of(e.after));

  /// Transitions that land ON [state] — `authStore.events.entering(.synced)`.
  Stream<UnitEvent<S, M>> entering(S state) =>
      where((e) => e.before != e.after && e.after == state);

  /// The [M2]-typed slice of the feed, msg re-typed — the post-fold
  /// counterpart of `ledger.on<M2>()`.
  Stream<UnitEvent<S, M2>> on<M2 extends M>() =>
      where((e) => e.msg is M2).map((e) =>
          UnitEvent(msg: e.msg as M2, before: e.before, after: e.after));
}

/// The keyed-store counterpart of [UnitEventStream].
extension StoreEventStream<K, E extends Identifiable<K>, M extends Msg>
    on Stream<StoreEvent<K, E, M>> {
  /// Events that changed anything — optionally only those where the [of]
  /// projection of some CHANGED key's value moved is the caller's judgment;
  /// this form filters on the changed-key set being non-empty.
  Stream<StoreEvent<K, E, M>> transitions() => where((e) => e.changed.isNotEmpty);

  /// The [M2]-typed slice of the feed, msg re-typed.
  Stream<StoreEvent<K, E, M2>> on<M2 extends M>() =>
      where((e) => e.msg is M2).map((e) => StoreEvent(
          msg: e.msg as M2,
          env: e.env,
          before: e.before,
          after: e.after,
          changed: e.changed,
          structural: e.structural));
}
