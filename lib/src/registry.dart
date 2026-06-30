import 'dart:async';

import 'package:identifiable/identifiable.dart';
import 'store.dart';

import 'envelope.dart';
import 'msg.dart';

/// A PURE interceptor in the dispatch pipeline: inspect/transform an envelope,
/// or return null to veto it. It runs in the replay/optimistic path, so it MUST
/// be pure — a riverpod app guards the flow with one of these without coupling
/// the bus to it; side effects belong in a subscriber ([Bus.on]), not a guard.
typedef Guard = Envelope? Function(Envelope);

/// The transport hook a [RegistryStore] calls to load a key on demand (Door 2):
/// hit the source and dispatch the result back onto the bus. App-provided, so
/// the ledger stays transport-agnostic.
typedef Fetch<K> = Future<void> Function(K key);

/// The message bus — the RICH tier's transport. Dispatch envelopes through
/// guards to typed subscribers. Transport-agnostic: feed it from WS, HTTP, a
/// local DB, or a local optimistic `dispatch(..., optimistic: true)`.
/// Decoupled from canon and from Flutter; a [RegistryStore] subscribes to it,
/// and a riverpod notifier can subscribe via [on] too — neither owns the other.
class Bus {
  final StreamController<Envelope> _controller =
      StreamController<Envelope>.broadcast(sync: true);
  final List<Guard> _guards = [];

  /// Register a pure guard. Runs on every dispatch, in registration order.
  void guard(Guard g) => _guards.add(g);

  /// Push a message through the bus. `source` tags provenance (defaults to the
  /// common remote/optimistic); `optimistic` is the overlay-routing signal — an
  /// optimistic dispatch flows through the SAME subscribers as a remote one but
  /// lands as a pending overlay.
  void dispatch(Msg msg,
      {Source? source, bool optimistic = false, String? correlationId}) {
    var env = Envelope(msg,
        source: source ??
            (optimistic ? CommonSource.optimistic : CommonSource.remote),
        optimistic: optimistic,
        correlationId: correlationId);
    for (final g in _guards) {
      final next = g(env);
      if (next == null) return; // vetoed
      env = next;
    }
    _controller.add(env);
  }

  /// Subscribe to messages of type [M]. Returns the subscription to cancel.
  StreamSubscription<Envelope> on<M extends Msg>(
          void Function(M msg, Envelope env) handler) =>
      _controller.stream.where((e) => e.msg is M).listen((e) => handler(e.msg as M, e));

  bool _connected = true;
  final StreamController<bool> _conn = StreamController<bool>.broadcast(sync: true);

  /// The transport's connection state. While connected + subscribed, a registry
  /// is fresh (the server pushes changes); a drop means freshness is no longer
  /// guaranteed — stores flip confirmed entries to `stale` until revalidated.
  bool get connected => _connected;
  Stream<bool> get connection => _conn.stream;

  /// Report transport connection state (the WS adapter calls this). A drop is
  /// the one event that invalidates everything push was keeping fresh.
  void setConnected(bool value) {
    if (value == _connected) return;
    _connected = value;
    _conn.add(value);
  }

  void close() {
    _controller.close();
    _conn.close();
  }
}

/// The PURE, const registry descriptor: how a message folds into an entry's
/// state. No mutable state, no `ref`, const — so it can sit in a spec. The live
/// store ([RegistryStore]) is created separately and wired to a [Bus].
abstract class Registry<S extends Identifiable<K>, M extends Msg, K> {
  const Registry();

  /// Fold one message into its key's entry. `state` is null when no entry
  /// exists yet; return null to REMOVE the entry. PURE — it is replayed on
  /// overlay confirm/rollback (next phase), so it must have no side effects.
  S? reduce(S? state, M msg);

  /// The key a message targets. Defaults to the message's own [Identifiable]
  /// id; override when a message keys differently from how it is identified.
  K keyOf(M msg) => (msg as Identifiable<K>).id;
}

/// One in-flight optimistic prediction: the message to re-fold over the base,
/// tagged by the correlation id that will confirm or roll it back.
class _Pending<K, M> {
  _Pending(this.correlationId, this.key, this.msg);
  final String correlationId;
  final K key;
  final M msg;
}

