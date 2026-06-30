import 'package:test/test.dart';
import 'package:ledger/ledger.dart';

class _User with Identifiable<String> {
  _User(this.id, this.name);
  @override
  final String id;
  final String name;
}

void main() {
  test('upsert reads back, replaces on same id', () {
    final s = Store<_User, String>();
    s.upsert(_User('a', 'Ann'));
    s.upsert(_User('b', 'Bob'));
    expect(s['a']?.name, 'Ann');
    expect(s.length, 2);
    s.upsert(_User('a', 'Annie'));
    expect(s['a']?.name, 'Annie');
    expect(s.length, 2);
  });

  test('removeById drops the entry', () {
    final s = Store<_User, String>();
    s.upsert(_User('a', 'Ann'));
    s.removeById('a');
    expect(s['a'], isNull);
    expect(s.length, 0);
  });

  test('changes stream emits the mutated key, in order', () {
    final s = Store<_User, String>();
    final keys = <String>[];
    s.changes.listen(keys.add);
    s.upsert(_User('a', 'Ann'));
    s.upsert(_User('b', 'Bob'));
    s.removeById('a');
    expect(keys, ['a', 'b', 'a']);
  });
}
