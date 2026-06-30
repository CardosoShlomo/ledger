import 'package:test/test.dart';
import 'package:ledger/ledger.dart';

class _Msg with Identifiable<int> {
  _Msg(this.id);
  @override
  final int id; // id doubles as the sort key here (higher = newer)
}

Connection<_Msg, int, int> _conn() => Connection<_Msg, int, int>((m) => m.id);

List<int> _ids(List<_Msg> ms) => [for (final m in ms) m.id];

void main() {
  test('setWindow assembles a clean newest-first window', () {
    final c = _conn();
    c.setWindow([_Msg(10), _Msg(8), _Msg(9)], hasMoreBefore: true);
    expect(_ids(c.window), [10, 9, 8]); // sorted, descending
    expect(c.hasMoreBefore, true);
    expect(c.hasMoreAfter, false); // atLiveEdge default
    expect(c.floating, isEmpty);
  });

  test('extendOlder appends older, dedupes, keeps window contiguous', () {
    final c = _conn();
    c.setWindow([_Msg(10), _Msg(9), _Msg(8)], hasMoreBefore: true);
    c.extendOlder([_Msg(8), _Msg(7), _Msg(6)], hasMoreBefore: false); // 8 overlaps
    expect(_ids(c.window), [10, 9, 8, 7, 6]); // no dup of 8
    expect(c.hasMoreBefore, false);
  });

  test('live push at the live edge anchors at the head', () {
    final c = _conn();
    c.setWindow([_Msg(10), _Msg(9)], hasMoreBefore: true); // atLiveEdge → hasMoreAfter false
    c.receive(_Msg(11));
    expect(_ids(c.window), [11, 10, 9]);
    expect(c.floating, isEmpty);
  });

  test('live push when NOT at the live edge floats', () {
    final c = _conn();
    c.setWindow([_Msg(5), _Msg(4)], hasMoreBefore: true, atLiveEdge: false); // a gap above
    c.receive(_Msg(20)); // newer than the window, but we're not at head → floats
    expect(_ids(c.window), [5, 4]); // window untouched
    expect(c.floating.map((f) => f.entity.id), [20]);
    expect(c.floating.single.sortKey, 20); // sort key delivered
  });

  test('floatIn stores a gap-separated entry as floating', () {
    final c = _conn();
    c.setWindow([_Msg(100), _Msg(99)], hasMoreBefore: true);
    c.floatIn(_Msg(50)); // info about an unloaded older message
    expect(_ids(c.window), [100, 99]);
    expect(c.floating.single.entity.id, 50);
  });

  test('graduation: a floating entry inside a newly-loaded range joins the window',
      () {
    final c = _conn();
    c.setWindow([_Msg(100), _Msg(99), _Msg(98)], hasMoreBefore: true);
    c.floatIn(_Msg(50)); // floating, below the window
    expect(c.floating.single.entity.id, 50);

    // scroll down and load the region that contains 50
    c.extendOlder([_Msg(97), _Msg(60), _Msg(50), _Msg(40)], hasMoreBefore: true);
    // 50 is now within the loaded [40..100] span → graduated into the window
    expect(c.floating, isEmpty);
    expect(c.window.any((m) => m.id == 50), true);
    expect(_ids(c.window), [100, 99, 98, 97, 60, 50, 40]);
  });

  test('watch emits the current view, then again on each mutation', () async {
    final c = _conn();
    final seen = <List<int>>[];
    final sub = c.watch().listen((v) => seen.add(_ids(v.window)));
    await Future<void>.delayed(Duration.zero); // initial (empty)

    c.setWindow([_Msg(2), _Msg(1)], hasMoreBefore: true);
    c.receive(_Msg(3)); // live edge → anchors
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();

    expect(seen, [
      <int>[], // initial empty
      [2, 1], // after setWindow
      [3, 2, 1], // after receive
    ]);
  });

  test('watch carries the floating set and the load edges', () async {
    final c = _conn();
    c.setWindow([_Msg(5), _Msg(4)], hasMoreBefore: true, atLiveEdge: false);
    ConnectionView<_Msg, int>? last;
    final sub = c.watch().listen((v) => last = v);
    await Future<void>.delayed(Duration.zero);

    c.receive(_Msg(20)); // off live edge → floats
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();

    expect(_ids(last!.window), [5, 4]);
    expect(last!.floating.single.entity.id, 20);
    expect(last!.hasMoreAfter, true); // not at live edge
    expect(last!.hasMoreBefore, true);
  });
}
