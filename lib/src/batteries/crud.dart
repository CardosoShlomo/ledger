/// The CRUD brick family: curated bundles of role-typed regents over one
/// resource. A brick is a [Regency] whose rows are BUILT from its
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

import '../regency.dart';
import '../guard.dart';
import '../msg.dart';
import 'roles.dart';
import '../store.dart';


// ── Layer 3: ARMS + one composable store ──────────────────────────────────
// A brick's fold is assembled from ARMS — one small pure piece per slot;
// an absent capability contributes NO arm (nothing inert to skip). The
// same vocabulary assembles future built-ins.

/// One slot's fold piece: answers the NEXT rows when the fact is its
/// slot's, null when the fact is not its business. Arms compose in order —
/// the first answering arm wins the round.
typedef RowsArm<K, T extends Identifiable<K>> = IdentifiableMap<K, T>?
    Function(IdentifiableMap<K, T> rows, Msg msg);

/// [X] replaces the rows wholesale — the authoritative list.
RowsArm<K, T> listedArm<K, T extends Identifiable<K>, X extends ListMsg<T>>() =>
    (rows, msg) => msg is X ? msg.items.toMapById() : null;

/// [X] fills ABSENCE only — the cache's fold: present rows never overwritten.
RowsArm<K, T> filledArm<K, T extends Identifiable<K>, X extends CacheMsg<T>>() =>
    (rows, msg) => msg is X
        ? {
            for (final t in msg.items)
              if (!rows.containsKey(t.id)) t.id: t,
            ...rows,
          }
        : null;

/// [X]'s item upserts — the dock's add, or the echo's admission.
RowsArm<K, T> upsertArm<K, T extends Identifiable<K>, X extends ItemMsg<T>>() =>
    (rows, msg) => msg is X ? rows.upsert(msg.item) : null;

/// [X]'s item leaves by ITS id — the dock settling on the echo.
RowsArm<K, T> settledArm<K, T extends Identifiable<K>, X extends ItemMsg<T>>() =>
    (rows, msg) => msg is X ? rows.removeById(msg.item.id) : null;

/// [X]'s own id leaves the rows — removal intent or confirmation.
RowsArm<K, T>
    removedArm<K, T extends Identifiable<K>, X extends Identifiable<K>>() =>
        (rows, msg) =>
            msg is X ? rows.removeById((msg as Identifiable<K>).id) : null;

/// [X] clears the rows — resets, and the authority clearing the cache.
RowsArm<K, T> clearedArm<K, T extends Identifiable<K>, X>() =>
    (rows, msg) => msg is X ? const {} : null;

