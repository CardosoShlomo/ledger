// The classic todo app, regent-style — compare it with the version you
// already know. Three things to notice:
//
//  1. Messages are FACTS (`TodoAdded`), never calls. Stores fold them.
//  2. The toggle is OPTIMISTIC with no wire ids: the request itself is the
//     prediction (one dispatch sends and folds); the server's echo settles
//     it by state comparison, and silence reverts it — automatically.
//  3. The queue is positional: the veto row above the store drops duplicate
//     adds before the store ever sees them.
import 'package:regent/regent.dart';

// ── The facts ──
sealed class TodoMsg extends Msg {
  const TodoMsg();
}

class TodoAdded extends TodoMsg {
  const TodoAdded(this.id, this.title);
  final String id;
  final String title;
}

/// The intent AND the prediction: dispatching it folds instantly and tells
/// the transport to send — one dispatch, both jobs. Note it states the
/// TARGET (`done: true`), not the operation ("toggle"): verdicts settle by
/// comparing state, so facts should be absolute — re-applying an absolute
/// fact is a no-op, re-applying a toggle never is.
class CompleteTodo extends TodoMsg {
  const CompleteTodo(this.id, {required this.done});
  final String id;
  final bool done;
}

/// The server's echo — the resolver that settles the prediction.
class TodoToggled extends TodoMsg {
  const TodoToggled(this.id, {required this.done});
  final String id;
  final bool done;
}

// ── The state ──
class Todo with Identifiable<String> {
  const Todo(this.id, this.title, {this.done = false});
  @override
  final String id;
  final String title;
  final bool done;

  Todo completed(bool done) => Todo(id, title, done: done);

  // Verdicts settle by STATE COMPARISON — value equality is the contract.
  @override
  bool operator ==(Object o) =>
      o is Todo && o.id == id && o.title == title && o.done == done;
  @override
  int get hashCode => Object.hash(id, title, done);
}

// ── The store: a pure fold, optimism declared in one line ──
final class ToggleVerdict extends Verdict<CompleteTodo, TodoToggled> {
  const ToggleVerdict();
  @override
  Duration get deadline => const Duration(seconds: 3);
}

final class Todos extends Store<String, Todo, TodoMsg> {
  const Todos() : super(verdict: const ToggleVerdict());

  @override
  IdentifiableMap<String, Todo> reduce(
          IdentifiableMap<String, Todo> todos, TodoMsg msg) =>
      switch (msg) {
        TodoAdded(:final id, :final title) => todos.upsert(Todo(id, title)),
        CompleteTodo(:final id, :final done) ||
        TodoToggled(:final id, :final done) =>
          todos.updateById(id, (t) => t.completed(done)),
      };
}

void main() async {
  final ledger = Ledger();

  // Row order is semantics: the veto stands ABOVE the store it protects.
  late final StoreMemory<String, Todo, TodoMsg> todos;
  ledger.veto<TodoAdded>((msg) => todos[msg.id] != null); // duplicates drop
  todos = ledger.store(const Todos());

  // An effect: the transport lives OUTSIDE the fold, listening post-queue.
  ledger.on<CompleteTodo>().listen((msg) async {
    // fake server: echoes the first write, loses the second
    if (msg.id == 'milk') {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      ledger.dispatch(TodoToggled(msg.id, done: msg.done));
    }
  });

  ledger.dispatch(const TodoAdded('milk', 'Buy milk'));
  ledger.dispatch(const TodoAdded('milk', 'Buy milk')); // vetoed — a no-op
  ledger.dispatch(const TodoAdded('tea', 'Brew tea'));

  // Optimistic write: done flips NOW, `pending` until the echo settles it.
  ledger.dispatch(const CompleteTodo('milk', done: true));
  print('milk done=${todos['milk']!.done} '
      '(${todos.flagsOf('milk')?.stability})'); // true (pending)

  await Future<void>.delayed(const Duration(milliseconds: 200));
  print('milk done=${todos['milk']!.done} '
      '(${todos.flagsOf('milk')?.stability})'); // true (confirmed)

  // The server never answers this one — the deadline reverts it, no code.
  ledger.dispatch(const CompleteTodo('tea', done: true));
  print('tea done=${todos['tea']!.done}'); // true, hopeful
  await Future<void>.delayed(const Duration(seconds: 4));
  print('tea done=${todos['tea']!.done} '
      '(${todos.flagsOf('tea')?.stability})'); // false (reverted)

  ledger.close();
}
