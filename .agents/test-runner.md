# Test policy (2026-10-28, owner-corrected — supersedes the owner-runs-all version)

## Who runs what
- **Owner runs ONLY: Flutter UI tests** (`testWidgets` — widget/integration pumping real widgets).
- **Main/agents run everything else:**
  - `functions/`: `npm run lint && npm test` (fast, never hangs).
  - Flutter non-UI: bloc/model/repository/pure unit tests (`test()`, never `testWidgets`).
  - `flutter analyze` / `dart format`: always allowed (static, seconds).

## How to run non-UI Flutter tests without touching UI tests
- Pure unit files: pass multiple paths in one call.
- Mixed files: `--name` with a regex (NOTE: `--plain-name` is substring-only;
  `--name` takes the regex). Exclude widget tests with a negative lookahead:
  `flutter test test/<f>.dart --reporter compact --name '^(?!(widget name 1|widget name 2)$).*'`
  Get exact widget names via `grep -n "testWidgets(" test/<f>.dart`.
- Confirmed-working patterns live in the session history (feed/graph/commit/
  auth/narrator/hold runs, 2026-10-28).

## Hard lessons (do not relearn)
1. `Future.timeout` NEVER fires inside `testWidgets`' FakeAsync zone (timers
   need pumps). A hanging `await` there hangs forever — use bounded pump
   loops (`for` + `tester.pump(duration)` + state check) instead.
2. `tester.ensureSemantics()` handles must be disposed BEFORE the test body
   ends (`addTearDown` runs too late and fails the test). Prefer finding
   widgets by `Key` over semantics finders.
3. `tester.pumpAndSettle()` hangs forever on never-settling trees (FeedView).
   Prefer bounded pumps + `firstWhere`/state checks.
4. `provider`'s `ProviderNotFoundException` implements `Exception`, NOT
   `FlutterError` — `on FlutterError` misses it.
5. `dart:js_interop` breaks VM test compilation on import. Browser-only code
   goes behind conditional imports (`*_stub.dart` /
   `*_web.dart` with `if (dart.library.js_interop)`), mirroring
   `browser_gesture.dart`, `install_guide.dart`, `auth_redirect_*.dart`.
