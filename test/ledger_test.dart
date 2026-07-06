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
  const _Counter();
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
  test('journal records everything; a posting guard gates what becomes state',
      () async {
    final ledger = Ledger();
    final counter = ledger.store(const _Counter());

    final journalSeen = <Object>[];
    ledger.journal.on<Msg>().listen(journalSeen.add);
    final admittedSeen = <Object>[];
    ledger.on<Msg>().listen(admittedSeen.add);

    ledger.guard<_Reset>((msg, env) => null); // drop resets at posting

    ledger.dispatch(_Inc('a', 5));
    ledger.dispatch(_Reset('a')); // vetoed at posting

    await Future<void>.delayed(Duration.zero); // observers deliver post-cut
    expect(counter['a']?.value, 5); // reset never posted to state
    expect(admittedSeen.length, 1); // ledger.on = the ADMITTED feed — no ghost effects
    expect(journalSeen.length, 2); // …but the journal kept BOTH (complete record)
  });

  test('a registered registry receives posted messages and stamps stability', () {
    final ledger = Ledger();
    final counter = ledger.store(const _Counter());
    ledger.dispatch(_Inc('a', 3));
    expect(counter['a']?.value, 3);
    expect(counter.flagsOf('a')?.stability, Stability.confirmed);
  });

  test('connection state flows through to the stores', () {
    final ledger = Ledger();
    final counter = ledger.store(const _Counter());
    ledger.dispatch(_Inc('a', 1));
    ledger.setConnected(false); // disconnect → confirmed entries go stale
    expect(counter.flagsOf('a')?.stability, Stability.stale);
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
