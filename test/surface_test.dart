import 'package:ledger/ledger.dart';
import 'package:test/test.dart';

class _Item with Identifiable<String> {
  _Item(this.id);
  @override
  final String id;
}

class _Set extends Msg with Identifiable<String> {
  _Set(this.id);
  @override
  final String id;
}

final class _Items extends Registry<_Item, _Set, String> {
  const _Items();
  @override
  _Item? reduce(_Item? s, _Set m) => _Item(m.id);
}

void main() {
  test('surface fetches only missing/stale keys; fresh + in-flight are no-ops',
      () {
    final bus = Bus();
    final store = RegistryStore(const _Items(), bus);
    final fetched = <String>[];
    store.onFetch((k) async => fetched.add(k));

    store.surface('a'); // missing -> fetch + mark loading
    store.surface('a'); // loading -> no-op
    expect(fetched, ['a']);

    bus.dispatch(_Set('a')); // confirms -> fresh
    store.surface('a'); // confirmed -> no-op
    expect(fetched, ['a']);

    store.invalidate('a'); // confirmed -> stale
    store.surface('a'); // stale -> fetch again
    expect(fetched, ['a', 'a']);
  });

  test('surface is inert without a fetcher (data arrives by push instead)', () {
    final bus = Bus();
    final store = RegistryStore(const _Items(), bus);
    store.surface('a');
    expect(store.flagsOf('a'), isNull); // never marked loading
  });
}
