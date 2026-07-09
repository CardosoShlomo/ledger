import 'package:meta/meta.dart';

import 'msg.dart';

/// A message in transit through the queue. `dispatch` produces one; guards
/// judge it. There is NO transit metadata: where a fact came from is said by
/// its TYPE (a msg IS a source); how settled a datum is, by the rows that
/// fold facts about it (docks, in-flight units, coverage) — the ledger keeps
/// nothing beside the fact itself.
@immutable
class Envelope {
  const Envelope(this.msg);

  final Msg msg;

  Envelope copyWith({Msg? msg}) => Envelope(msg ?? this.msg);
}
