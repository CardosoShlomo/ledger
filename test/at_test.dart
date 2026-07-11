import 'package:regent/regent.dart';
import 'package:test/test.dart';

sealed class _Msg extends Msg {}

class _Put extends _Msg {
  _Put(this.id, this.text);
  final String id;
  final String text;
}

class _Shout extends _Msg {
  _Shout(this.text);
  final String text;
}

class _Doc with Identifiable<String> {
  const _Doc(this.id, this.text);
  @override
  final String id;
  final String text;
}

final class _Docs extends Store<String, _Doc, _Msg> {
  const _Docs();

  @override
  IdentifiableMap<String, _Doc> reduce(
          IdentifiableMap<String, _Doc> entities, _Msg msg) =>
      switch (msg) {
        _Put(:final id, :final text) => entities.upsert(_Doc(id, text)),
        _Shout() => entities,
      };
}

final class _Volume extends Unit<int, _Msg> {
  const _Volume() : super(0);

  @override
  int reduce(int state, _Msg msg) =>
      switch (msg) { _Shout() => state + 1, _Put() => state };
}

/// Not enrolled in any row — the identity lookup must refuse it.
final class _Stranger extends Unit<int, _Msg> {
  const _Stranger() : super(0);
  @override
  int reduce(int s, _Msg m) => s;
}

final class _NoEmptyShouts extends Veto<_Shout> {
  const _NoEmptyShouts();

  @override
  bool block(_Shout msg, ReadStore read) => msg.text.isEmpty;
}

const _app = Regency({
  _Docs(),
  _NoEmptyShouts(),
  _Volume(),
});

void main() {
  test('at() hands back every kind TYPED; folds work end to end', () async {
    final ledger = Ledger.root(_app);
    final StoreMemory<String, _Doc, _Msg> docs = ledger.at(const _Docs());
    final UnitMemory<int, _Msg> volume = ledger.at(const _Volume());
    final GuardMemory<_Shout> gate = ledger.at(const _NoEmptyShouts());
    ledger.dispatch(_Put('a', 'one'));
    ledger.dispatch(_Shout('hey'));
    await Future<void>.delayed(Duration.zero);
    expect(docs['a']!.text, 'one');
    expect(volume.value, 1);
    expect(gate, isNotNull);
    ledger.close();
  });

  test('row order is queue order: the gate shields only rows below it',
      () async {
    final ledger = Ledger.root(_app);
    ledger.dispatch(_Shout(''));
    ledger.dispatch(_Shout('kept'));
    await Future<void>.delayed(Duration.zero);
    expect(ledger.at(const _Volume()).value, 1);
    ledger.close();
  });

  test('every position observes: .entry, a row, a gate, .exit', () async {
    final ledger = Ledger.root(_app);
    final ingress = <String>[], admitted = <String>[], atVolume = <String>[];
    final dropped = <String>[];
    ledger.at(.entry).msgs<_Shout>().listen((m) => ingress.add(m.text));
    ledger
        .at(const _Volume())
        .msgs<_Shout>()
        .listen((m) => atVolume.add(m.text));
    ledger
        .at(const _NoEmptyShouts())
        .dropped
        .listen((m) => dropped.add(m.text));
    ledger.at(.exit).msgs<_Shout>().listen((m) => admitted.add(m.text));
    ledger.dispatch(_Shout(''));
    ledger.dispatch(_Shout('kept'));
    await Future<void>.delayed(Duration.zero);
    expect(ingress, ['', 'kept']); // the RECORD is complete
    expect(dropped, ['']); // the veto's bool, as a feed
    expect(atVolume, ['kept']); // the row below the gate
    expect(admitted, ['kept']); // what exits
    ledger.close();
  });

  test('states/statesBefore branch the atomic fold story', () async {
    final ledger = Ledger.root(_app);
    final befores = <int>[], afters = <int>[];
    ledger.at(const _Volume()).statesBefore.listen(befores.add);
    ledger.at(const _Volume()).states.listen(afters.add);
    ledger.dispatch(_Shout('a'));
    ledger.dispatch(_Shout('b'));
    await Future<void>.delayed(Duration.zero);
    expect(befores, [0, 1]);
    expect(afters, [1, 2]);
    ledger.close();
  });

  test('two rows holding the identical const instance are one regent — rejected',
      () {
    final ledger = Ledger();
    ledger.store(const _Docs());
    expect(() => ledger.store(const _Docs()), throwsStateError);
    ledger.close();
  });

  test('the identical GUARD instance twice is rejected too', () {
    const dup = Regency({_NoEmptyShouts(), Regency({_NoEmptyShouts()})});
    expect(() => Ledger.root(dup), throwsStateError);
  });

  test('standing at a spec no row holds throws (identity lookup)', () {
    final ledger = Ledger.root(_app);
    expect(() => ledger.at(const _Volume()).value, returnsNormally);
    expect(() => ledger.at(const _Docs()).base, returnsNormally);
    expect(() => ledger.at(const _Stranger()), throwsStateError);
    ledger.close();
  });
}
