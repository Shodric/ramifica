/// Verified author, from `--dart-define=CREATOR_EMAIL=name@domain`
/// or `--dart-define-from-file=dart_defines.json`. Empty hides Create.
const storyCreatorEmail = String.fromEnvironment('CREATOR_EMAIL');

bool isStoryCreator({
  String? email,
  bool emailVerified = false,
  String creatorEmail = storyCreatorEmail,
}) {
  final expected = creatorEmail.trim().toLowerCase();
  if (expected.isEmpty) return false;
  final normalized = email?.trim().toLowerCase();
  return emailVerified && normalized == expected;
}
