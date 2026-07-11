import 'package:regent/regent.dart';
import 'package:test/test.dart';

// ── An ecommerce micro-app declared as a const VALUE ──

sealed class ProductMsg extends Msg {
  const ProductMsg();
}

class Product with Identifiable<String> {
  const Product(this.id, this.name);
  @override
  final String id;
  final String name;

  @override
  bool operator ==(Object o) => o is Product && o.id == id && o.name == name;
  @override
  int get hashCode => Object.hash(id, name);
}

class ProductsLoaded extends ProductMsg {
  const ProductsLoaded(this.products);
  final List<Product> products;
}

class CachedProducts extends ProductMsg {
  const CachedProducts(this.products);
  final List<Product> products;
}

class RenameShop extends ProductMsg {
  const RenameShop(this.name);
  final String name;
}

class ShopSaved extends ProductMsg {
  const ShopSaved(this.name);
  final String name;
}

final class Products extends Store<String, Product, ProductMsg> {
  const Products();
  @override
  IdentifiableMap<String, Product> reduce(
          IdentifiableMap<String, Product> rows, ProductMsg msg) =>
      switch (msg) {
        ProductsLoaded(:final products) => products.toMapById(),
        CachedProducts() || RenameShop() || ShopSaved() => rows,
      };
}

final class LocalProducts extends Store<String, Product, ProductMsg> {
  const LocalProducts();
  @override
  IdentifiableMap<String, Product> reduce(
          IdentifiableMap<String, Product> rows, ProductMsg msg) =>
      switch (msg) {
        CachedProducts(:final products) => {
            for (final p in products)
              if (!rows.containsKey(p.id)) p.id: p,
            ...rows,
          },
        ProductMsg() => rows,
      };
}

final class Covered extends Unit<bool, ProductMsg> {
  const Covered() : super(false);
  @override
  bool reduce(bool state, ProductMsg msg) =>
      switch (msg) { ProductsLoaded() => true, _ => state };
}

final class CacheGate extends Veto<CachedProducts> {
  const CacheGate();
  @override
  bool block(CachedProducts msg, ReadStore read) => read(const Covered());
}

final class Shop extends Unit<String, ShopSaved> {
  const Shop() : super('corner shop');
  @override
  String reduce(String name, ShopSaved msg) => msg.name;
}

final class ShopWrite extends Unit<String?, ProductMsg> {
  const ShopWrite() : super(null);
  @override
  String? reduce(String? pending, ProductMsg msg) => switch (msg) {
        RenameShop(:final name) => name,
        ShopSaved() => null,
        _ => pending,
      };
}

/// The projection IS the edge — endpoints as const super-ctor fields.
final class LocalSupports extends Projection<Product, String, Product> {
  const LocalSupports() : super(const Products(), const LocalProducts());
  @override
  Product resolve(Product? row, Product local) => row ?? local;
}

final class WriteSupportsShop extends UnitProjection<String?, String> {
  const WriteSupportsShop() : super(const Shop(), const ShopWrite());
  @override
  String resolve(String value, String? pending) => pending ?? value;
}

// A nested SEGMENT — the shop's dock as a graft: rows splice in place.
const shopGraft = Regency({
  ShopWrite(),
  Shop(),
}, merges: {WriteSupportsShop()});

const app = Regency({
  Covered(),
  CacheGate(), // protects the shadow below
  LocalProducts(),
  Products(),
  shopGraft, // a graph is a regent: splices here
}, merges: {LocalSupports()});

void main() {
  test('a graph builds a ledger; order is protection; merges auto-wire', () {
    final ledger = Ledger.root(app);

    // The shadow answers the main's reads through the carried edge.
    ledger.dispatch(const CachedProducts([Product('p1', 'kettle')]));
    final products = ledger.at(const Products());
    expect((products['p1'] as Product).name, 'kettle');

    // Once the authority covers, the gate drops late cache for rows below.
    ledger.dispatch(const ProductsLoaded([Product('p2', 'mug')]));
    ledger.dispatch(const CachedProducts([Product('p3', 'ghost')]));
    expect(products['p3'], isNull);
    ledger.close();
  });

  test('a nested graph SPLICES: its rows are real rows, its merges wire', () {
    final ledger = Ledger.root(app);
    ledger.dispatch(const RenameShop('corner & co'));
    final shop = ledger.at(const Shop());
    expect(shop.value, 'corner & co'); // the dock's promise answers reads
    expect(ledger.at(const Shop()).base, 'corner shop'); // base never folds it
    ledger.dispatch(const ShopSaved('corner & co'));
    expect(ledger.at(const Shop()).base, 'corner & co');
    ledger.close();
  });

  test('a single regent IS a ledger — no graph ceremony', () {
    final ledger = Ledger.root(const Covered());
    ledger.dispatch(const ProductsLoaded([]));
    expect(ledger.at(const Covered()).base, isTrue);
    ledger.close();
  });

  test('the identical regent twice anywhere in the tree throws at build', () {
    const dup = Regency({
      Covered(),
      Regency({Covered()}),
    });
    expect(() => Ledger.root(dup), throwsStateError);
  });

  test('the identical graph spliced twice throws at build', () {
    const dup = Regency({
      shopGraft,
      Regency({shopGraft}),
    });
    expect(() => Ledger.root(dup), throwsStateError);
  });

  test('replay: the graph replays to a snapshot keyed by instance', () {
    final a = replay(app, const [
      CachedProducts([Product('p1', 'kettle')]),
      ProductsLoaded([Product('p2', 'mug')]),
    ]);
    final b = replay(app, const [
      ProductsLoaded([Product('p2', 'mug')]),
      CachedProducts([Product('p1', 'kettle')]),
    ]);
    // cache-vs-authority converges in either order — same law, graph form.
    expect(a[const Covered()], isTrue);
    expect(a[const Covered()], b[const Covered()]);
    expect(a[const Shop()], b[const Shop()]);
  });
}
