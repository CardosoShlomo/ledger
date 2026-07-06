import 'package:test/test.dart';
import 'package:regent/regent.dart';

sealed class _PriceMsg extends Msg {
  const _PriceMsg();
}

class _PriceSet extends _PriceMsg {
  const _PriceSet(this.id, this.value);
  final String id;
  final double value;
}

class _Price with Identifiable<String> {
  const _Price(this.id, this.value);
  @override
  final String id;
  final double value;
}

final class _Prices extends Store<String, _Price, _PriceMsg> {
  const _Prices();

  @override
  IdentifiableMap<String, _Price> reduce(
          IdentifiableMap<String, _Price> entities, _PriceMsg msg) =>
      switch (msg) {
        _PriceSet(:final id, :final value) =>
          entities.upsert(_Price(id, value)),
      };
}

/// A tiny hand facade — the generated one is app-tier.
class _Stores {
  const _Stores(this.floor);
  final double floor;
}

/// REWRITES an under-floor price up to the floor; drops negatives outright.
final class _FloorGuard extends Guard<_PriceSet, _Stores> {
  const _FloorGuard();

  @override
  Msg? judge(Envelope env, _PriceSet msg, _Stores stores) {
    if (msg.value < 0) return null;
    if (msg.value < stores.floor) return _PriceSet(msg.id, stores.floor);
    return msg;
  }
}

final class _NegativeVeto extends Veto<_PriceSet, _Stores> {
  const _NegativeVeto();

  @override
  bool block(Envelope env, _PriceSet msg, _Stores stores) => msg.value < 0;
}

void main() {
  test('a guard REWRITES for the rows below; the row above saw the original',
      () {
    final ledger = Ledger();
    final raw = ledger.store(const _Prices()); // above: the original fact
    ledger.guard(const _FloorGuard(), const _Stores(10));
    final floored = ledger.store(const _Prices()); // below: the rewrite

    ledger.dispatch(const _PriceSet('a', 3));

    expect(raw['a']?.value, 3); // the journal-true fact
    expect(floored['a']?.value, 10); // the admitted rewrite
  });

  test('a guard DROPS: rows below never fold, the end of the queue is silent',
      () async {
    final ledger = Ledger();
    ledger.guard(const _FloorGuard(), const _Stores(10));
    final prices = ledger.store(const _Prices());
    final admitted = <Msg>[];
    ledger.on<Msg>().listen(admitted.add);

    ledger.dispatch(const _PriceSet('a', -1));
    await Future<void>.delayed(Duration.zero);

    expect(prices['a'], isNull);
    expect(admitted, isEmpty);
  });

  test('a Veto is the boolean guard: pass or drop, never rewrite', () {
    final ledger = Ledger();
    ledger.guard(const _NegativeVeto(), const _Stores(0));
    final prices = ledger.store(const _Prices());

    ledger.dispatch(const _PriceSet('a', -1));
    ledger.dispatch(const _PriceSet('b', 5));

    expect(prices['a'], isNull);
    expect(prices['b']?.value, 5);
  });
}
