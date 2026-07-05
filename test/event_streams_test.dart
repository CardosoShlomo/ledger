import 'package:test/test.dart';
import 'package:regent/regent.dart';

enum _Phase { idle, compressing, uploading, done }

sealed class _FlowMsg extends Msg {
  const _FlowMsg();
}

class _Advance extends _FlowMsg {
  const _Advance(this.phase, [this.note = '']);
  final _Phase phase;
  final String note;
}

class _Noted extends _FlowMsg {
  const _Noted(this.note);
  final String note;
}

class _Flow {
  const _Flow(this.phase, this.note);
  final _Phase phase;
  final String note;

  @override
  bool operator ==(Object o) => o is _Flow && o.phase == phase && o.note == note;
  @override
  int get hashCode => Object.hash(phase, note);
}

final class _FlowUnit extends Unit<_Flow, _FlowMsg> {
  const _FlowUnit() : super(const _Flow(_Phase.idle, ''));
  @override
  _Flow reduce(_Flow s, _FlowMsg m) => switch (m) {
        _Advance(:final phase, :final note) => _Flow(phase, note),
        _Noted(:final note) => _Flow(s.phase, note),
      };
}

void main() {
  test('transitions() passes only real moves', () {
    final bus = Bus();
    final unit = UnitMemory(const _FlowUnit(), bus);
    final seen = <_Phase>[];
    unit.events.transitions().listen((e) => seen.add(e.after.phase));
    bus.dispatch(const _Advance(_Phase.compressing));
    bus.dispatch(const _Advance(_Phase.compressing)); // no-op fold
    bus.dispatch(const _Advance(_Phase.uploading));
    expect(seen, [_Phase.compressing, _Phase.uploading]);
  });

  test('transitions(projection) watches one aspect', () {
    final bus = Bus();
    final unit = UnitMemory(const _FlowUnit(), bus);
    var fired = 0;
    unit.events.transitions((s) => s.phase).listen((_) => fired++);
    bus.dispatch(const _Noted('a')); // note moved, phase did not
    bus.dispatch(const _Advance(_Phase.done));
    expect(fired, 1);
  });

  test('entering fires once per arrival at the state', () {
    final bus = Bus();
    final unit = UnitMemory(const _FlowUnit(), bus);
    var arrived = 0;
    unit.events
        .entering(const _Flow(_Phase.done, 'x'))
        .listen((_) => arrived++);
    bus.dispatch(const _Advance(_Phase.done, 'x'));
    bus.dispatch(const _Advance(_Phase.done, 'x')); // already there
    expect(arrived, 1);
  });

  test('on<M>() re-types the msg', () {
    final bus = Bus();
    final unit = UnitMemory(const _FlowUnit(), bus);
    final notes = <String>[];
    unit.events.on<_Noted>().listen((e) => notes.add(e.msg.note));
    bus.dispatch(const _Advance(_Phase.compressing, 'skip'));
    bus.dispatch(const _Noted('kept'));
    expect(notes, ['kept']);
  });
}
