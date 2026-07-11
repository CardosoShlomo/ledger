import 'package:regent/regent.dart';
import 'package:test/test.dart';

sealed class _M extends Msg {
  const _M();
}

class _Set extends _M {
  const _Set(this.v);
  final int v;
}

class _PendingSet extends _M {
  const _PendingSet(this.v);
  final int? v;
}

final class _Main extends Unit<int, _M> {
  const _Main() : super(0);
  @override
  int reduce(int s, _M m) => switch (m) {
        _Set(:final v) => v,
        _PendingSet() => s,
      };
}

final class _Side extends Unit<int?, _M> {
  const _Side() : super(null);
  @override
  int? reduce(int? s, _M m) => switch (m) {
        _PendingSet(:final v) => v,
        _Set() => s,
      };
}

final class _ApplyPending extends UnitProjection<int?, int> {
  const _ApplyPending();
  @override
  int resolve(int value, int? source) => source ?? value;
}

void main() {
  test('a unit merge edge resolves reads; base stays honest', () {
    final bus = Bus();
    final main = UnitMemory(const _Main(), bus);
    final side = UnitMemory(const _Side(), bus);
    main.merge(side, const _ApplyPending());

    bus.dispatch(const _Set(1));
    expect(main.state, 1);

    bus.dispatch(const _PendingSet(9));
    expect(main.state, 9); // the edge answers
    expect(main.folded, 1); // the fold never saw it

    bus.dispatch(const _PendingSet(null));
    expect(main.state, 1); // the edge released
  });

  test('a source change fires the target changes stream', () async {
    final bus = Bus();
    final main = UnitMemory(const _Main(), bus);
    final side = UnitMemory(const _Side(), bus);
    main.merge(side, const _ApplyPending());

    var fired = 0;
    main.changes.listen((_) => fired++);
    bus.dispatch(const _PendingSet(9));
    await Future<void>.delayed(Duration.zero);
    expect(fired, greaterThan(0));
    expect(main.state, 9);
  });
}
