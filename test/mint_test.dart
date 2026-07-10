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

enum _Rows with RegentNode<_Rows> {
  counter(_Counter()),
  gate(_MintOnPing());

  const _Rows(this.regent);
  @override
  final Regent regent;
}

enum _LoopRows with RegentNode<_LoopRows> {
  gate(_LoopGate());

  const _LoopRows(this.regent);
  @override
  final Regent regent;
}

void main() {
  test('a mint re-enters at index 0: the row ABOVE the gate folds it', () {
    final ledger = Ledger.of(_Rows.values);
    ledger.dispatch(const _Ping());
    expect(ledger.read(const _Counter()), 1);
    ledger.close();
  });

  test('minted facts are NOT journaled — the journal stays inputs-only', () {
    final ledger = Ledger.of(_Rows.values);
    final journaled = <Msg>[];
    final sub = ledger.journal.on<Msg>().listen(journaled.add);
    ledger.dispatch(const _Ping());
    ledger.dispatch(const _Ping());
    // taps are async — settle the microtask queue
    return Future(() {
      expect(journaled.whereType<_Inc>(), isEmpty);
      expect(journaled.whereType<_Ping>().length, 2);
      expect(ledger.read(const _Counter()), 2);
      sub.cancel();
      ledger.close();
    });
  });

  test('replay RE-DERIVES mints from the source facts alone', () {
    final z = replay(_Rows.values, const [_Ping(), _Ping(), _Ping()]);
    expect(z[_Rows.counter], 3);
  });

  test('a mint chain past the budget throws — sequencing is diagnosed', () {
    final ledger = Ledger.of(_LoopRows.values);
    expect(() => ledger.dispatch(const _Loop()), throwsStateError);
    ledger.close();
  });
}
