import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ramifica/app/theme.dart';
import 'package:ramifica/core/cue_clock.dart';
import 'package:ramifica/core/functions_client.dart';
import 'package:ramifica/core/prefetcher.dart';
import 'package:ramifica/core/warm_slot.dart';
import 'package:ramifica/data/repositories/run_repository.dart';
import 'package:ramifica/features/feed/choice_zone.dart';
import 'package:ramifica/features/feed/feed_bloc.dart';
import 'package:ramifica/features/feed/feed_event.dart';
import 'package:ramifica/features/feed/feed_state.dart';
import 'package:ramifica/features/feed/feed_view.dart';
import 'package:ramifica/features/feed/hold_portal.dart';
import 'package:ramifica/features/feed/node_video.dart';
import 'package:ramifica/features/feed/video_frame.dart';

const _png =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8'
    'z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

void main() {
  test('holding starts the default portal', () async {
    final clock = _Clock();
    final bloc = _bloc(clock);
    addTearDown(bloc.close);

    await _open(bloc);
    bloc.add(const PauseReached());
    await bloc.stream.firstWhere((state) => state.phase == FeedPhase.speaking);
    expect(clock.scheduled, const Duration(milliseconds: 4100));
    clock.fire();
    await bloc.stream.firstWhere((state) => state.phase == FeedPhase.window);

    expect(bloc.prefetcher.urls, [
      'https://example.com/video.mp4',
      'https://example.com/next.mp4',
      'https://example.com/ridge.mp4',
    ]);
    bloc.add(const HoldStarted('choice_temple'));
    await bloc.stream.firstWhere((state) => state.phase == FeedPhase.holding);

    expect(bloc.state.holdChoiceId, 'choice_temple');
    expect(bloc.prefetcher.urls.last, 'https://example.com/next.mp4');
  });

  test('a press holds that zone and promotes its clip', () async {
    final clock = _Clock();
    final bloc = _bloc(clock);
    addTearDown(bloc.close);
    await _window(bloc, clock);

    bloc.add(const HoldStarted('choice_ridge'));
    await bloc.stream.firstWhere((state) => state.phase == FeedPhase.holding);

    expect(bloc.state.holdChoiceId, 'choice_ridge');
    expect(bloc.prefetcher.urls.last, 'https://example.com/ridge.mp4');
  });

  test('a press before the window does nothing', () async {
    final bloc = _bloc(_Clock());
    addTearDown(bloc.close);
    await _open(bloc);

    bloc.add(const HoldStarted('choice_ridge'));
    await Future<void>.delayed(Duration.zero);

    expect(bloc.state.phase, FeedPhase.playing);
    expect(bloc.state.holdChoiceId, isNull);
  });

  test('releasing early returns to the window', () async {
    final clock = _Clock();
    final bloc = _bloc(clock);
    addTearDown(bloc.close);
    await _window(bloc, clock);
    bloc.add(const HoldStarted('choice_ridge'));
    await bloc.stream.firstWhere((state) => state.phase == FeedPhase.holding);

    bloc.add(const HoldCancelled());
    await bloc.stream.firstWhere((state) => state.phase == FeedPhase.window);

    expect(bloc.state.holdChoiceId, isNull);
    expect(bloc.prefetcher.urls, contains('https://example.com/ridge.mp4'));
  });

  test('tapping the video toggles the pause while playing', () async {
    final bloc = _bloc(_Clock());
    addTearDown(bloc.close);
    await _open(bloc);

    bloc.add(const VideoTapped());
    await bloc.stream.firstWhere((state) => state.userPaused);
    expect(bloc.state.phase, FeedPhase.playing);

    bloc.add(const VideoTapped());
    await bloc.stream.firstWhere((state) => !state.userPaused);
    expect(bloc.state.phase, FeedPhase.playing);
  });

  test('tapping outside playing never pauses', () async {
    final clock = _Clock();
    final bloc = _bloc(clock);
    addTearDown(bloc.close);
    await _window(bloc, clock);

    bloc.add(const VideoTapped());
    await Future<void>.delayed(Duration.zero);

    expect(bloc.state.phase, FeedPhase.window);
    expect(bloc.state.userPaused, isFalse);
  });

  test('a finished hold ignores the release', () async {
    final clock = _Clock();
    final bloc = _bloc(clock);
    addTearDown(bloc.close);
    await _window(bloc, clock);
    bloc.add(const HoldStarted('choice_ridge'));
    await bloc.stream.firstWhere((state) => state.phase == FeedPhase.holding);
    bloc.add(const HoldCompleted());
    await bloc.stream.firstWhere((state) => state.phase == FeedPhase.playing);
    final runId = bloc.state.runId;
    bloc.add(const HoldCancelled());
    await Future<void>.delayed(Duration.zero);

    // The release arrived after the commit went through: ignored, no
    // revert to the window, same run, hold cleared.
    expect(bloc.state.phase, FeedPhase.playing);
    expect(bloc.state.runId, runId);
    expect(bloc.state.holdChoiceId, isNull);
  });

  testWidgets('feed zones render the small options puck', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 390,
            height: 844,
            child: Stack(
              children: [
                ChoiceZone(
                  choiceId: 'choice_ridge',
                  label: 'Climb the ridge',
                  x: 0.5,
                  y: 0.5,
                  radius: 0.15,
                  video: const VideoFrame(Size(390, 844)),
                  enabled: true,
                  onHoldStart: (_) {},
                ),
              ],
            ),
          ),
        ),
      ),
    );

    // Authored radius 0.15 on this frame spans ~142px, but the visible
    // marker clamps to the 40px options puck with a 20px glyph while the
    // tappable disc keeps the authored geometry.
    expect(
      tester.getSize(find.byKey(const ValueKey('visible-ring-choice_ridge'))),
      const Size(40, 40),
    );
    final icon = tester.widget<Icon>(
      find.descendant(
        of: find.byKey(const ValueKey('visible-ring-choice_ridge')),
        matching: find.byType(Icon),
      ),
    );
    expect(icon.size, 20);
    expect(
      tester.getSize(find.byKey(const ValueKey('ring-choice_ridge'))).width,
      greaterThan(40),
    );
  });

  testWidgets('hotspots appear with the narration and hold mid-voice', (
    tester,
  ) async {
    final clock = _Clock();
    final bloc = _bloc(clock);
    addTearDown(bloc.close);
    await tester.pumpWidget(
      MaterialApp(
        home: BlocProvider.value(
          value: bloc,
          child: FeedView(clipPlayer: _Clip()),
        ),
      ),
    );
    bloc.add(const StoryOpened(storyId: 'story_temple'));
    await _pumpUntil(tester, () => bloc.state.phase == FeedPhase.playing);
    expect(find.byType(ChoiceZone), findsNothing);

    // The muted cue runs on the narration timer: zones rise with it,
    // enabled, instead of waiting for the window.
    bloc.add(const PauseReached());
    await _pumpUntil(tester, () => bloc.state.phase == FeedPhase.speaking);
    expect(find.byType(ChoiceZone), findsNWidgets(2));
    expect(
      tester
          .widget<ChoiceZone>(find.byKey(const ValueKey('choice_ridge')))
          .enabled,
      isTrue,
    );

    // A mid-narration grab cuts the cue and holds like at window; a
    // stray cue end landing mid-hold changes nothing.
    final gesture = await tester.startGesture(_ring(tester, 'choice_ridge'));
    await tester.pump();
    await tester.pump();
    expect(bloc.state.phase, FeedPhase.holding);
    expect(bloc.state.holdChoiceId, 'choice_ridge');
    expect(clock.scheduled, isNull);
    bloc.add(const VoiceFinished());
    await tester.pump();
    expect(bloc.state.phase, FeedPhase.holding);

    // Releasing lands in the window with the zones still up.
    await gesture.up();
    await tester.pumpAndSettle();
    expect(bloc.state.phase, FeedPhase.window);
    expect(bloc.state.holdChoiceId, isNull);
    expect(find.byType(ChoiceZone), findsNWidgets(2));
  });

  testWidgets('the window shows each label under its ring', (tester) async {
    final clock = _Clock();
    final bloc = _bloc(clock, voice: false);
    addTearDown(bloc.close);
    await _showWindow(tester, bloc);

    expect(find.text('Enter the temple'), findsOneWidget);
    expect(find.text('Climb the ridge'), findsOneWidget);
    expect(find.byType(ChoiceZone), findsNWidgets(2));
    expect(
      tester.getTopLeft(find.text('Enter the temple')).dy,
      greaterThan(
        tester
            .getBottomLeft(
              find.byKey(const ValueKey('visible-ring-choice_temple')),
            )
            .dy,
      ),
    );
  });

  testWidgets('the engagement rail hides while the zones are up', (
    tester,
  ) async {
    final clock = _Clock();
    final bloc = _bloc(clock, voice: false);
    addTearDown(bloc.close);
    await tester.pumpWidget(
      MaterialApp(
        home: BlocProvider.value(
          value: bloc,
          child: FeedView(clipPlayer: _Clip()),
        ),
      ),
    );
    bloc.add(const StoryOpened(storyId: 'story_temple'));
    await _pumpUntil(tester, () => bloc.state.phase == FeedPhase.playing);

    AnimatedOpacity rail() => tester.widget<AnimatedOpacity>(
      find.byKey(const ValueKey('action-rail')),
    );
    expect(rail().opacity, 1);
    expect(find.byKey(const ValueKey('rail-like')), findsOneWidget);
    expect(find.byKey(const ValueKey('rail-comment')), findsOneWidget);
    expect(find.byKey(const ValueKey('rail-save')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('rail-comment')));
    await tester.pump();
    expect(
      find.descendant(
        of: find.byType(FeedView),
        matching: find.text('Comments are coming soon.'),
      ),
      findsOneWidget,
    );

    bloc.add(const PauseReached());
    await _pumpUntil(tester, () => bloc.state.phase == FeedPhase.window);
    expect(find.byType(ChoiceZone), findsNWidgets(2));
    expect(rail().opacity, 0);
  });

  testWidgets('tapping the video pauses and resumes the clip', (tester) async {
    final clock = _Clock();
    final bloc = _bloc(clock, voice: false);
    addTearDown(bloc.close);
    await tester.pumpWidget(
      MaterialApp(
        home: BlocProvider.value(
          value: bloc,
          child: FeedView(clipPlayer: _Clip()),
        ),
      ),
    );
    bloc.add(const StoryOpened(storyId: 'story_temple'));
    await _pumpUntil(tester, () => bloc.state.phase == FeedPhase.playing);

    AnimatedOpacity mark(String key) =>
        tester.widget<AnimatedOpacity>(find.byKey(ValueKey(key)));
    bool playing() => tester.widget<NodeVideo>(find.byType(NodeVideo)).play;
    expect(mark('pause-mark').opacity, 0);
    expect(playing(), isTrue);

    await tester.tapAt(const Offset(400, 300));
    await _pumpUntil(tester, () => bloc.state.userPaused);
    expect(mark('pause-mark').opacity, 1);
    expect(playing(), isFalse);

    await tester.tapAt(const Offset(400, 300));
    await _pumpUntil(tester, () => !bloc.state.userPaused);
    expect(mark('play-flash').opacity, 1);
    expect(mark('pause-mark').opacity, 0);
    expect(playing(), isTrue);

    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump();
    expect(mark('play-flash').opacity, 0);
  });

  testWidgets('tapping the video during the window does not pause', (
    tester,
  ) async {
    final clock = _Clock();
    final bloc = _bloc(clock, voice: false);
    addTearDown(bloc.close);
    await tester.pumpWidget(
      MaterialApp(
        home: BlocProvider.value(
          value: bloc,
          child: FeedView(clipPlayer: _Clip()),
        ),
      ),
    );
    bloc.add(const StoryOpened(storyId: 'story_temple'));
    await _pumpUntil(tester, () => bloc.state.phase == FeedPhase.playing);
    bloc.add(const PauseReached());
    await _pumpUntil(tester, () => bloc.state.phase == FeedPhase.window);
    expect(find.byType(ChoiceZone), findsNWidgets(2));

    // Above both zones: an empty stretch of video.
    await tester.tapAt(const Offset(400, 100));
    await tester.pump();
    await tester.pump();
    expect(bloc.state.phase, FeedPhase.window);
    expect(bloc.state.userPaused, isFalse);
    expect(
      tester
          .widget<AnimatedOpacity>(find.byKey(const ValueKey('pause-mark')))
          .opacity,
      0,
    );
  });

  testWidgets('the tap that wakes a hidden clip does not pause', (
    tester,
  ) async {
    final clock = _Clock();
    final bloc = _bloc(clock, voice: false);
    addTearDown(bloc.close);
    await tester.pumpWidget(
      MaterialApp(
        home: BlocProvider.value(
          value: bloc,
          child: FeedView(clipPlayer: _Clip()),
        ),
      ),
    );
    bloc.add(const StoryOpened(storyId: 'story_temple'));
    await _pumpUntil(tester, () => bloc.state.phase == FeedPhase.playing);
    bloc.add(const AppHidden());
    await _pumpUntil(tester, () => bloc.state.hiddenPaused);

    await tester.tapAt(const Offset(400, 300));
    await tester.pump();
    await tester.pump();
    expect(bloc.state.hiddenPaused, isFalse);
    expect(bloc.state.userPaused, isFalse);
  });

  testWidgets('long hotspot labels wrap to a second line', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 390,
            height: 844,
            child: Stack(
              children: [
                ChoiceZone(
                  choiceId: 'meal',
                  label: 'Desbloquear computadora',
                  x: 0.5,
                  y: 0.5,
                  radius: 0.15,
                  video: VideoFrame.fitWidth(
                    const Size(390, 844),
                    sourceSize: const Size(480, 854),
                  ),
                  enabled: true,
                  compact: true,
                  onHoldStart: (_) {},
                ),
              ],
            ),
          ),
        ),
      ),
    );

    final label = tester.widget<Text>(find.text('Desbloquear computadora'));
    expect(label.maxLines, 2);
    expect(label.textAlign, TextAlign.center);
  });

  testWidgets('a short press does not choose', (tester) async {
    final clock = _Clock();
    final bloc = _bloc(clock, voice: false);
    addTearDown(bloc.close);
    await _showWindow(tester, bloc);

    final gesture = await tester.startGesture(_ring(tester, 'choice_ridge'));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(bloc.state.phase, FeedPhase.window);
    expect(bloc.state.holdChoiceId, isNull);
  });

  testWidgets(
    'holding halfway grows the choice color and dims the other zone',
    (tester) async {
      final clock = _Clock();
      final bloc = _bloc(clock, voice: false);
      addTearDown(bloc.close);
      await _showWindow(tester, bloc);

      final gesture = await tester.startGesture(_ring(tester, 'choice_ridge'));
      await tester.pump();
      await tester.pump();
      expect(bloc.state.phase, FeedPhase.holding);

      // Halfway through the 1.5 seconds: the circle grows in the held
      // hotspot's color at half opacity (ridge is the second choice with
      // no authored color, so its fallback is nodeActive) while the
      // untouched zone fades out.
      await tester.pump(const Duration(milliseconds: 750));
      expect(bloc.state.phase, FeedPhase.holding);
      expect(
        tester
            .widget<ColoredBox>(find.byKey(const ValueKey('hold-fill')))
            .color,
        RamificaColors.nodeActive.withValues(alpha: 0.5),
      );
      expect(_fade(tester, 'choice_temple'), 0);
      expect(_fade(tester, 'choice_ridge'), 1);

      // Released halfway: the circle shrinks back, nothing commits, and the
      // faded zone comes back.
      await gesture.up();
      await tester.pumpAndSettle();
      expect(bloc.state.phase, FeedPhase.window);
      expect(bloc.state.holdChoiceId, isNull);
      expect(find.byKey(const ValueKey('hold-fill')), findsNothing);
      expect(_fade(tester, 'choice_temple'), 1);
    },
  );

  testWidgets('releasing mid-hold keeps the growing color while shrinking', (
    tester,
  ) async {
    final clock = _Clock();
    final bloc = _bloc(clock, voice: false);
    addTearDown(bloc.close);
    await _showWindow(tester, bloc);

    final gesture = await tester.startGesture(_ring(tester, 'choice_ridge'));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    final growing = tester
        .widget<ColoredBox>(find.byKey(const ValueKey('hold-fill')))
        .color;

    // The release clears the held choice, but the shrinking circle must
    // keep the color it grew with instead of flashing to the fallback.
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 100));
    expect(bloc.state.phase, FeedPhase.window);
    expect(bloc.state.holdChoiceId, isNull);
    expect(find.byKey(const ValueKey('hold-fill')), findsOneWidget);
    expect(
      tester.widget<ColoredBox>(find.byKey(const ValueKey('hold-fill'))).color,
      growing,
    );
  });

  testWidgets('hotspot rings wear their icon color', (tester) async {
    Color ringOf(String choiceId) {
      final box =
          tester
                  .widget<DecoratedBox>(
                    find.descendant(
                      of: find.byKey(ValueKey('visible-ring-$choiceId')),
                      matching: find.byType(DecoratedBox),
                    ),
                  )
                  .decoration
              as BoxDecoration;
      return (box.border! as Border).top.color;
    }

    final clock = _Clock();
    final bloc = _bloc(clock, voice: false);
    addTearDown(bloc.close);
    await _showWindow(tester, bloc);

    // No authored colors: the first choice falls back to hotspot cyan,
    // the second to nodeActive — icon and ring alike.
    expect(ringOf('choice_temple'), RamificaColors.hotspot);
    expect(ringOf('choice_ridge'), RamificaColors.nodeActive);
  });

  testWidgets('swiping mid-hold cancels instead of committing', (tester) async {
    final clock = _Clock();
    final bloc = _bloc(clock, voice: false);
    addTearDown(bloc.close);
    await _showWindow(tester, bloc);

    final start = _ring(tester, 'choice_ridge');
    final gesture = await tester.startGesture(start);
    await tester.pump();
    await tester.pump();
    expect(bloc.state.phase, FeedPhase.holding);

    // A vertical drag is never a hold: the drag start cancels, the swipe
    // itself is ignored outside playing, and nothing commits.
    await gesture.moveTo(start + const Offset(0, 100));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(bloc.state.phase, FeedPhase.window);
    expect(bloc.state.holdChoiceId, isNull);
    expect(find.byKey(const ValueKey('hold-fill')), findsNothing);
  });

  testWidgets('the portal reports completion only at full cover', (
    tester,
  ) async {
    var completed = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: HoldPortal(
          open: true,
          serial: 1,
          center: const Offset(200, 400),
          startRadius: 20,
          fillColor: const Color(0xFFFF5252),
          onCompleted: () => completed++,
        ),
      ),
    );

    await tester.pump(const Duration(seconds: 1));
    expect(completed, 0);
    expect(find.byKey(const ValueKey('hold-fill')), findsOneWidget);

    await tester.pump(const Duration(seconds: 1));
    expect(completed, 1);

    await tester.pump(const Duration(milliseconds: 500));
    expect(completed, 1);
  });

  testWidgets('closing mid-hold reverses without completing', (tester) async {
    var completed = 0;
    Widget portal(bool open) => MaterialApp(
      home: HoldPortal(
        open: open,
        serial: 1,
        center: const Offset(200, 400),
        startRadius: 20,
        fillColor: const Color(0xFFFF5252),
        onCompleted: () => completed++,
      ),
    );

    await tester.pumpWidget(portal(true));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byKey(const ValueKey('hold-fill')), findsOneWidget);

    await tester.pumpWidget(portal(false));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump();

    expect(completed, 0);
    expect(find.byKey(const ValueKey('hold-fill')), findsNothing);
  });

  testWidgets('a new serial restarts the growth', (tester) async {
    var completed = 0;
    Widget portal(int serial) => MaterialApp(
      home: HoldPortal(
        open: true,
        serial: serial,
        center: const Offset(200, 400),
        startRadius: 20,
        fillColor: const Color(0xFFFF5252),
        onCompleted: () => completed++,
      ),
    );

    await tester.pumpWidget(portal(1));
    await tester.pump(const Duration(seconds: 1));
    expect(completed, 0);

    await tester.pumpWidget(portal(2));
    await tester.pump(const Duration(seconds: 1));
    expect(completed, 0);

    await tester.pump(const Duration(seconds: 1));
    expect(completed, 1);
  });

  testWidgets('releasing outside the ring cancels the hold', (tester) async {
    final clock = _Clock();
    final bloc = _bloc(clock, voice: false);
    addTearDown(bloc.close);
    await _showWindow(tester, bloc);

    final gesture = await tester.startGesture(_ring(tester, 'choice_ridge'));
    await tester.pump();
    expect(bloc.state.phase, FeedPhase.holding);

    await gesture.moveTo(const Offset(10, 10));
    await gesture.up();
    await tester.pump();

    expect(bloc.state.phase, FeedPhase.window);
    expect(bloc.state.holdChoiceId, isNull);
  });

  testWidgets('another finger does not cancel the hold', (tester) async {
    final clock = _Clock();
    final bloc = _bloc(clock, voice: false);
    addTearDown(bloc.close);
    await _showWindow(tester, bloc);

    final hold = await tester.startGesture(_ring(tester, 'choice_ridge'));
    await tester.pump();
    expect(bloc.state.phase, FeedPhase.holding);

    final tap = await tester.startGesture(const Offset(10, 10));
    await tap.up();
    await tester.pump();
    expect(bloc.state.phase, FeedPhase.holding);
    expect(bloc.state.holdChoiceId, 'choice_ridge');

    await hold.up();
    await tester.pump();
    expect(bloc.state.phase, FeedPhase.window);
  });

  testWidgets('the ring follows the cover rect', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            key: const Key('frame'),
            width: 195,
            height: 422,
            child: Stack(
              children: [
                ChoiceZone(
                  choiceId: 'choice_ridge',
                  label: 'Climb the ridge',
                  x: 0.72,
                  y: 0.58,
                  radius: 0.12,
                  video: const VideoFrame(Size(195, 422)),
                  enabled: true,
                  onHoldStart: (_) {},
                ),
              ],
            ),
          ),
        ),
      ),
    );

    // Cover: scale = max(195/9, 422/16) = 26.375; video 237.375x422.
    final origin = tester.getTopLeft(find.byKey(const Key('frame')));
    expect(
      tester.getCenter(find.byKey(const ValueKey('ring-choice_ridge'))),
      offsetMoreOrLessEquals(origin + const Offset(149.7225, 244.76)),
    );
  });

  testWidgets('completing then closing runs the ring exit', (tester) async {
    var completed = 0;
    Widget portal(bool open) => MaterialApp(
      home: HoldPortal(
        open: open,
        serial: 1,
        center: const Offset(200, 400),
        startRadius: 20,
        fillColor: const Color(0xFFFF5252),
        onCompleted: () => completed++,
      ),
    );

    await tester.pumpWidget(portal(true));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(completed, 1);
    expect(find.byKey(const ValueKey('hold-fill')), findsOneWidget);

    // Closing after completion runs the ring exit instead of shrinking.
    await tester.pumpWidget(portal(false));
    await tester.pump(const Duration(milliseconds: 100));
    expect(completed, 1);
    expect(find.byKey(const ValueKey('hold-ring')), findsOneWidget);
    expect(find.byKey(const ValueKey('hold-fill')), findsNothing);

    await tester.pumpAndSettle();
    expect(completed, 1);
    expect(find.byKey(const ValueKey('hold-ring')), findsNothing);
    expect(find.byKey(const ValueKey('hold-fill')), findsNothing);
  });

  testWidgets('a new hold mid-exit restarts growth', (tester) async {
    var completed = 0;
    Widget portal({required bool open, required int serial}) => MaterialApp(
      home: HoldPortal(
        open: open,
        serial: serial,
        center: const Offset(200, 400),
        startRadius: 20,
        fillColor: const Color(0xFFFF5252),
        onCompleted: () => completed++,
      ),
    );

    await tester.pumpWidget(portal(open: true, serial: 1));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(completed, 1);

    // Reopening with the same serial mid-exit cancels the exit and grows.
    await tester.pumpWidget(portal(open: false, serial: 1));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const ValueKey('hold-ring')), findsOneWidget);

    await tester.pumpWidget(portal(open: true, serial: 1));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const ValueKey('hold-fill')), findsOneWidget);
    expect(find.byKey(const ValueKey('hold-ring')), findsNothing);

    // A new serial mid-exit restarts growth too, and still completes.
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(completed, 2);
    await tester.pumpWidget(portal(open: false, serial: 1));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const ValueKey('hold-ring')), findsOneWidget);

    await tester.pumpWidget(portal(open: true, serial: 2));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const ValueKey('hold-fill')), findsOneWidget);
    expect(find.byKey(const ValueKey('hold-ring')), findsNothing);

    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(completed, 3);
  });
}

