import 'envelope.dart';
import 'msg.dart';
import 'pure.dart';
import 'store.dart';

/// A PURE judge standing at its row of the queue: every traversing message
/// of the [M] family is submitted to [judge], whose returned set IS the feed
/// the rows below see — one verb for every shape of judgment:
///
///  * `{msg}`            — PASS it unchanged;
///  * `const {}`         — DROP it (the walk stops for every row below;
///                          rows above have already folded);
///  * `{other}`          — REWRITE it;
///  * `{a, b, …}`        — FAN OUT: each message walks the rows below as its
///                          own branch, in set order.
///
/// Non-[M] messages pass untouched. The journal always keeps the ORIGINAL
/// fact — guards shape the admitted feed, never the record — so a replay
/// reproduces every branch deterministically from the source fact.
///
/// The world is readable only through [read] — the OWN ledger's state,
/// looked up by citizen identity — so a guard is replayable by construction:
/// same journal, same verdicts, no dependency on generated code.
abstract base class Guard<M extends Msg> extends Regent {
  const Guard();

  @pure
  Set<Msg> judge(Envelope env, M msg, ReadStore read);

  @override
  Null mount(LedgerRows ledger) {
    ledger.guard<M>(this);
    return null;
  }
}

/// The refusing specialization — a guard that only ever passes or drops.
/// TRUE from [block] drops the message.
abstract base class Veto<M extends Msg> extends Guard<M> {
  const Veto();

  bool block(Envelope env, M msg, ReadStore read);

  @override
  Set<Msg> judge(Envelope env, M msg, ReadStore read) =>
      block(env, msg, read) ? const {} : {msg};
}
