/// The CRUD brick family: curated bundles of role-typed regents over one
/// resource. A brick is a [RegentGraph] whose rows are BUILT from its
/// generic slots — the consumer binds facts by declaring a named subclass:
///
/// ```dart
/// final class InterestsCrud extends WritableListCrud<String, Interest,
///     InterestsMsg, CachedInterestsMsg, AddInterestMsg, InterestAddedMsg,
///     InterestCancelledMsg, InterestGoneMsg> {
///   const InterestsCrud();
/// }
/// ```
///
/// A fact in the wrong slot is a BOUND violation at the declaration — the
/// compiler is the whole checker. Brick regents type on the CONCRETE slot
/// (`L`, not `ListMsg<T>`), so a second implementer of the same role is
/// simply never delivered. [Never] fills an empty slot: a `Never`-typed arm
/// is inert by subtyping alone.
///
/// The brick's rows are one instance-identity family, memoized per const
/// brick instance — `const InterestsCrud().store` IS the mounted row, so
/// `ledger.read(const InterestsCrud().store)` and external guards read it
/// like any hand-written regent.
library;

import 'package:identifiable/identifiable.dart';

import 'graph.dart';
import 'guard.dart';
import 'msg.dart';
import 'roles.dart';
import 'store.dart';


// ── Layer 3: role-typed regents, each usable alone ────────────────────────

/// The authoritative rows of a resource: [L] replaces wholesale, [E] admits
/// one echoed item, [R]/[G] remove by key (the optimistic intent and the
/// server's confirmation — same fold, idempotent), [ResetMsg] clears.
final class ResourceRows<K, T extends Identifiable<K>, L extends ListMsg<T>,
    E extends EchoOf<T>, R extends RemoveMsg<K>,
    G extends RemoveMsg<K>> extends Store<K, T, Msg> {
  const ResourceRows();

  @override
  IdentifiableMap<K, T> reduce(IdentifiableMap<K, T> rows, Msg msg) {
    if (msg is L) return msg.items.toMapById();
    if (msg is E) return rows.upsert(msg.item);
    if (msg is R) return rows.removeById(msg.id);
    if (msg is G) return rows.removeById(msg.id);
    if (msg is ResetMsg) return const {};
    return rows;
  }
}

/// The shadow tier: cached rows filling gaps until the authority answers —
/// the authoritative list CLEARS it (a cold-start bridge, not a second
/// truth: rows the authority didn't confirm stop answering).
final class ResourceCache<K, T extends Identifiable<K>, C extends CacheMsg<T>,
    L extends ListMsg<T>> extends Store<K, T, Msg> {
  const ResourceCache();

  @override
  IdentifiableMap<K, T> reduce(IdentifiableMap<K, T> rows, Msg msg) {
    if (msg is L) return const {};
    if (msg is C) return rows.upsertAll(msg.items);
    if (msg is ResetMsg) return const {};
    return rows;
  }
}

/// The write dock: items the app added optimistically, pending until the
/// echo admits them into the authoritative rows.
final class ResourceDock<K, T extends Identifiable<K>, A extends AddMsg<T>,
    E extends EchoOf<T>> extends Store<K, T, Msg> {
  const ResourceDock();

  @override
  IdentifiableMap<K, T> reduce(IdentifiableMap<K, T> rows, Msg msg) {
    if (msg is A) return rows.upsert(msg.item);
    if (msg is E) return rows.removeById(msg.item.id);
    if (msg is ResetMsg) return const {};
    return rows;
  }
}

/// TRUE once the authority answered — what the cache gate judges by.
final class Coverage<L extends Msg> extends Unit<bool, Msg> {
  const Coverage() : super(false);

  @override
  bool reduce(bool state, Msg msg) {
    if (msg is L) return true;
    if (msg is ResetMsg) return false;
    return state;
  }
}

/// Drops cache facts once [coverage] holds — a stale cache never overwrites
/// the authority for any row below this gate.
final class CacheGate<C extends Msg> extends Veto<C> {
  const CacheGate(this.coverage);

  final Unit<bool, Msg> coverage;

