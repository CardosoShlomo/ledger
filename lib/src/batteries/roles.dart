/// The ROLE vocabulary — small, closed, and mechanical. A role is a
/// field-less mixin a fact wears (`with`) to state the SHAPE it carries;
/// contract getters only, so a role can never restructure the wire and a
/// const fact stays const. The declaration slots each mean one thing:
///
///   * `extends` — MEANING: the fact's semantic family (`InterestMsg`)
///   * `with`    — SHAPE: the mechanical role it plays (`AddMsg<Interest>`)
///   * `implements` — AUDIENCE: the sealed fold-groups that hear it
///
/// Roles stay data-shapes: lists, items, keys. A workflow verb
/// (`ApproveMsg`) does not belong here.
library;

import 'package:identifiable/identifiable.dart';

import '../msg.dart';


/// The fact carries the FULL authoritative list — a fold replaces wholesale.
mixin ListMsg<T> on Msg {
  List<T> get items;
}

/// The fact carries a CACHED list — a shadow tier fills gaps and yields to
/// the authority (a coverage gate drops it once the real list landed).
mixin CacheMsg<T> on Msg {
  List<T> get items;
}

/// The common item-carrying shape [AddMsg] and [EchoOf] share — what the
/// upsert arms bind on.
mixin ItemMsg<T> on Msg {
  T get item;
}

/// The fact carries one item the app ADDS optimistically — a dock holds it
/// as pending until the echo admits it.
mixin AddMsg<T> on Msg implements ItemMsg<T> {}

/// The fact is the server's ECHO of an item — the admission that settles a
/// pending add into the authoritative rows.
mixin EchoOf<T> on Msg implements ItemMsg<T> {}

/// The fact clears the resource — rows empty, coverage withdrawn.
mixin ResetMsg on Msg {}

// Removal has NO role of its own: an id-targeted fact wears the family's
// universal shape — `Identifiable<K>` — and the SLOT it stands in supplies
// the meaning (standing in R = "removes this id"). Wire messages that
// already carry an id work unchanged.

// ── The GENERIC facts — tier 1 of the CRUD ladder. For a purely LOCAL
// resource these ARE the vocabulary: `dispatch(Added(todo))`, zero message
// declarations (`SimpleCrud` binds them). Wire-bound resources keep their
// domain-named facts and wear the role mixins instead. A generic fact's
// audience is exactly the bricks that bound it — two bricks binding the
// same instantiation is a boot-time error (subclass to sever:
// `class ArchiveAdd extends Added<Todo> {}`). ──

/// The full list of a resource, as a bare generic fact.
class Listed<T> extends Msg with ListMsg<T> {
  const Listed(this.items);
  @override
  final List<T> items;
}

/// One item added — for a local resource this is the ADMISSION itself
/// (it wears both the intent and the echo shape, so `SimpleCrud` folds it
/// straight into the authoritative rows).
class Added<T> extends Msg with AddMsg<T>, EchoOf<T> {
  const Added(this.item);
  @override
  final T item;
}

/// One row removed by key.
class Removed<K> extends Msg with Identifiable<K> {
  const Removed(this.id);
  @override
  final K id;
}
