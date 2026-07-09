import 'package:test/test.dart';
import 'package:regent/regent.dart';

class _CountState with Identifiable<String> {
  _CountState(this.id, this.value);
  @override
  final String id;
  final int value;
}

sealed class _CountMsg extends Msg {
  const _CountMsg();
}

class _Inc extends _CountMsg with Identifiable<String> {
  _Inc(this.id, this.by);
  @override
  final String id;
  final int by;
}

class _Reset extends _CountMsg with Identifiable<String> {
  _Reset(this.id);
  @override
  final String id;
}

final class _Counter extends Store<String, _CountState, _CountMsg> {
  // [lane] distinguishes two rows of this store in one ledger — identical
  // const instances are ONE citizen (identity keying), so rows must differ.
  const _Counter([this.lane = 0]);
  final int lane;
  @override
  IdentifiableMap<String, _CountState> reduce(
          IdentifiableMap<String, _CountState> entities, _CountMsg m) =>
      switch (m) {
        _Inc(:final id, :final by) =>
          entities.upsert(_CountState(id, (entities[id]?.value ?? 0) + by)),
        _Reset(:final id) => entities.removeById(id),
      };
}

void main() {
  test('journal records everything; a guard gates the rows below its own',
      () async {
    final ledger = Ledger();
    // Row order IS the spec: the guard stands above the store it protects.
    ledger.veto<_Reset>((_) => true); // drop resets from this row down
    final counter = ledger.store(const _Counter());

    final journalSeen = <Object>[];
    ledger.journal.on<Msg>().listen(journalSeen.add);
    final admittedSeen = <Object>[];
    ledger.on<Msg>().listen(admittedSeen.add);

    ledger.dispatch(_Inc('a', 5));
    ledger.dispatch(_Reset('a')); // dropped above the store's row

    await Future<void>.delayed(Duration.zero); // observers deliver post-cut
    expect(counter['a']?.value, 5); // reset never reached the store
    expect(admittedSeen.length, 1); // ledger.on = the END of the queue — no ghost effects
    expect(journalSeen.length, 2); // …but the journal kept BOTH (complete record)
  });

  test('a guard protects only the rows below it — placement is semantics',
      () async {
    final ledger = Ledger();
    final above = ledger.store(const _Counter()); // folds BEFORE the guard
    ledger.veto<_Reset>((_) => true);
    final below = ledger.store(const _Counter(1)); // sees only what survives

    ledger.dispatch(_Inc('a', 5));
    ledger.dispatch(_Reset('a'));

    expect(above['a'], isNull); // the reset folded here — row above the guard
    expect(below['a']?.value, 5); // …and was dropped before this row
  });

  test('a registered registry receives posted messages', () {
    final ledger = Ledger();
    final counter = ledger.store(const _Counter());
    ledger.dispatch(_Inc('a', 3));
    expect(counter['a']?.value, 3);
  });

  test('an effect dispatches AFTER the traversal (async delivery)', () async {
    final ledger = Ledger();
    final counter = ledger.store(const _Counter());
    // message → effect → message: the effect delivers async (post-cut), so
    // its dispatch is an ordinary new traversal — never re-entrant.
    ledger.on<_Inc>().listen((msg) {
      if (msg.by == 5) ledger.dispatch(_Inc('a', 1));
    });
    ledger.dispatch(_Inc('a', 5));
    expect(counter['a']?.value, 5); // state settled; effect not yet run
    await Future<void>.delayed(Duration.zero);
    expect(counter['a']?.value, 6); // the effect's fact landed after
  });

  test('close disposes the stores it created', () async {
    final ledger = Ledger();
    final counter = ledger.store(const _Counter());
    var disposed = false;
    // The store's change stream completes only when its controller is closed —
    // which `dispose` does, so a `done` here proves `close` fanned out to it.
    counter.changes.listen((_) {}, onDone: () => disposed = true);
    ledger.close();
    await Future<void>.delayed(Duration.zero);
    expect(disposed, isTrue);
  });
}
