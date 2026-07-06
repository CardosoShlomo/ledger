import 'package:test/test.dart';
import 'package:regent/regent.dart';

sealed class _CartMsg extends Msg {
  const _CartMsg();
}

/// The wire request doubles as the PREDICTION — stores need no promotion,
/// so one dispatch is both the send and the instant fold.
class _RemoveItem extends _CartMsg {
  const _RemoveItem(this.id);
  final String id;
}

/// The server echo — same effect as the prediction when it agrees.
class _ItemRemoved extends _CartMsg {
  const _ItemRemoved(this.id);
  final String id;
}

class _Restocked extends _CartMsg {
  const _Restocked(this.id, this.qty);
  final String id;
  final int qty;
}

class _Item with Identifiable<String> {
  const _Item(this.id, this.qty);
  @override
  final String id;
  final int qty;

  @override
  bool operator ==(Object o) => o is _Item && o.id == id && o.qty == qty;
  @override
  int get hashCode => Object.hash(id, qty);
}

final class _CartVerdict extends Verdict<_RemoveItem, _ItemRemoved> {
  const _CartVerdict();
  @override
  Duration get deadline => const Duration(milliseconds: 50);
}

final class _Cart extends Store<String, _Item, _CartMsg> {
  const _Cart() : super(verdict: const _CartVerdict());

  @override
  IdentifiableMap<String, _Item> reduce(
          IdentifiableMap<String, _Item> entities, _CartMsg msg) =>
      switch (msg) {
        _RemoveItem(:final id) => entities.removeById(id),
        _ItemRemoved(:final id) => entities.removeById(id),
        _Restocked(:final id, :final qty) => entities.upsert(_Item(id, qty)),
      };
}

void main() {
  test('a prediction removes instantly; base untouched', () {
    final bus = Bus();
    final cart = StoreMemory(const _Cart(), bus);
    bus.dispatch(const _Restocked('a', 1));
    bus.dispatch(const _RemoveItem('a'));

    expect(cart['a'], isNull); // gone from the effective read
    expect(cart.confirmed('a'), isNotNull); // base clean
    expect(cart.flagsOf('a')?.stability, Stability.pending);
  });

  test('the echo confirms: re-applying the prediction is a no-op', () {
    final bus = Bus();
    final cart = StoreMemory(const _Cart(), bus);
    bus.dispatch(const _Restocked('a', 1));
    bus.dispatch(const _RemoveItem('a'));
    bus.dispatch(const _ItemRemoved('a'));

    expect(cart['a'], isNull);
    expect(cart.confirmed('a'), isNull); // base agrees now
    expect(cart.flagsOf('a'), isNull); // removed rows carry no flags
  });

  test('silence REVERTS at the deadline: the row returns', () async {
    final bus = Bus();
    final cart = StoreMemory(const _Cart(), bus);
    bus.dispatch(const _Restocked('a', 1));
    bus.dispatch(const _RemoveItem('a'));
    await Future<void>.delayed(const Duration(milliseconds: 80));

    expect(cart['a']?.qty, 1); // back
    expect(cart.flagsOf('a')?.stability, Stability.reverted);
  });

  test('predictions on different keys settle independently', () async {
    final bus = Bus();
    final cart = StoreMemory(const _Cart(), bus);
    bus.dispatch(const _Restocked('a', 1));
    bus.dispatch(const _Restocked('b', 1));
    bus.dispatch(const _RemoveItem('a'));
    bus.dispatch(const _RemoveItem('b'));
    bus.dispatch(const _ItemRemoved('a')); // only a's echo

    expect(cart.confirmed('a'), isNull); // a settled
    expect(cart['b'], isNull); // b still predicted
    expect(cart.flagsOf('b')?.stability, Stability.pending);
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(cart['b']?.qty, 1); // b reverted alone
  });

  test('a resolver that lands elsewhere leaves the prediction waiting', () {
    final bus = Bus();
    final cart = StoreMemory(const _Cart(), bus);
    bus.dispatch(const _Restocked('a', 1));
    bus.dispatch(const _Restocked('b', 1));
    bus.dispatch(const _RemoveItem('a'));
    bus.dispatch(const _ItemRemoved('b')); // unrelated key

    expect(cart['a'], isNull); // still predicted
    expect(cart.flagsOf('a')?.stability, Stability.pending);
  });
}
