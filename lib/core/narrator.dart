/// The node voice. Decoded when the node opens, played at the pause.
abstract class Narrator {
  Future<void> prepare(String url);

  /// Resumes the audio context. Call it from a user gesture.
  void unlock();

  /// Plays the prepared buffer. Calls [onEnded] once when it finishes.
  /// Returns false when there is nothing to play.
  Future<bool> play({required void Function() onEnded});

  void stop();

  void dispose();
}
