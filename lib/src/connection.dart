import 'dart:async';

import 'package:identifiable/identifiable.dart';

/// An immutable snapshot of a [Connection]: the assembled ordered [window] to
/// render, the [floating] side set, and the load edges. What [Connection.watch]
/// emits and [Connection.view] returns.
class ConnectionView<T, K> {
  const ConnectionView({
    required this.window,
    required this.floating,
    required this.hasMoreBefore,
    required this.hasMoreAfter,
  });
  final List<T> window;
  final List<Floating<T, K>> floating;
  final bool hasMoreBefore;
  final bool hasMoreAfter;
}

/// One floating entry: an entity known to the connection but NOT inside the
/// contiguous anchored window — a gap-separated push, or info about an entry
/// outside the loaded range. Carries its [sortKey] so a consumer can surface it
/// (a "new messages" pill, a placeholder) or hold it until it graduates.
class Floating<T, K> {
  const Floating(this.entity, this.sortKey, {this.incomplete = false});
  final T entity;
  final K sortKey;

  /// True when the entity is a known stub (a reference / partial push) whose
  /// full data hasn't loaded yet.
  final bool incomplete;
}

/// A paginated, normalized, ordered window over [Identifiable] entities keyed by
/// a [Comparable] sort key.
///
/// It holds ONE contiguous ANCHORED window — the clean, in-order list you render
/// directly (`window`) — plus a FLOATING set ([floating]) of entities that are
/// known but not contiguous with the window. Fetched pages merge + dedupe into
/// the window and graduate any floating entries they now cover; a live push
/// anchors at the head only when the window is at the live edge, else it floats.
///
/// This is the SIMPLE-tier connection: a single anchored range + a floating set.
/// (Multiple non-contiguous ranges / explicit gap regions are a later tier.)
class Connection<T extends Identifiable<I>, I, K extends Comparable<Object?>> {
  Connection(this._sortKeyOf, {this.descending = true});

  /// Extracts the order key (e.g. message id or timestamp). Consumer-provided so
  /// the connection is agnostic to the cursor source.
  final K Function(T) _sortKeyOf;

  /// True for newest-first windows (chat): the head is the largest key.
  final bool descending;

  final Map<I, T> _entities = {}; // normalized truth, by id
  final List<I> _window = []; // ids in the contiguous anchored range, ordered
  final Set<I> _floatingIds = {}; // ids known but not contiguous
  final Set<I> _incompleteIds = {}; // known-but-partial stubs
  final StreamController<void> _changes =
      StreamController<void>.broadcast(sync: true);

  /// Older entries exist beyond the window's far edge.
  bool hasMoreBefore = true;

  /// Newer entries exist beyond the window's near edge. `false` ⇒ the window
  /// includes the LIVE EDGE, so a push is contiguous (anchors) rather than floats.
  bool hasMoreAfter = true;

  int _cmp(I a, I b) {
    final r = _sortKeyOf(_entities[a]!).compareTo(_sortKeyOf(_entities[b]!));
    return descending ? -r : r;
  }

  void _sortWindow() => _window.sort(_cmp);

  K? get _windowMin =>
      _window.isEmpty ? null : _sortKeyOf(_entities[_window.last]!);
  K? get _windowMax =>
      _window.isEmpty ? null : _sortKeyOf(_entities[_window.first]!);

  /// After any change, promote floating entries whose key now falls inside the
  /// loaded [min..max] span (the gap around them closed) into the window.
  void _reconcile() {
    final min = _windowMin, max = _windowMax;
    if (min == null || max == null) return;
    final graduated = <I>[];
    for (final id in _floatingIds) {
      final k = _sortKeyOf(_entities[id]!);
      if (k.compareTo(min) >= 0 && k.compareTo(max) <= 0) graduated.add(id);
    }
    if (graduated.isEmpty) return;
    for (final id in graduated) {
      _floatingIds.remove(id);
      _window.add(id);
    }
    _sortWindow();
  }

  /// Set the anchored window to a freshly-fetched contiguous page (initial load
  /// or refresh). [atLiveEdge] true means this page includes the newest entries.
  void setWindow(List<T> page,
      {required bool hasMoreBefore, bool atLiveEdge = true}) {
    for (final e in page) {
      _entities[e.id] = e;
      _floatingIds.remove(e.id);
      _incompleteIds.remove(e.id);
    }
    _window
      ..clear()
      ..addAll(page.map((e) => e.id));
    _sortWindow();
    this.hasMoreBefore = hasMoreBefore;
    hasMoreAfter = !atLiveEdge;
    _reconcile();
    _notify();
  }

  /// Merge a fetched OLDER page at the far edge (loadMore). Dedupes by id and
  /// extends the window; `hasMoreBefore` reports whether still more older exist.
  void extendOlder(List<T> page, {required bool hasMoreBefore}) {
    for (final e in page) {
      _entities[e.id] = e;
      _floatingIds.remove(e.id);
      _incompleteIds.remove(e.id);
      if (!_window.contains(e.id)) _window.add(e.id);
    }
    _sortWindow();
    this.hasMoreBefore = hasMoreBefore;
    _reconcile();
    _notify();
  }

  /// A live push. If the window is at the live edge ([hasMoreAfter] == false),
  /// the entity is contiguous → anchors at the head; otherwise it floats.
  void receive(T entity) {
    _entities[entity.id] = entity;
    _incompleteIds.remove(entity.id);
    if (hasMoreAfter) {
      _floatingIds.add(entity.id);
    } else {
      _floatingIds.remove(entity.id);
      if (!_window.contains(entity.id)) _window.add(entity.id);
      _sortWindow();
    }
    _reconcile();
    _notify();
  }

  /// Store an entity as FLOATING explicitly — info about an entry we can't place
  /// in the window yet (e.g. an edit to an unloaded message). [incomplete] marks
  /// a known-but-partial stub.
  void floatIn(T entity, {bool incomplete = false}) {
    _entities[entity.id] = entity;
    if (!_window.contains(entity.id)) _floatingIds.add(entity.id);
    if (incomplete) {
      _incompleteIds.add(entity.id);
    } else {
      _incompleteIds.remove(entity.id); // full data → no longer a stub
    }
    _reconcile();
    _notify();
  }

  /// The assembled, ordered, contiguous window — render this directly.
  List<T> get window => [for (final id in _window) _entities[id]!];

  /// The side set: floating entries with their sort keys, for the consumer to
  /// surface or hold.
  List<Floating<T, K>> get floating => [
        for (final id in _floatingIds)
          Floating(_entities[id]!, _sortKeyOf(_entities[id]!), incomplete: _incompleteIds.contains(id))
      ];

  T? operator [](I id) => _entities[id];
  int get length => _window.length;

  /// The current snapshot.
  ConnectionView<T, K> get view => ConnectionView(
        window: window,
        floating: floating,
        hasMoreBefore: hasMoreBefore,
        hasMoreAfter: hasMoreAfter,
      );

  /// A reactive, framework-agnostic stream: the current [view] now, then again
  /// after every mutation (window or floating change). Wrap in a StreamBuilder /
  /// StreamProvider / listen raw.
  Stream<ConnectionView<T, K>> watch() {
    late final StreamController<ConnectionView<T, K>> ctrl;
    StreamSubscription<void>? sub;
    ctrl = StreamController<ConnectionView<T, K>>(
      onListen: () {
        ctrl.add(view);
        sub = _changes.stream.listen((_) => ctrl.add(view));
      },
      onCancel: () => sub?.cancel(),
    );
    return ctrl.stream;
  }

  void dispose() => _changes.close();

  void _notify() => _changes.add(null);
}
