import 'package:meta/meta.dart';

/// A FACT. The journal stores it, optimistic overlays re-fold it, replay
/// re-delivers it — so it must never mutate after construction. The
/// annotation makes the analyzer enforce final fields on every subclass.
@immutable
abstract class Msg {
  const Msg();
}