/// The live store for a [Registry]: a confirmed BASE (`identifiable.Store`) plus
/// a provenance/stability flags sidecar, driven off a [Bus] — and an OPTIMISTIC
/// OVERLAY on top.
///
/// Optimism is modelled as a pending message log, never a base mutation: an
/// `optimistic` dispatch with a `correlationId` is recorded as an overlay; the
/// EFFECTIVE read folds the base through the pending overlays for that key
/// (overlay wins, base stays clean). A remote message carrying that same
/// correlation id CONFIRMS it (drop the overlay, apply the real effect to base);
/// [rollback] discards it. Because predictions never touch base, a rollback
/// after a superseding write keeps the superseding write — see the test.
class RegistryStore<S extends Identifiable<K>, M extends Msg, K> {
  RegistryStore(this._reg, Bus bus) {
    _sub = bus.on<M>(_apply);
    // a disconnect loses the push freshness guarantee → confirmed entries stale.
    _connSub = bus.connection.listen((up) {
      if (!up) invalidateAll();
    });
  }

  final Registry<S, M, K> _reg;
  final Store<S, K> _base = Store<S, K>(); // confirmed truth only
  final Map<K, Flags> _flags = {};
  final List<_Pending<K, M>> _pending = []; // ordered optimistic overlays
  final StreamController<K> _changes = StreamController<K>.broadcast(sync: true);
  late final StreamSubscription<Envelope> _sub;
  late final StreamSubscription<bool> _connSub;

  void _apply(M msg, Envelope env) {
    final key = _reg.keyOf(msg);
    // optimistic + correlationId → a pending overlay; base is NOT touched.
    if (env.optimistic && env.correlationId != null) {
      _pending.add(_Pending(env.correlationId!, key, msg));
      _changes.add(key);
      return;
    }
    // a confirmed/remote message carrying a pending correlation id CONFIRMS it:
    // drop the optimistic overlay; the real effect below replaces it.
    final affected = <K>{key};
    final cid = env.correlationId;
    if (cid != null) {
      for (final p in _pending) {
        if (p.correlationId == cid) affected.add(p.key);
      }
      _pending.removeWhere((p) => p.correlationId == cid);
    }
    final next = _reg.reduce(_base[key], msg);
    if (next == null) {
      _base.removeById(key);
      _flags.remove(key);
    } else {
      _base.upsert(next);
      _flags[key] = Flags(source: env.source, stability: Stability.confirmed);
    }
    for (final k in affected) {
      _changes.add(k);
    }
  }

  /// Discard the optimistic overlay(s) for [correlationId] — the prediction
  /// failed (timeout/reject). Base is untouched, so any superseding writes that
  /// landed meanwhile survive.
  void rollback(String correlationId) {
    final keys = <K>{
      for (final p in _pending)
        if (p.correlationId == correlationId) p.key
    };
    _pending.removeWhere((p) => p.correlationId == correlationId);
    for (final k in keys) {
      _changes.add(k);
    }
  }

  /// The EFFECTIVE value at [key]: confirmed base folded through any pending
  /// optimistic overlays for that key.
  S? operator [](K key) {
    var s = _base[key];
    for (final p in _pending) {
      if (p.key == key) s = _reg.reduce(s, p.msg);
    }
    return s;
  }

  /// The CONFIRMED value at [key] — base only, ignoring overlays.
  S? confirmed(K key) => _base[key];

  /// Flags at [key]: `optimistic`/`pending` while an overlay is in flight, else
  /// the confirmed base flags.
  Flags? flagsOf(K key) {
    if (_pending.any((p) => p.key == key)) {
      return const Flags(
          source: CommonSource.optimistic, stability: Stability.pending);
    }
    return _flags[key];
  }

  void _setStability(K key, Stability s, {Source? source}) {
    final cur = _flags[key];
    _flags[key] =
        Flags(source: source ?? cur?.source ?? CommonSource.remote, stability: s);
    _changes.add(key);
  }

  /// A fetch is in flight for [key] — the screen-entry trigger calls this when
  /// it fires a load. The value (if any) stays; stability becomes `loading`.
  void markLoading(K key) => _setStability(key, Stability.loading);

  /// A fetch for [key] errored.
  void markFailed(K key) => _setStability(key, Stability.failed);

  Fetch<K>? _fetch;

  /// Wire the transport: how to load a [key] (hit the source, dispatch the
  /// result back onto the bus). Without it, [surface] is inert — data is expected
  /// to arrive by push instead.
  void onFetch(Fetch<K> fetch) => _fetch = fetch;

