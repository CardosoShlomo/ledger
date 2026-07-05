import 'package:test/test.dart';
import 'package:regent/regent.dart';

sealed class _RadiusMsg extends Msg {
  const _RadiusMsg();
}

class _SetRadius extends _RadiusMsg {
  const _SetRadius(this.m);
  final int m;
}

final class _Radius extends Unit<int, _RadiusMsg> {
  const _Radius() : super(500);
  @override
  int reduce(int state, _RadiusMsg m) => switch (m) { _SetRadius(:final m) => m };
}

void main() {
  test('optimistic overlay shows instantly; base stays untouched', () {
    final bus = Bus();
    final unit = UnitMemory(const _Radius(), bus);
    bus.dispatch(const _SetRadius(1000)); // confirmed base
    bus.dispatch(const _SetRadius(5000), optimistic: true, correlationId: 'C1');

    expect(unit.value, 5000); // EFFECTIVE = overlay over base
  });

  test('a message with the matching correlationId confirms (promote + drop)',
      () {
    final bus = Bus();
    final unit = UnitMemory(const _Radius(), bus);
    bus.dispatch(const _SetRadius(5000), optimistic: true, correlationId: 'C1');
    bus.dispatch(const _SetRadius(5000), correlationId: 'C1'); // server echo

    expect(unit.value, 5000);
    unit.rollback('C1'); // already promoted — nothing to discard
    expect(unit.value, 5000);
  });

  test('rollback discards the prediction, returns to base', () {
    final bus = Bus();
    final unit = UnitMemory(const _Radius(), bus);
    bus.dispatch(const _SetRadius(1000));
    bus.dispatch(const _SetRadius(5000), optimistic: true, correlationId: 'C1');
    expect(unit.value, 5000);

    unit.rollback('C1');
    expect(unit.value, 1000);
  });

  test('a superseding confirmed write survives a later rollback', () {
    final bus = Bus();
    final unit = UnitMemory(const _Radius(), bus);
    bus.dispatch(const _SetRadius(5000), optimistic: true, correlationId: 'C1');
    bus.dispatch(const _SetRadius(2000)); // unrelated confirmed write to base

    unit.rollback('C1');
    expect(unit.value, 2000); // base was never polluted by the prediction
  });

  test('rollback flags reverted; the next family fact clears it', () {
    final bus = Bus();
    final unit = UnitMemory(const _Radius(), bus);
    bus.dispatch(const _SetRadius(1000));
    bus.dispatch(const _SetRadius(5000), optimistic: true, correlationId: 'C1');
    expect(unit.reverted, isFalse);

    unit.rollback('C1');
    expect(unit.value, 1000);
    expect(unit.reverted, isTrue); // failed optimism, renderable

    bus.dispatch(const _SetRadius(2000)); // reality speaks again
    expect(unit.reverted, isFalse);
  });

  test('a rollback that changed nothing does not flag reverted', () {
    final bus = Bus();
    final unit = UnitMemory(const _Radius(), bus);
    bus.dispatch(const _SetRadius(5000), optimistic: true, correlationId: 'C1');
    bus.dispatch(const _SetRadius(5000), correlationId: 'C1'); // confirmed

    unit.rollback('C1'); // already promoted — value unchanged
    expect(unit.reverted, isFalse);
  });

  test('ledger.rollback reaches unit stores', () {
    final ledger = Ledger();
    final unit = ledger.unit(const _Radius());
    ledger.dispatch(const _SetRadius(5000),
        optimistic: true, correlationId: 'C9');
    expect(unit.value, 5000);

    ledger.rollback('C9');
    expect(unit.value, 500);
  });
}
