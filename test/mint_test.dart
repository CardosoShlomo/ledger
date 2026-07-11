import 'package:regent/regent.dart';
import 'package:test/test.dart';

// ── A counter unit ABOVE the minting gate: only an index-0 round reaches it ──

class _Ping extends Msg {
  const _Ping();
}

class _Inc extends Msg {
  const _Inc();
}

class _Loop extends Msg {
  const _Loop();
}

final class _Counter extends Unit<int, _Inc> {
  const _Counter() : super(0);

  @override
  int reduce(int state, _Inc msg) => state + 1;
}

/// Forwards the ping AND mints an increment — the derived fact re-enters at
/// index 0, so the counter row ABOVE this gate folds it.
final class _MintOnPing extends Guard<_Ping> {
  const _MintOnPing();

  @override
  Set<Judgment> judge(_Ping msg, ReadStore read) =>
      {.forward(msg), .mint(const _Inc())};
}

/// A self-minting loop — the budget must diagnose it.
final class _LoopGate extends Guard<_Loop> {
  const _LoopGate();

  @override
  Set<Judgment> judge(_Loop msg, ReadStore read) =>
      {.mint(const _Loop())};
}

const _app = Regency({
  _Counter(),
  _MintOnPing(),
});

void main() {
  test('a mint re-enters at index 0: the row ABOVE the gate folds it', () {
    final ledger = Ledger.root(_app);
    ledger.dispatch(const _Ping());
    expect(ledger.at(const _Counter()).base, 1);
    ledger.close();
  });

  test('minted facts are NOT recorded — the entry feed stays inputs-only', () {
    final ledger = Ledger.root(_app);
    final recorded = <Msg>[];
    final sub = ledger.at(.entry).msgs<Msg>().listen(recorded.add);
    ledger.dispatch(const _Ping());
    ledger.dispatch(const _Ping());
    // taps are async — settle the microtask queue
    return Future(() {
      expect(recorded.whereType<_Inc>(), isEmpty);
      expect(recorded.whereType<_Ping>().length, 2);
      expect(ledger.at(const _Counter()).base, 2);
      sub.cancel();
      ledger.close();
    });
  });

  test('replay RE-DERIVES mints from the source facts alone', () {
    final z = replay(_app, const [_Ping(), _Ping(), _Ping()]);
    expect(z[const _Counter()], 3);
  });

  test('the gate memory tells the whole story: forwarded AND minted', () {
    final ledger = Ledger.root(_app);
    final minted = <Msg>[];
    final forwarded = <Msg>[];
    final gate = ledger.at(const _MintOnPing());
    final subs = [
      gate.minted.listen(minted.add),
      gate.forwarded.listen(forwarded.add),
    ];
    ledger.dispatch(const _Ping());
    return Future(() {
      expect(minted.single, isA<_Inc>());
      expect(forwarded.single, isA<_Ping>());
      for (final s in subs) {
        s.cancel();
      }
      ledger.close();
    });
  });

  test('a mint chain past the budget throws — sequencing is diagnosed', () {
    final ledger = Ledger.root(const _LoopGate());
    expect(() => ledger.dispatch(const _Loop()), throwsStateError);
    ledger.close();
  });
}
