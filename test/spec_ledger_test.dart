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

enum _Rows with RegentNode<_Rows> {
  docs(_Docs()),
  gate(_NoEmptyShouts()),
  volume(_Volume());

  const _Rows(this.regent);
  @override
  final Regent regent;
}

void main() {
  test('Ledger.of mounts the declared rows; folds work end to end', () async {
    final ledger = Ledger.of(_Rows.values);
    final docs = ledger.memoryOf(.docs) as StoreMemory<String, _Doc, _Msg>;
    final volume = ledger.memoryOf(.volume) as UnitMemory<int, _Msg>;
    expect(ledger.memoryOf(.gate), isNull);
    ledger.dispatch(_Put('a', 'one'));
    ledger.dispatch(_Shout('hey'));
    await Future<void>.delayed(Duration.zero);
    expect(docs['a']!.text, 'one');
    expect(volume.value, 1);
  });

  test('row order is queue order: the gate shields only rows below it',
      () async {
    final ledger = Ledger.of(_Rows.values);
    final volume = ledger.memoryOf(.volume) as UnitMemory<int, _Msg>;
    ledger.dispatch(_Shout(''));
    ledger.dispatch(_Shout('kept'));
    await Future<void>.delayed(Duration.zero);
    expect(volume.value, 1);
  });

  test('on(before:) reads the feed at a declared position', () async {
    final ledger = Ledger.of(_Rows.values);
    final ingress = <String>[], admitted = <String>[], atVolume = <String>[];
    ledger.on<_Shout>(before: .docs).listen((m) => ingress.add(m.text));
    ledger.on<_Shout>(before: .volume).listen((m) => atVolume.add(m.text));
    ledger.on<_Shout>().listen((m) => admitted.add(m.text));
    ledger.dispatch(_Shout(''));
    ledger.dispatch(_Shout('kept'));
    await Future<void>.delayed(Duration.zero);
    expect(ingress, ['', 'kept']);
    expect(atVolume, ['kept']);
    expect(admitted, ['kept']);
  });

  test('a sliced or reordered rows list is rejected', () {
    expect(() => Ledger.of([_Rows.gate, _Rows.volume]), throwsArgumentError);
    expect(() => Ledger.of([_Rows.docs, _Rows.volume]), throwsArgumentError);
  });

  test('two rows holding the identical const instance are one citizen — rejected',
      () {
    final ledger = Ledger();
    ledger.store(const _Docs());
    expect(() => ledger.store(const _Docs()), throwsStateError);
    ledger.close();
  });

  test('reading a spec no row holds throws (identity lookup)', () {
    final ledger = Ledger.of(_Rows.values);
    expect(() => ledger.read(const _Volume()), returnsNormally);
    expect(() => ledger.read(const _Docs()), returnsNormally);
    expect(() => ledger.read(const _Stranger()), throwsStateError);
    ledger.close();
  });
}
