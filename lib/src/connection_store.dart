import 'dart:async';

import 'package:identifiable/identifiable.dart';

import 'connection.dart';
import 'envelope.dart';
import 'msg.dart';
import 'registry.dart'; // Bus

/// The PURE, const descriptor for a family of [Connection]s driven off the bus:
/// which connection [keyOf] a message targets, an entity's [sortKeyOf], and how
/// a message [apply]s to the connection (a live push → `receive`, a page →
/// `setWindow`/`extendOlder`, an out-of-window entry → `floatIn`). No `ref`, no
/// state — the live store is [ConnectionStore].
///
/// Type params: T entity (Identifiable<I>), I entity id, SK sort key, M message,
/// K connection key (distinct from the entity id — e.g. a chat keyed by
/// (adId,userId) whose entities are messages keyed by messageId).
abstract class ConnectionRegistry<T extends Identifiable<I>, I,
    SK extends Comparable<Object?>, M extends Msg, K> {
  const ConnectionRegistry();

  /// The connection a message targets.
  K keyOf(M msg);

  /// An entity's order key.
  SK sortKeyOf(T entity);

  /// Route a message to the connection's operations. Mutates the (local)
  /// connection — `connection.receive` / `extendOlder` / `setWindow` / `floatIn`.
  void apply(Connection<T, I, SK> connection, M msg);
}

/// The live store: one [Connection] per key, driven off a [Bus]. A message for a
/// never-opened connection still creates it — so a push for an unopened chat is
/// STORED (floating) from the start instead of ignored, ready when you open it.
class ConnectionStore<T extends Identifiable<I>, I,
    SK extends Comparable<Object?>, M extends Msg, K> {
  ConnectionStore(this._reg, Bus bus) {
    _sub = bus.on<M>(_apply);
    // a disconnect loses the freshness guarantee → loaded pages may be stale,
    // so the next surface refetches.
    _connSub = bus.connection.listen((up) {
      if (!up) _surfaced.clear();
    });
  }

  final ConnectionRegistry<T, I, SK, M, K> _reg;
  final Map<K, Connection<T, I, SK>> _connections = {};
  final Set<K> _surfaced = {}; // keys whose initial page was requested
  Fetch<K>? _fetch;
  late final StreamSubscription<Envelope> _sub;
  late final StreamSubscription<bool> _connSub;

  Connection<T, I, SK> _of(K key) => _connections.putIfAbsent(
      key, () => Connection<T, I, SK>(_reg.sortKeyOf));

  void _apply(M msg, Envelope env) => _reg.apply(_of(_reg.keyOf(msg)), msg);

  /// The connection at [key] (lazily created).
  Connection<T, I, SK> operator [](K key) => _of(key);

  /// Watch the connection at [key] — its `(window, floating)` view, reactively.
  Stream<ConnectionView<T, SK>> watch(K key) => _of(key).watch();

  /// Wire the transport: how to load a connection's INITIAL page (hit the source,
  /// dispatch the page back onto the bus). Without it, [surface] is inert.
  void onFetch(Fetch<K> fetch) => _fetch = fetch;

  /// Door 2 for a connection: ensure its initial page is loading. Idempotent —
  /// once requested (or after a disconnect re-arms it), repeat calls are no-ops,
  /// independent of any floating pushes already received. Promises no outcome.
  void surface(K key) {
    final fetch = _fetch;
    if (fetch == null || _surfaced.contains(key)) return;
    _surfaced.add(key);
    fetch(key).catchError((Object _) => _surfaced.remove(key)); // retry on failure
  }

  /// Forget that [key]'s page was loaded, so the next [surface] refetches.
  void invalidate(K key) => _surfaced.remove(key);

  void dispose() {
    _sub.cancel();
    _connSub.cancel();
    for (final c in _connections.values) {
      c.dispose();
    }
  }
}