  /// Door 2 (nav trigger): bring [key]'s data UP to the renderable layer — the
  /// screen saying "I'm live on this now, provide it fresh; I'll show whatever
  /// surfaces." Fetches only if it is missing, stale, or failed; a
  /// `confirmed`/`loading`/`pending` key is a no-op. Idempotent, so it is safe to
  /// call on every navigation — which is why the trigger needs no notion of WHERE
  /// you came from: arriving at an already-fresh key does nothing; only an unseen
  /// or stale key fetches. It promises no outcome — failure/loading stay visible
  /// via [Stability].
  void surface(K key) {
    final fetch = _fetch;
    if (fetch == null) return;
    switch (flagsOf(key)?.stability) {
      case Stability.confirmed:
      case Stability.loading:
      case Stability.pending:
        return; // already present or in flight
      case null:
      case Stability.missing:
      case Stability.stale:
      case Stability.failed:
        markLoading(key);
        fetch(key).catchError((Object _) => markFailed(key));
    }
  }

  /// Mark a CONFIRMED entry stale (server invalidation, a related change, or a
  /// disconnect). A no-op on an entry that isn't currently confirmed.
  void invalidate(K key) {
    if (_flags[key]?.stability == Stability.confirmed) {
      _setStability(key, Stability.stale);
    }
  }

  /// Invalidate every confirmed entry — what a [Bus] disconnect triggers.
  void invalidateAll() {
    for (final key in _flags.keys.toList()) {
      invalidate(key);
    }
  }

  /// All effective entries (base ∪ optimistic-only), each folded.
  Iterable<S> get values sync* {
    final keys = <K>{
      for (final e in _base.values) e.id,
      for (final p in _pending) p.key,
    };
    for (final key in keys) {
      final v = this[key];
      if (v != null) yield v;
    }
  }

  /// Keys whose EFFECTIVE value changed — base apply, overlay add, confirm, or
  /// rollback. Surgical, per key. (Also fires on flag-only changes; use [consume]
  /// for a value-distinct stream, [watchStatus] for a flag-distinct one.)
  Stream<K> get changes => _changes.stream;

  final Map<K, int> _watchers = {}; // active consumers per key (Door 1 refcount)

  void _retain(K key) => _watchers.update(key, (n) => n + 1, ifAbsent: () => 1);

  void _release(K key) {
    final n = (_watchers[key] ?? 1) - 1;
    if (n <= 0) {
      _watchers.remove(key);
    } else {
      _watchers[key] = n;
    }
  }

  /// How many consumers are currently subscribed to [key] (Door 1 refcount).
  int watchers(K key) => _watchers[key] ?? 0;

  /// Door 1 GC: reclaim every CONFIRMED entry no consumer is watching and no
  /// optimistic overlay needs. Call it on memory pressure or a cache-trim tick —
  /// a later [surface] simply refetches anything dropped. Loading/pending and
  /// still-watched entries are kept.
  void gc() {
    for (final key in [for (final e in _base.values) e.id]) {
      if (watchers(key) > 0) continue;
      if (_pending.any((p) => p.key == key)) continue;
      _base.removeById(key);
      _flags.remove(key);
    }
  }

  /// Door 1: CONSUME [key] — the effective value now, then on every VALUE change
  /// (flag-only flips emit nothing). While a consumer holds this subscription the
  /// entry is RETAINED ([watchers] counts it); when the last one cancels it
  /// becomes [gc]-eligible. Universal: wrap in any framework's stream primitive.
  Stream<S?> consume(K key) {
    late final StreamController<S?> ctrl;
    StreamSubscription<K>? sub;
    S? last;
    ctrl = StreamController<S?>(
      onListen: () {
        _retain(key);
        last = this[key];
        ctrl.add(last);
        sub = changes.listen((k) {
          if (k != key) return;
          final v = this[key];
          if (!identical(v, last)) {
            last = v;
            ctrl.add(v);
          }
        });
      },
      onCancel: () {
        sub?.cancel();
        _release(key);
      },
    );
    return ctrl.stream;
  }

  /// The `(key, #status)` aspect: the flags at [key] now, then on every FLAG
  /// change — value-only changes that leave the flags equal emit nothing.
  Stream<Flags?> watchStatus(K key) {
    late final StreamController<Flags?> ctrl;
    StreamSubscription<K>? sub;
    Flags? last;
    ctrl = StreamController<Flags?>(
      onListen: () {
        last = flagsOf(key);
        ctrl.add(last);
        sub = changes.listen((k) {
          if (k != key) return;
          final f = flagsOf(key);
          if (f != last) {
            last = f;
            ctrl.add(f);
          }
        });
      },
      onCancel: () => sub?.cancel(),
    );
    return ctrl.stream;
  }

  void dispose() {
    _sub.cancel();
    _connSub.cancel();
    _base.dispose();
    _changes.close();
  }
}
