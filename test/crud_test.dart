import 'package:regent/regent.dart';
import 'package:test/test.dart';

// ── An ecommerce resource on the brick: extends = meaning, with = shape ──

sealed class OrderMsg extends Msg {
  const OrderMsg();
}

class Order with Identifiable<String> {
  const Order(this.id, this.total);
  @override
  final String id;
  final int total;
}

class OrdersLoaded extends OrderMsg with ListMsg<Order> {
  const OrdersLoaded(this.items);
  @override
  final List<Order> items;
}

class CachedOrders extends OrderMsg with CacheMsg<Order> {
  const CachedOrders(this.items);
  @override
  final List<Order> items;
}

class PlaceOrder extends OrderMsg with AddMsg<Order> {
  const PlaceOrder(this.item);
  @override
  final Order item;
}

class OrderPlaced extends OrderMsg with EchoOf<Order> {
  const OrderPlaced(this.item);
  @override
  final Order item;
}

class CancelOrder extends OrderMsg with RemoveMsg<String> {
  const CancelOrder(this.id);
  @override
  final String id;
}

class OrderGone extends OrderMsg with RemoveMsg<String> {
  const OrderGone(this.id);
  @override
  final String id;
}

class SessionReset extends Msg with ResetMsg {
  const SessionReset();
}

final class OrdersCrud extends WritableListCrud<String, Order, OrdersLoaded,
    CachedOrders, PlaceOrder, OrderPlaced, CancelOrder, OrderGone> {
  const OrdersCrud();
}

final class OrdersList
    extends ListCrud<String, Order, OrdersLoaded, CachedOrders> {
  const OrdersList();
}

void main() {
  const crud = OrdersCrud();

  StoreMemory<String, Order, Msg> ordersOf(Ledger ledger) =>
      ledger.memory(crud.store) as StoreMemory<String, Order, Msg>;

  test('the brick is one const identity — its parts are THE mounted rows', () {
    expect(identical(crud.store, const OrdersCrud().store), isTrue);
    final ledger = Ledger.root(crud);
    expect(ledger.memory(crud.store), isNotNull);
    expect(ledger.read(crud.covered), isFalse);
    ledger.close();
  });

  test('cache fills until the authority covers; then the gate drops it', () {
    final ledger = Ledger.root(crud);
    final orders = ordersOf(ledger);
    ledger.dispatch(const CachedOrders([Order('o1', 100)]));
    expect(orders['o1'], isNotNull); // shadow answers through the merge
    ledger.dispatch(const OrdersLoaded([Order('o2', 250)]));
    expect(ledger.read(crud.covered), isTrue);
    ledger.dispatch(const CachedOrders([Order('o3', 999)]));
    expect(orders['o3'], isNull); // gated
    ledger.close();
  });

  test('optimistic add docks, appears in reads, settles on the echo', () {
    final ledger = Ledger.root(crud);
    final orders = ordersOf(ledger);
    ledger.dispatch(const OrdersLoaded([]));
    ledger.dispatch(const PlaceOrder(Order('o9', 40)));
    expect(orders['o9'], isNotNull); // pending, via the dock edge
    expect(ledger.read(crud.store)['o9'], isNull); // base truth: not admitted
    ledger.dispatch(const OrderPlaced(Order('o9', 40)));
    expect(ledger.read(crud.store)['o9'], isNotNull); // admitted
    expect(ledger.read(crud.dock!)['o9'], isNull); // dock cleared
    ledger.close();
  });

  test('removal: the intent takes the row now, the confirmation is idempotent',
      () {
    final ledger = Ledger.root(crud);
    final orders = ordersOf(ledger);
    ledger.dispatch(const OrdersLoaded([Order('o1', 100), Order('o2', 250)]));
    ledger.dispatch(const CancelOrder('o1'));
    expect(orders['o1'], isNull);
    ledger.dispatch(const OrderGone('o1'));
    expect(orders['o1'], isNull);
    expect(orders['o2'], isNotNull);
    ledger.close();
  });

  test('reset clears rows, dock, cache, and withdraws coverage', () {
    final ledger = Ledger.root(crud);
    ledger.dispatch(const OrdersLoaded([Order('o1', 100)]));
    ledger.dispatch(const PlaceOrder(Order('o9', 40)));
    ledger.dispatch(const SessionReset());
    expect(ledger.read(crud.store), isEmpty);
    expect(ledger.read(crud.dock!), isEmpty);
    expect(ledger.read(crud.cache), isEmpty);
    expect(ledger.read(crud.covered), isFalse);
    ledger.close();
  });

  test('a read-only preset has no dock and no dock row', () {
    const list = OrdersList();
    expect(list.dock, isNull);
    final ledger = Ledger.root(list);
    ledger.dispatch(const PlaceOrder(Order('o9', 40))); // Never slot: inert
    expect(ledger.read(list.store), isEmpty);
    ledger.close();
  });

  test('a brick splices into a larger graph; outside guards read its parts',
      () {
    final app = Regency({const OrdersList(), crud});
    final ledger = Ledger.root(app);
    ledger.dispatch(const OrdersLoaded([Order('o1', 100)]));
    expect(ledger.read(crud.covered), isTrue);
    expect(ledger.read(const OrdersList().covered), isTrue);
    ledger.close();
  });

  test('replayRoot re-derives the brick — same journal, same snapshot', () {
    const order = [
      CachedOrders([Order('o1', 100)]),
      OrdersLoaded([Order('o2', 250)]),
      PlaceOrder(Order('o9', 40)),
      OrderPlaced(Order('o9', 40)),
    ];
    final a = replayRoot(crud, order);
    final b = replayRoot(crud, order);
    expect((a[crud.store] as Map).keys, ['o2', 'o9']);
    expect((a[crud.store] as Map).keys, (b[crud.store] as Map).keys);
    expect(a[crud.covered], isTrue);
  });
}
