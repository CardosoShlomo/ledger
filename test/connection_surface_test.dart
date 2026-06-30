import 'package:ledger/ledger.dart';
import 'package:test/test.dart';

class _Line with Identifiable<String> {
  _Line(this.id, this.at);
  @override
  final String id;
  final int at;
}

class _Push extends Msg {
  const _Push(this.chat, this.line);
  final String chat;
  final _Line line;
}

final class _Chat extends ConnectionRegistry<_Line, String, int, _Push, String> {
  const _Chat();
  @override
  String keyOf(_Push m) => m.chat;
  @override
  int sortKeyOf(_Line e) => e.at;
  @override
  void apply(Connection<_Line, String, int> c, _Push m) => c.receive(m.line);
}

void main() {
  test('surface requests the initial page once; idempotent until invalidate', () {
    final bus = Bus();
    final store = ConnectionStore(const _Chat(), bus);
    final loaded = <String>[];
    store.onFetch((k) async => loaded.add(k));

    store.surface('a'); // first → fetch
    store.surface('a'); // already requested → no-op
    expect(loaded, ['a']);

    store.invalidate('a'); // re-arm
    store.surface('a'); // fetch again
    expect(loaded, ['a', 'a']);
  });

  test('a disconnect re-arms surface (loaded pages may be stale)', () {
    final bus = Bus();
    final store = ConnectionStore(const _Chat(), bus);
    final loaded = <String>[];
    store.onFetch((k) async => loaded.add(k));

    store.surface('a');
    bus.setConnected(false); // clears surfaced
    store.surface('a'); // refetches
    expect(loaded, ['a', 'a']);
  });
}
