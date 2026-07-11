import 'store.dart';

/// The app as a VALUE: an ordered set of regents plus merge edges. A graph
/// IS a regent, and a regent is a one-row graph — `Ledger.root` takes a
/// single [Regent], so the smallest ledger is `Ledger.root(const NavUnit())`
/// and the largest is a const tree:
///
/// ```dart
/// @canon
/// const ledger = Regency({
///   TodosCovered(),
///   CachedTodosGate(),   // order is the set's order — placement is protection
///   LocalTodos(),
///   Todos(),
/// }, merges: {LocalTodoSupports()});
/// ```
///
/// Rows are PURE regents — implicitly const from the set context, so every
/// instance canonicalizes (the identity `read`, enrollment, and laws key
/// on). Edges are the projections themselves: a [Projection] carries its
/// [Projection.target]/[Projection.source] endpoints as const fields, so
/// the merges set lists bare projection instances.
///
/// Nesting: a row may itself be a [Regency] — its rows SPLICE at that
/// position (a graft: the segment's regents are real rows of the one
/// queue, visible to laws and replay). A brick (a parameterized graph
/// subclass) is the same thing with a name.
base class Regency extends Regent {
  const Regency(this.rows, {this.merges = const {}});

  /// The ordered rows — regents and nested graphs, spliced in set order.
  final Set<Regent> rows;

  /// The edges: projections carrying their own endpoints.
  final Set<AnyProjection> merges;

  @override
  Null mount(LedgerRows ledger) {
    ledger.graph(this);
    return null;
  }
}
