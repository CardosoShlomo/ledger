import 'dart:async';

import 'package:ledger/ledger.dart';
import 'package:test/test.dart';

// --- domain ----------------------------------------------------------------
class Item with Identifiable<String> {
  Item(this.id, this.name);
  @override
  final String id;
  final String name;
}

sealed class ItemMsg extends Msg with Identifiable<String> {
  ItemMsg(this.id);
  @override
  final String id;
}

class ItemLoaded extends ItemMsg {
  ItemLoaded(super.id, this.name);
  final String name;
}

class ItemRenamed extends ItemMsg {
  ItemRenamed(super.id, this.name);
  final String name;
}

final class Items extends Registry<Item, ItemMsg, String> {
  const Items();
  @override
  Item? reduce(Item? s, ItemMsg m) => switch (m) {
        ItemLoaded(:final id, :final name) => Item(id, name),
        ItemRenamed(:final id, :final name) => Item(id, name),
      };
}

// --- a stand-in for canon's nav graph --------------------------------------
enum Screen { home, detail }

class _Entry {
  _Entry(this.screen, this.id);
  final Enum screen;
  final Object? id;
}

class FakeGraph {
  final List<_Entry> stack = [_Entry(Screen.home, null)];
  final _nav = StreamController<void>.broadcast(sync: true);
  Stream<void> get navigations => _nav.stream;
  void go(Enum screen, Object? id) {
    stack.add(_Entry(screen, id));
    _nav.add(null);
  }
}

// --- hand-written mirror of the GENERATED `Data` surface -------------------
abstract final class Data {
  static late final RegistryStore<Item, ItemMsg, String> _items;
  static late final FakeGraph _graph;

  static void bind(Ledger ledger, FakeGraph graph) {
    _items = ledger.registry(const Items());
    _graph = graph;
    graph.navigations.listen((_) => surfaceLive());
    surfaceLive();
  }

  static void onFetchItem(Fetch<String> f) => _items.onFetch(f);

  static Item? itemOnDetail() {
    for (final e in _graph.stack) {
      if (e.screen == Screen.detail) return _items[e.id as String];
    }
    return null;
  }

  static Stream<Item?>? consumeItemOnDetail() {
    for (final e in _graph.stack) {
      if (e.screen == Screen.detail) return _items.consume(e.id as String);
    }
    return null;
  }

  static void surfaceItemOnDetail() {
    for (final e in _graph.stack) {
      if (e.screen == Screen.detail) {
        _items.surface(e.id as String);
        return;
      }
    }
  }

  static void surfaceLive() => surfaceItemOnDetail();
}

void main() {
  test('e2e: nav → surface → fetch → consume; optimistic rename round-trips',
      () async {
    final ledger = Ledger();
    final graph = FakeGraph();
    Data.bind(ledger, graph);

    // transport: a fetch loads the item from a fake server, dispatching it back.
    final server = {'x': 'Widget'};
    Data.onFetchItem((id) async => ledger.dispatch(ItemLoaded(id, server[id]!)));

    // at home: detail isn't live, so there's nothing to read or consume.
    expect(Data.itemOnDetail(), isNull);
    expect(Data.consumeItemOnDetail(), isNull);

    // navigate → the commit fires surfaceLive → surface('x') → fetch → confirmed.
    graph.go(Screen.detail, 'x');
    expect(Data.itemOnDetail()?.name, 'Widget');
    expect(Data._items.flagsOf('x')?.stability, Stability.confirmed);

    // consume the live value reactively.
    final seen = <String?>[];
    final sub = Data.consumeItemOnDetail()!.listen((i) => seen.add(i?.name));
    await Future<void>.delayed(Duration.zero);
    expect(seen, ['Widget']);

    // optimistic rename: instant overlay, then confirm via the effect's result.
    await ledger.command(ItemRenamed('x', 'Renamed'),
        effect: () async => ItemRenamed('x', 'Renamed'));
    await Future<void>.delayed(Duration.zero);

    expect(Data.itemOnDetail()?.name, 'Renamed');
    expect(Data._items.flagsOf('x')?.stability, Stability.confirmed);
    expect(seen.first, 'Widget');
    expect(seen.last, 'Renamed');

    // navigating again to an ALREADY-fresh key triggers no second fetch.
    var fetches = 0;
    Data.onFetchItem((id) async {
      fetches++;
      ledger.dispatch(ItemLoaded(id, server[id]!));
    });
    graph.go(Screen.detail, 'x'); // same key, still confirmed
    expect(fetches, 0); // surface no-op on a fresh key

    await sub.cancel();
    ledger.close();
  });
}