Future<void> _open(FeedBloc bloc) async {
  bloc.add(const StoryOpened(storyId: 'story_temple'));
  await bloc.stream.firstWhere((state) => state.phase == FeedPhase.playing);
}

Future<void> _window(FeedBloc bloc, _Clock clock) async {
  await _open(bloc);
  bloc.add(const PauseReached());
  await bloc.stream.firstWhere((state) => state.phase == FeedPhase.speaking);
  clock.fire();
  await bloc.stream.firstWhere((state) => state.phase == FeedPhase.window);
}

Future<void> _showWindow(WidgetTester tester, FeedBloc bloc) async {
  await tester.pumpWidget(
    MaterialApp(
      home: BlocProvider.value(
        value: bloc,
        child: FeedView(clipPlayer: _Clip()),
      ),
    ),
  );
  bloc.add(const StoryOpened(storyId: 'story_temple'));
  await tester.pumpAndSettle();
  bloc.add(const PauseReached());
  await tester.pumpAndSettle();
}

/// Pumps until [done] with a bounded loop instead of settling, so the
/// test never waits on unrelated timers or animations.
Future<void> _pumpUntil(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 50 && !done(); i++) {
    await tester.pump();
  }
  expect(done(), isTrue);
}

Offset _ring(WidgetTester tester, String choiceId) {
  return tester.getCenter(find.byKey(ValueKey('ring-$choiceId')));
}

