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
  // [lane] distinguishes two rows of this store in one ledger — identical
  // const instances are ONE citizen (identity keying), so rows must differ.
  const _Prices([this.lane = 0]);
  final int lane;

  @override
  IdentifiableMap<String, _Price> reduce(
          IdentifiableMap<String, _Price> entities, _PriceMsg msg) =>
      switch (msg) {
        _PriceSet(:final id, :final value) =>
          entities.upsert(_Price(id, value)),
      };
}

/// The floor as a UNIT citizen — the guard reads it through `read`, by the
/// canonical const expression (identity lookup, no facade).
final class _Floor extends Unit<double, _PriceMsg> {
  const _Floor(double floor) : super(floor);
  @override
  double reduce(double state, _PriceMsg msg) => state;
}

/// REWRITES an under-floor price up to the floor; drops negatives outright.
final class _FloorGuard extends Guard<_PriceSet> {
  const _FloorGuard();

  @override
  Msg? judge(Envelope env, _PriceSet msg, ReadStore read) {
    final floor = read(const _Floor(10));
    if (msg.value < 0) return null;
    if (msg.value < floor) return _PriceSet(msg.id, floor);
    return msg;
  }
}

final class _NegativeVeto extends Veto<_PriceSet> {
  const _NegativeVeto();

  @override
  bool block(Envelope env, _PriceSet msg, ReadStore read) => msg.value < 0;
}

void main() {
  test('a guard REWRITES for the rows below; the row above saw the original',
      () {
    final ledger = Ledger();
    ledger.unit(const _Floor(10));
    final raw = ledger.store(const _Prices()); // above: the original fact
    ledger.guard(const _FloorGuard());
    final floored = ledger.store(const _Prices(1)); // below: the rewrite

    ledger.dispatch(const _PriceSet('a', 3));

    expect(raw['a']?.value, 3); // the journal-true fact
    expect(floored['a']?.value, 10); // the admitted rewrite
  });

  test('a guard DROPS: rows below never fold, the end of the queue is silent',
      () async {
    final ledger = Ledger();
    ledger.unit(const _Floor(10));
    ledger.guard(const _FloorGuard());
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
    ledger.guard(const _NegativeVeto());
    final prices = ledger.store(const _Prices());

    ledger.dispatch(const _PriceSet('a', -1));
    ledger.dispatch(const _PriceSet('b', 5));

    expect(prices['a'], isNull);
    expect(prices['b']?.value, 5);
  });
}
