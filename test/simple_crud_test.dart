import 'package:regent/regent.dart';
import 'package:test/test.dart';

class Search with Identifiable<String> {
  const Search(this.id, this.query);
  @override
  final String id;
  final String query;
}

/// The whole state tier of a local resource — one line, zero messages.
final class RecentSearchesCrud extends SimpleCrud<String, Search> {
  const RecentSearchesCrud();
}

/// A second resource over the SAME entity — the ledger must refuse the
/// pair at boot: an entity has ONE authoritative home (a second view is a
/// derived read over it), which is what keeps the generic facts
/// collision-free by construction.
final class RecentSearchesTwin extends SimpleCrud<String, Search> {
  const RecentSearchesTwin();
}

void main() {
  const crud = RecentSearchesCrud();

  test('a local resource: add, remove, list — no messages declared', () {
    final ledger = Ledger.root(crud);
    ledger.dispatch(const Added(Search('s1', 'kettle')));
    ledger.dispatch(const Added(Search('s2', 'mug')));
    expect(ledger.at(crud.store).ids, ['s1', 's2']);
    ledger.dispatch(const Removed<String>('s1'));
    expect(ledger.at(crud.store).ids, ['s2']);
    ledger.dispatch(const Listed([Search('s3', 'teapot')]));
    expect(ledger.at(crud.store).ids, ['s3']); // the list replaces wholesale
    expect(ledger.at(crud.covered).state, isTrue);
    expect(crud.dock, isNull); // no wire: adds fold straight in
    expect(crud.cache, isNull); // and no cache tier at all
    ledger.close();
  });

  test('a second brick of the same entity THROWS at boot — one home', () {
    const dup = Regency({RecentSearchesCrud(), RecentSearchesTwin()});
    expect(
        () => Ledger.root(dup),
        throwsA(isA<StateError>().having(
            (e) => e.message, 'message', contains('ONE authoritative home'))));
  });

  test('replay: the local resource is a pure fold like any regent', () {
    final z = replay(crud, const [
      Added(Search('s1', 'kettle')),
      Added(Search('s2', 'mug')),
      Removed<String>('s1'),
    ]);
    expect((z[crud.store] as Map).keys, ['s2']);
  });
}