double _fade(WidgetTester tester, String choiceId) {
  return tester
      .widget<AnimatedOpacity>(find.byKey(ValueKey('zone-fade-$choiceId')))
      .opacity;
}

FeedBloc _bloc(_Clock clock, {bool voice = true}) {
  return FeedBloc(
    repository: RunRepository(
      execute: FunctionsClient(
        call: (name, data) async {
          if (name == 'startRun') {
            return {
              'runId': 'run_1',
              'storyId': 'story_temple',
              'status': 'active',
            };
          }
          return _playback(voice: voice);
        },
      ).call,
    ),
    prefetcher: Prefetcher(open: _Slot.new),
    clock: clock,
  );
}

Map<String, dynamic> _playback({required bool voice}) {
  return {
    'runId': 'run_1',
    'status': 'active',
    'story': {
      'storyId': 'story_temple',
      'title': 'The temple secret',
      'authorName': 'Alex Vance',
    },
    'node': {
      'nodeId': 'node_001',
      'title': 'The temple door',
      'isEnding': false,
      'videoUrl': 'https://example.com/video.mp4',
      'durationSeconds': 10,
      'ttsText': voice ? 'Enter or climb?' : null,
      'ttsAudioUrl': voice ? 'https://example.com/voice.m4a' : null,
      'ttsDurationSeconds': voice ? 4.1 : null,
      'videoFrameLastBlurData': 'data:image/png;base64,$_png',
    },
    'choices': [
      {
        'choiceId': 'choice_temple',
        'label': 'Enter the temple',
        'targetNodeId': 'node_002',
        'isDefault': true,
        'x': 0.25,
        'y': 0.55,
        'radius': 0.12,
        'targetSecret': false,
        'target': {
          'nodeId': 'node_002',
          'videoUrl': 'https://example.com/next.mp4',
        },
      },
      {
        'choiceId': 'choice_ridge',
        'label': 'Climb the ridge',
        'targetNodeId': 'node_003',
        'isDefault': false,
        'x': 0.72,
        'y': 0.58,
        'radius': 0.12,
        'targetSecret': false,
        'target': {
          'nodeId': 'node_003',
          'videoUrl': 'https://example.com/ridge.mp4',
        },
      },
    ],
  };
}

class _Slot implements WarmSlot {
  @override
  void mount(String url) {}

  @override
  void dispose() {}
}

class _Clock implements CueClock {
  Duration? scheduled;
  void Function()? _fire;

  @override
  void schedule(Duration duration, void Function() fire) {
    scheduled = duration;
    _fire = fire;
  }

  @override
  void cancel() {
    scheduled = null;
    _fire = null;
  }

  void fire() {
    final next = _fire;
    _fire = null;
    next?.call();
  }
}

class _Clip implements ClipPlayer {
  @override
  bool ready = false;
  final _listeners = <VoidCallback>[];

  @override
  bool get ended => false;

  @override
  Future<void> open({
    required Uri url,
    required bool muted,
    required bool play,
  }) async {
    ready = true;
    for (final listener in List<VoidCallback>.of(_listeners)) {
      listener();
    }
  }

  @override
  Future<void> setMuted(bool muted) async {}

  @override
  void pause() {}

  @override
  void resume() {}

  @override
  void addListener(VoidCallback listener) => _listeners.add(listener);

  @override
  void removeListener(VoidCallback listener) => _listeners.remove(listener);

  @override
  Widget buildView() => const SizedBox.expand();

  @override
  void dispose() {}
}
