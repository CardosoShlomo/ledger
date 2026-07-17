# regent

Optimistic, message-driven state engine: a journal of sealed facts folded
into keyed stores and units, traversed by one ordered queue of regents.
Pure Dart.

## Regent in 60 seconds

In standard state-management terms:

- **Msg** — an event/action: an immutable fact you `dispatch`.
- **Store / Unit** — a reducer with its state: a `Store` folds messages into
  a keyed collection, a `Unit` into a single value.
- **Guard** — middleware as a pure function: it can drop, rewrite, or fan
  out a message before the rows below it see it.
- **Mint** — a guard deriving a new message from one it judged (run as its
  own round, re-judged from the top; never journaled — it re-derives on
  replay).
- **Ledger / journal** — the runtime plus its event log: the journal keeps
  every dispatched message; reads and streams come from `at(position)`.
- **Regent** — any row in the ordered queue a message walks: a store, a
  unit, or a guard.

```dart
import 'package:regent/regent.dart';

sealed class CartMsg extends Msg { const CartMsg(); }
final class ItemAdded extends CartMsg {
  const ItemAdded(this.productId);
  final String productId;
}

final class Cart extends Unit<List<String>, CartMsg> {
  const Cart() : super(const []);
  @override
  List<String> reduce(List<String> items, CartMsg msg) => switch (msg) {
    ItemAdded(:final productId) => [...items, productId],
  };
}

const cart = Cart();

void main() {
  final ledger = Ledger.root(cart);
  ledger.dispatch(const ItemAdded('sku-42'));
  print(ledger.at(cart).state); // [sku-42]
}
```

The rest of this document uses these terms with their full meanings.

## Why one journal

The structural decision everything else falls out of: **every store folds
the same stream, and the stream is totally ordered.** Most state
architectures isolate per component — a bloc per page, a stream per
feature — and that isolation is exactly what forecloses the interesting
properties. Give all folds one ordered stream and the chain runs by
itself:

- the stream **is a journal**, so `replay(app, facts)` exists — the whole
  application re-folded in a unit test;
- replay exists, so **laws are executable**: order-independence and
  cache-vs-authority convergence are `expect`s, not review comments —

  ```dart
  expect(replay(app, [cached, authority]),
      equals(replay(app, [authority, cached])));
  ```

- delivery is by declaration (a message names its regents), so a guard
  stands **positioned** — placement is protection, meaningful only because
  consumers don't race on a bus;
- an event serving many folds can't be shaped for any one screen, so the
  vocabulary is forced to be **facts about reality** (`OrderPlaced`, never
  `ShowSpinner`).

Two rules of thumb this buys, stated once:

**Reality at both doors.** A store's messages describe what happened in
the world, and its state describes the world. Anything shaped like a
screen — loading, selected, visible — exists only as a derivation, so no
fold is ever rewritten because a screen changed its mind. A UI redesign is
a read-side edit; when storage describes screens, every redesign is a
state migration.

**Scope by shareability.** State takes the scope and lifetime of what it
describes, and the test is a thought experiment: could a second consumer —
another surface, or a later moment — coherently mean this fact? The
blocked-users list with one reading screen is still the world's (a second
surface is a feature waiting to happen; the row must survive navigation).
A scroll position is not (another screen consuming it is meaningless).
Space-sharing gives scope, time-sharing gives lifetime and persistence,
and the classic drift bugs — the same entity copied into three feature
stores, data dying on navigation and refetching on return — are all
mis-answers to that one question.

The honest boundary: if the app is thin CRUD over a reliable server, a
per-screen pattern is fine and this package is more than it needs.
Regent's case begins where offline, optimism, and many surfaces reading
one truth live — there it is not a nicer reducer, it is the layer
per-screen patterns leave unowned.

## The queue of regents

Dispatch a `Msg`; it enters the journal (the complete, ungated record) and
walks the QUEUE — an ordered list of REGENTS:

- A **store** row is a pure READER standing at its place: it folds what
  passes (`Store.reduce` over a keyed collection, `Unit.reduce` over one
  value) and can never touch the message. What it sees is whatever survived
  the guards above its row.
- A **guard** row is a pure JUDGE of the flow: it folds nothing and holds no
  state. Its verdict is a set of LAUNCHES targeting the only two indices
  that preserve the theorem *no row ever sees a message that skipped a
  guard above it*: `.forward(msg)` continues THIS round below (pass, drop
  via `{}`, rewrite, fan out); `.mint(msg)` DERIVES a new fact as its own
  round from index 0, after this round completes — re-judged by every
  guard, never journaled (it re-derives on replay), required to commute
  with its siblings. A `Veto` is the boolean specialization (pass or drop).

One order, two opposite relationships to it: moving a store changes what IT
sees; moving a guard changes what EVERYONE below it sees. The record always
keeps the original fact — guards shape the admitted feed, never the record.

