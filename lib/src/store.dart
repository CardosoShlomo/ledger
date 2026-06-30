import 'dart:async';

import 'package:identifiable/identifiable.dart';

/// A reactive, normalized map of [Identifiable] entries keyed by their id — the
/// SIMPLE tier. Use it directly (`upsert`/`removeById`/`[]`/`changes`/`watch`)
/// for reactive normalized state with NO bus. Pure `dart:async`, no Flutter. The
/// rich tier (`RegistryStore`) drives one of these from a message bus + a pure
/// reduce and adds the provenance/stability sidecar — but this works standalone.
class Store<T extends Identifiable<I>, I> {
  final Map<I, T> _entries = {};
  final StreamController<I> _changes = StreamController<I>.broadcast(sync: true);

  /// The entry for [id], or null.
  T? operator [](I id) => _entries[id];

  /// All current entries (live view).
  Iterable<T> get values => _entries.values;

  int get length => _entries.length;

  /// Keys that changed — one event per mutation, for surgical rebuilds.
  Stream<I> get changes => _changes.stream;

  /// A surgical, framework-agnostic stream of the entry at [id]: the current
  /// value now, then again on every VALUE change (value-distinct — a mutation
  /// that leaves this entry untouched emits nothing). Wrap in any framework.
  Stream<T?> watch(I id) {
    late final StreamController<T?> ctrl;
    StreamSubscription<I>? sub;
    T? last;
    ctrl = StreamController<T?>(
      onListen: () {
        last = this[id];
        ctrl.add(last);
        sub = changes.listen((k) {
          if (k != id) return;
          final v = this[id];
          if (!identical(v, last)) {
            last = v;
            ctrl.add(v);
          }
        });
      },
      onCancel: () => sub?.cancel(),
    );
    return ctrl.stream;
  }

  void upsert(T item) {
    _entries[item.id] = item;
    _changes.add(item.id);
  }

  void upsertAll(Iterable<T> items) {
    for (final item in items) {
      _entries[item.id] = item;
      _changes.add(item.id);
    }
  }

  void removeById(I id) {
    if (_entries.remove(id) != null) _changes.add(id);
  }

  void update(I id, T Function(T current) f) {
    final current = _entries[id];
    if (current != null) {
      _entries[id] = f(current);
      _changes.add(id);
    }
  }

  void dispose() => _changes.close();
}