/// A keyed store ASSEMBLED from arms — the one citizen class behind a
/// brick's rows, cache, and dock (each an instance with its own arms; arm
/// order is precedence, the first answering arm wins).
final class ResourceStore<K, T extends Identifiable<K>>
    extends Store<K, T, Msg> {
  const ResourceStore(this.arms);

  final List<RowsArm<K, T>> arms;

  @override
  IdentifiableMap<K, T> reduce(IdentifiableMap<K, T> rows, Msg msg) {
    for (final arm in arms) {
      final next = arm(rows, msg);
      if (next != null) return next;
    }
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
abstract base class Crud<
    K,
    T extends Identifiable<K>,
    L extends ListMsg<T>,
    C extends CacheMsg<T>,
    A extends AddMsg<T>,
    E extends EchoOf<T>,
    R extends Identifiable<K>,
    G extends Identifiable<K>> extends Regency implements EntityHome {
  const Crud() : super(const {});

  // Rows are BUILT (type-parameterized regents cannot be const) and memoized
  // per const-canonical brick instance, so the instances the ledger mounts
  // are the very ones [store]/[cache]/[dock]/[covered] hand back to reads.
  static final Expando<_CrudParts> _parts = Expando();

  _CrudParts get _p => _parts[this] ??= _build();

  _CrudParts _build() {
    final covered = Coverage<L>();
    final rows = ResourceStore<K, T>([
      if (L != Never) listedArm<K, T, L>(),
      if (E != Never) upsertArm<K, T, E>(),
      if (R != Never) removedArm<K, T, R>(),
      if (G != Never) removedArm<K, T, G>(),
      clearedArm<K, T, ResetMsg>(),
    ]);
    final cached = C != Never;
    final gate = cached ? CacheGate<C>(covered) : null;
    final cache = cached
        ? ResourceStore<K, T>([
            if (L != Never) clearedArm<K, T, L>(),
            filledArm<K, T, C>(),
            clearedArm<K, T, ResetMsg>(),
          ])
        : null;
    final writable = A != Never;
    final dock = writable
        ? ResourceStore<K, T>([
            upsertArm<K, T, A>(),
            if (E != Never) settledArm<K, T, E>(),
            clearedArm<K, T, ResetMsg>(),
          ])
        : null;
    return _CrudParts(
      rows: {
        covered,
        if (gate != null) gate,
        if (cache != null) cache,
        if (dock != null) dock,
        rows,
      },
      merges: {
        if (cache != null) ShadowSupports<K, T>(rows, cache),
        if (dock != null) ShadowSupports<K, T>(rows, dock),
      },
      store: rows,
      cache: cache,
      dock: dock,
      covered: covered,
    );
  }

  /// The resource's entity type. ONE resource per entity — an entity has
  /// one authoritative home (a second view is a DERIVED READ over it, never
  /// a second store), which is also what keeps the generic facts
  /// ([Added]/[Listed]/[Removed]) collision-free by construction. The
  /// ledger throws on a second brick of the same entity.
  Type get entity => T;

  @override
  Set<Regent> get rows => _p.rows;

  @override
  Set<AnyProjection> get merges => _p.merges;

  /// The authoritative rows — read it like any regent:
  /// `ledger.at(const InterestsCrud().store)`.
  ResourceStore<K, T> get store => _p.store as ResourceStore<K, T>;

  /// The shadow rows the cache facts fold into — null on a cache-less
  /// preset.
  ResourceStore<K, T>? get cache => _p.cache as ResourceStore<K, T>?;

  /// The pending optimistic adds — null on a read-only preset.
  ResourceStore<K, T>? get dock => _p.dock as ResourceStore<K, T>?;

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
  final Object? cache;
  final Object? dock;
  final Object covered;
}

/// A read-only listed resource: authoritative list + cache shadow + coverage
/// gate. Write slots are [Never].
abstract base class ListCrud<K, T extends Identifiable<K>,
        L extends ListMsg<T>, C extends CacheMsg<T>>
    extends Crud<K, T, L, C, Never, Never, Never, Never> {
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
        R extends Identifiable<K>,
        G extends Identifiable<K>>
    extends Crud<K, T, L, C, A, E, R, G> {
  const WritableListCrud();
}

/// A listed resource with removal but no write dock — the shape of a
/// blocked list: authoritative list + cache shadow + a keyed removal fact.
abstract base class RemovableListCrud<K, T extends Identifiable<K>,
        L extends ListMsg<T>, C extends CacheMsg<T>, R extends Identifiable<K>>
    extends Crud<K, T, L, C, Never, Never, R, Never> {
  const RemovableListCrud();
}

/// The LOCAL resource — tier 1 of the ladder: the generic facts ARE the
/// vocabulary, so one line declares the whole state tier:
///
/// ```dart
/// final class RecentSearchesCrud extends SimpleCrud<String, Search> {
///   const RecentSearchesCrud();
/// }
/// // dispatch(Added(search)); dispatch(Removed<String>(search.id));
/// ```
///
/// [Added] folds STRAIGHT into the authoritative rows (a local list has no
/// echo to wait for); a second `SimpleCrud` over the same [T] throws at
/// boot — subclass a generic fact to sever the audiences.
abstract base class SimpleCrud<K, T extends Identifiable<K>>
    extends Crud<K, T, Listed<T>, Never, Never, Added<T>, Removed<K>, Never> {
  const SimpleCrud();
}
