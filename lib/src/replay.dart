import 'package:identifiable/identifiable.dart';

import 'ledger.dart';
import 'msg.dart';
import 'store.dart';

/// The state the WHOLE ledger folds from [order] — its *replay*. Builds a
/// pure ledger from [root] (a `Regency` or any single regent), folds the
/// messages synchronously, and returns every regent's state keyed by SPEC
/// INSTANCE — `z[const Todos()]`. Deterministic: the folds are pure, so the
/// same messages always yield the same snapshot — replay is the operation
/// purity buys you.
///
/// Compare two replays with `equals` / `isNot` to state order-(in)dependence
/// across the ledger as a law:
///
///   expect(replay(app, [cache, authority]),
///          equals(replay(app, [authority, cache])));  // converges
///
/// Guard rows judge through the replayed ledger's OWN read, so a
/// gate-bearing graph replays with no external wiring.
Map<Object, Object?> replay(Regent root, List<Msg> order) {
  final ledger = Ledger.root(root);
  for (final msg in order) {
    ledger.dispatch(msg);
  }
  final snapshot = ledger.snapshot();
  ledger.close();
  return snapshot;
}

/// A single store's replayed collection — the narrow form of [replay] for a
/// store whose `reduce` reads only its own state (no guards, no merge edges).
IdentifiableMap<K, E> replayStore<K, E extends Identifiable<K>, M extends Msg>(
    Store<K, E, M> store, List<Msg> order) {
  final bus = Bus();
  final mem = StoreMemory<K, E, M>(store, bus);
  for (final msg in order) {
    bus.dispatch(msg);
  }
  final state = mem.entities;
  mem.dispose();
  bus.close();
  return state;
}
