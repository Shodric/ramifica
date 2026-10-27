import 'dart:async';

/// Schedules the muted subtitle. Tests pass a clock that fires on demand.
abstract class CueClock {
  void schedule(Duration duration, void Function() fire);

  void cancel();
}

class TimerCueClock implements CueClock {
  Timer? _timer;

  @override
  void schedule(Duration duration, void Function() fire) {
    _timer?.cancel();
    if (duration <= Duration.zero) {
      fire();
      return;
    }
    _timer = Timer(duration, fire);
  }

  @override
  void cancel() {
    _timer?.cancel();
    _timer = null;
  }
}
