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

import 'msg.dart';


/// The fact carries the FULL authoritative list — a fold replaces wholesale.
mixin ListMsg<T> on Msg {
  List<T> get items;
}

/// The fact carries a CACHED list — a shadow tier fills gaps and yields to
/// the authority (a coverage gate drops it once the real list landed).
mixin CacheMsg<T> on Msg {
  List<T> get items;
}

/// The fact carries one item the app ADDS optimistically — a dock holds it
/// as pending until the echo admits it.
mixin AddMsg<T> on Msg {
  T get item;
}

/// The fact is the server's ECHO of an item — the admission that settles a
/// pending add into the authoritative rows.
mixin EchoOf<T> on Msg {
  T get item;
}

/// The fact removes one row by key.
mixin RemoveMsg<K> on Msg {
  K get id;
}

/// The fact clears the resource — rows empty, coverage withdrawn.
mixin ResetMsg on Msg {}