  @override
  bool block(C msg, ReadStore read) => read(coverage);
}

/// The shadow edge: the target's own row wins; the shadow answers the rest.
final class ShadowSupports<K, T extends Identifiable<K>>
    extends Projection<T, K, T> {
  const ShadowSupports([super.target, super.source]);

  @override
  T resolve(T? row, T shadow) => row ?? shadow;
}

// ── Layer 4: the curated bundles ──────────────────────────────────────────

/// The full-arity CRUD brick — presets below fix unused slots to [Never].
/// Subclass to declare a resource; `@override get store` (and siblings) is
/// the bring-your-own extension point.
abstract base class CrudRegent<
    K,
    T extends Identifiable<K>,
    L extends ListMsg<T>,
    C extends CacheMsg<T>,
    A extends AddMsg<T>,
    E extends EchoOf<T>,
    R extends RemoveMsg<K>,
    G extends RemoveMsg<K>> extends RegentGraph {
  const CrudRegent() : super(const {});

  // Rows are BUILT (type-parameterized regents cannot be const) and memoized
  // per const-canonical brick instance, so the instances the ledger mounts
  // are the very ones [store]/[cache]/[dock]/[covered] hand back to reads.
  static final Expando<_CrudParts> _parts = Expando();

  _CrudParts get _p => _parts[this] ??= _build();

  _CrudParts _build() {
    final covered = Coverage<L>();
    final gate = CacheGate<C>(covered);
    final cache = ResourceCache<K, T, C, L>();
    final rows = ResourceRows<K, T, L, E, R, G>();
    final writable = A != Never;
    final dock = writable ? ResourceDock<K, T, A, E>() : null;
    return _CrudParts(
      rows: {covered, gate, cache, if (dock != null) dock, rows},
      merges: {
        ShadowSupports<K, T>(rows, cache),
        if (dock != null) ShadowSupports<K, T>(rows, dock),
      },
      store: rows,
      cache: cache,
      dock: dock,
      covered: covered,
    );
  }

  @override
  Set<Regent> get rows => _p.rows;

  @override
  Set<AnyProjection> get merges => _p.merges;

  /// The authoritative rows — read it like any regent:
  /// `ledger.read(const InterestsCrud().store)`.
  ResourceRows<K, T, L, E, R, G> get store =>
      _p.store as ResourceRows<K, T, L, E, R, G>;

  /// The shadow rows the cache facts fold into.
  ResourceCache<K, T, C, L> get cache =>
      _p.cache as ResourceCache<K, T, C, L>;

  /// The pending optimistic adds — null on a read-only preset.
  ResourceDock<K, T, A, E>? get dock =>
      _p.dock as ResourceDock<K, T, A, E>?;

  /// TRUE once the authority answered.
  Coverage<L> get covered => _p.covered as Coverage<L>;
}

final class _CrudParts {
  const _CrudParts({
    required this.rows,
    required this.merges,
    required this.store,
    required this.cache,
    required this.dock,
    required this.covered,
  });

  final Set<Regent> rows;
  final Set<AnyProjection> merges;
  final Object store;
  final Object cache;
  final Object? dock;
  final Object covered;
}

/// A read-only listed resource: authoritative list + cache shadow + coverage
/// gate. Write slots are [Never].
abstract base class ListCrud<K, T extends Identifiable<K>,
        L extends ListMsg<T>, C extends CacheMsg<T>>
    extends CrudRegent<K, T, L, C, Never, Never, Never, Never> {
  const ListCrud();
}

/// The writable listed resource: [ListCrud] plus the optimistic write dock
/// (add intent, echo admission) and removal (intent + confirmation).
abstract base class WritableListCrud<
        K,
        T extends Identifiable<K>,
        L extends ListMsg<T>,
        C extends CacheMsg<T>,
        A extends AddMsg<T>,
        E extends EchoOf<T>,
        R extends RemoveMsg<K>,
        G extends RemoveMsg<K>>
    extends CrudRegent<K, T, L, C, A, E, R, G> {
  const WritableListCrud();
}
