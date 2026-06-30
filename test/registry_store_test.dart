import 'package:test/test.dart';
import 'package:ledger/ledger.dart';

class _CounterState with Identifiable<String> {
  _CounterState(this.id, this.value);
  @override
  final String id;
  final int value;
}

sealed class _CounterMsg extends Msg {
  const _CounterMsg();
}

class _Inc extends _CounterMsg with Identifiable<String> {
  _Inc(this.id, this.by);
  @override
  final String id;
  final int by;
}

class _Reset extends _CounterMsg with Identifiable<String> {
  _Reset(this.id);
  @override
  final String id;
}

final class _Counter extends Registry<_CounterState, _CounterMsg, String> {
  const _Counter();
  @override
  _CounterState? reduce(_CounterState? s, _CounterMsg m) => switch (m) {
        _Inc(:final id, :final by) => _CounterState(id, (s?.value ?? 0) + by),
        _Reset() => null, // remove
      };
}

void main() {
  test('dispatch folds via reduce; flags = confirmed/remote', () {
    final bus = Bus();
    final store = RegistryStore(const _Counter(), bus);
    bus.dispatch(_Inc('a', 5));
    expect(store['a']?.value, 5);
    expect(store.flagsOf('a'),
        const Flags(source: CommonSource.remote, stability: Stability.confirmed));
    bus.dispatch(_Inc('a', 3));
    expect(store['a']?.value, 8);
  });

  test('optimistic dispatch tags the source flag', () {
    final bus = Bus();
    final store = RegistryStore(const _Counter(), bus);
    bus.dispatch(_Inc('a', 1), source: CommonSource.optimistic);
    expect(store.flagsOf('a')?.source, CommonSource.optimistic);
  });

  test('reduce -> null removes the entry and its flags', () {
    final bus = Bus();
    final store = RegistryStore(const _Counter(), bus);
    bus.dispatch(_Inc('a', 5));
    bus.dispatch(_Reset('a'));
    expect(store['a'], isNull);
    expect(store.flagsOf('a'), isNull);
  });

  test('a pure guard vetoes a message without coupling the bus', () {
    final bus = Bus();
    final store = RegistryStore(const _Counter(), bus);
    bus.guard((e) => e.msg is _Reset ? null : e); // drop resets
    bus.dispatch(_Inc('a', 5));
    bus.dispatch(_Reset('a')); // vetoed → 'a' survives
    expect(store['a']?.value, 5);
  });

  test('changes stream emits the key per mutation', () {
    final bus = Bus();
    final store = RegistryStore(const _Counter(), bus);
    final keys = <String>[];
    store.changes.listen(keys.add);
    bus.dispatch(_Inc('a', 1));
    bus.dispatch(_Inc('b', 1));
    expect(keys, ['a', 'b']);
  });
}