## Two doors

The app is a const VALUE — a `Regency` of rows in traversal order plus the
merge edges (each projection carries its own endpoints). Reader rows get
NAMES — const globals the consumer owns (const canonicalization makes the
global and any equal construction ONE instance, so the name IS the row):

```dart
const catalogCovered = CatalogCovered();
const catalog = Catalog();

const app = Regency({
  catalogCovered,
  CachedCatalogGate(),  // set order is the queue — placement is protection
  catalog,
});

final ledger = Ledger.root(app); // splices rows, wires merges
```

Regencies nest (a segment splices at its position) and a plain regent is a
one-row graph: `Ledger.root(const NavUnit())`. A FEATURE whose rows are
provably self-contained travels as one named graft — its merge edges ride
along and resolve before the root's own:

```dart
final class WishlistFeature extends Regency {
  const WishlistFeature()
      : super(const {WishlistCap(), wishlist, wishlistWrite},
              merges: const {WriteSupportsWishlist()});
}
```

Grouping is splice-in-place and reads stay FLAT — `read(wishlist)` never
knows the grouping exists, so a graft can never change what a row means,
only where the set is written down. The ledger then has exactly TWO doors:

- **`dispatch(msg)`** — state a fact.
- **`at(position)`** — stand at a position, typed by the spec instance:
  `at(catalog)` is the store's live memory, `at(viewer)` the unit's,
  `at(const CachedCatalogGate())` the guard's story (`GuardEvent`s: judged
  input + verdict — `dropped`, `forwarded`, `minted`), `at(.entry)` the
  complete pre-judgment RECORD, `at(.exit)` the admitted feed
  (`at(.exit).msgs<OrderPlaced>()` — effects tap here, so nothing fires on
  a dropped message).

On every handle, PLURAL members are streams (`msgs<T>()`, `states`,
`statesBefore`, `events` — all derived from the one atomic `events`, so
nothing races the fold) and SINGULAR members are values now (`state` for a
unit, `entities`/`[id]`/`ids` for a store — merge-resolved; `folded` is the
unmerged fold truth on both, what guards judge through and what `replay`
snapshots).

Guards read the world only through `read(catalog)` — the ledger's own
folded state by REGENT IDENTITY (the const global or an equal construction
name the same row). With canon's generator the graph is annotated
(`@canon const app = Regency(...)`) and each row CLASS gains a read
extension, so the same globals answer everywhere: `read(catalog)` in a
judge, `catalog.of(context)` in a build, `catalog.entities` now — the
generator never invents a name.

## Optimism

Optimism is ROWS, never memory machinery — a store's memory holds nothing
but its fold. The **write dock**: a side store holds the pending prediction
as honest state (base has no arm for it), a merge edge applies it at read,
a guard settles it against echoes by STATE COMPARISON, and a deadline
EFFECT dispatches a timeout fact the guard judges like any other. Pending,
settled, in-flight, covered — every status a UI could render is a row, so
everything replays and confirm/revert/amend orders are statable as laws.

## Beyond the fold

- **Events** — each store emits one post-fold event per delivered family
  message (`msg`, `before`, `after`, changed keys): effects observe cause
  and consequence atomically, so they can never race the fold. Sugar:
  `transitions()`, `entering(state)`, `on<M>()`.
- **In-flight as a row** — a request fact folds its key in, the answering
  facts (success or failure) fold it out; presence = loading, read with the
  same surface as any state. A guard reading it drops duplicate asks; a
  scope-entry FACT judged by a gate replaces every fetch-on-entry bridge.
  No machinery, no sidecar.
- **Merges** — read-time edges, never copied state: a unit's state answers a
  keyed surface at its own `Identifiable` id (`merge`), or a whole store
  lends its rows to another's reads through a projection (`mergeStore`) —
  the write dock and the cross-entity lend (one store's rows answering
  another surface's reads). A disk cache is NOT a merge: it folds into the
  one store as an absence-only arm, its rows wearing a provenance flag any
  consumer (a freshness gate, a censoring ruling) reads as data.

## The one clock, and why there is no effects runner

Regent has exactly ONE clock: the dispatch stream. Nothing else is allowed
to mark time — not a `Duration` parameter in the state tier, not a wall-clock
read in a fold. So the first thing every arrival from an effects-as-values
framework asks for — a runner with `restartable` / `latest` / `debounce`
modes — regent deliberately does not ship. Not for lack of ambition: **the
modes have no work left to do here.**

The reason is that the wire is already a queue of facts, not a `Future` per
call. A network ask isn't a promise you cancel; it's a fact you send. You
cannot unsend it — you can only ignore its answer, **and ignoring is a
judgment**, which is pure by nature. So every mode collapses into citizens:

| runner mode | regent |
|---|---|
| `restartable` / `latest` | a CURRENT-intent row + a staleness veto |
| `droppable` | the in-flight row + its gate |
| `sequential` | the outbox — an ordered queue already |

Search-as-you-type, whole (the wire correlation is the trick — **the answer
echoes its question**, so staleness is judgeable in a pure fold):

```dart
final class Search extends Unit<String?, SearchMsg> {   // the CURRENT intent
  const Search() : super(null);
  @override
  String? reduce(String? q, SearchMsg msg) => switch (msg) {
    SearchQueryMsg(:final query) => query,              // newest intent wins
    SearchResultsMsg() => q,
  };
}

/// An answer to a question that is no longer current is dropped for every
/// row below — the whole "cancel the stale request" story, as a judgment.
final class StaleSearchGate extends Veto<SearchResultsMsg> {
  const StaleSearchGate();
  @override
  bool block(SearchResultsMsg msg, ReadStore read) => msg.query != read(search);
}
```

The effect that remains is a TRANSLATOR — fact in, I/O, fact out. No state,
no branches, and its worst possible sin (a stale or duplicate answer) is
eaten by the veto above: the edge may be racy, the ledger cannot be.

```dart
ledger.at(.exit).msgs<SearchQueryMsg>().listen((msg) async {
  try {
    dispatch(SearchResultsMsg(
        query: msg.query, products: await api.searchProducts(msg.query)));
  } on ApiException {
    dispatch(SearchFailedMsg(query: msg.query));  // failure is a fact too
  }
});
```

**And when a consumer genuinely wants to wait?** The timer is a translator
like any other edge: wall-time in, ONE fact out — `after(d, msg)` — and what
the elapsed time MEANS is judged in the queue against the present (an epoch
or a state check on the due-fact; a settle tick for a superseded epoch is a
stale fact like any other). A timer nobody cancels is harmless when its tick
is judged. Cancelling is then a cost optimization, never a correctness
requirement — and `replay()` never arms a timer at all, so a law test proves
the whole debounce by dispatching the due-facts, with zero real waiting.

What irreducibly stays at the edge: the sites that HOLD a cancellable
resource — upload bytes, platform streams, the socket itself. There the
decision is still a fold (the saga says cancelled; the connection unit says
offline) and the edge merely releases the resource. That is a small, stable,
hand-written set — which is why effects stay one honest file.

**The edge spends; the queue decides.**

## Message conventions

The structure prevents most failure modes; message taxonomy discipline
prevents the rest. These are the rules the engine can't enforce for you:

- **Messages are facts, not calls.** Name an inbound message for the fact it
  states (`ProductLoaded`, `UsernameTaken`), an outbound one for the intent
  it declares. A message never names its handler.
- **Semantic outcomes, never generic errors.** `UsernameTaken`, not
  `Error("username taken")` — an expected outcome is a message the reducer
  and UI handle like any other fact.
- **One sealed family per entity concern.** The family (`ProductMsg`,
  `CartMsg`) is exactly what one store reduces — `sealed`, so the reduce is
  exhaustively matched and a new variant is a compile error until every
  store answers it. NO row reduces the root `Msg` — a row whose facts cross
  families (a dock, an in-flight unit, a cache-fed table) declares a sealed
  GROUP its facts `implements` (a family base may join a group wholesale),
  so every cross-family arm is typed — no wildcard exists to write.
- **Guards are pure.** A guard reads the world only through `read` — never
  dispatches, never touches the world. Placement is semantics: declare
  guards above the rows they protect.
- **The locality axiom.** Every regent invocation is a pure function of
  (current state, message) — never of why the cursor arrived, what round it
  is, or what minted what. STORES TRANSFORM STATE AND NOTHING ELSE; GUARDS
  ENQUEUE CURSORS (at 0 or x+1) AND NOTHING ELSE. History reaches the
  future only through state, so replay totality is a theorem, provenance is
  invisible (if causation matters, it goes ON the fact), and every regent
  is table-testable with (state, msg) pairs — judgments are values.
- **Mints derive, never sequence.** A legitimate mint is a fact the fold
  already implies, restatable as a law about state ("whenever X folds, Y
  exists"). Sequencing over time belongs to effects; a mint chain past the
  depth budget throws — a design diagnosis, not a runtime hazard.

## Store keys are gradually typed

A store's key type may be the raw codec type or the id's generated extension
type — both are always valid, and they are runtime-identical (extension types
erase):

```dart
final class Products extends Store<String, Product, ProductMsg> { … }     // day one
final class Products extends Store<ProductId, Product, ProductMsg> { … }  // hardened
```

Write `String` before the first generation exists (nothing else compiles
yet); tighten to `ProductId` whenever you like — or never. The typed key buys
exactly one thing: nominal protection on the store's key axis
(`products[someUserId]` stops compiling). Everything else — verbs, entity
fields, derived reads — is typed independently and works the same either way.
