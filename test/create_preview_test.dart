import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ramifica/core/narrator.dart';
import 'package:ramifica/data/models/draft_node.dart';
import 'package:ramifica/data/models/playback.dart';
import 'package:ramifica/data/models/user.dart';
import 'package:ramifica/data/repositories/auth_repository.dart';
import 'package:ramifica/features/create/create_bloc.dart';
import 'package:ramifica/features/create/create_event.dart';
import 'package:ramifica/features/create/create_node_screen.dart';
import 'package:ramifica/features/create/create_preview.dart';
import 'package:ramifica/features/create/zone_marker.dart';
import 'package:ramifica/features/feed/choice_zone.dart';
import 'package:ramifica/features/feed/ending_card.dart';
import 'package:ramifica/features/feed/feed_bloc.dart';
import 'package:ramifica/features/feed/feed_event.dart';
import 'package:ramifica/features/feed/feed_state.dart';
import 'package:ramifica/features/feed/feed_view.dart';
import 'package:ramifica/features/feed/node_video.dart';
import 'package:ramifica/features/feed/story_chip.dart';
import 'package:ramifica/features/feed/subtitle_line.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import 'support/create_repository_harness.dart';
import 'support/fake_media_platform.dart';

void main() {
  late _PreviewMediaPlatform media;
  late VideoPlayerPlatform previousPlatform;

  setUp(() {
    previousPlatform = VideoPlayerPlatform.instance;
    media = _PreviewMediaPlatform();
    VideoPlayerPlatform.instance = media;
  });

  tearDown(() => VideoPlayerPlatform.instance = previousPlatform);

  testWidgets('the editor marker is centered on the saved hotspot', (
    tester,
  ) async {
    (double, double)? moved;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: Center(
              child: SizedBox(
                width: 300,
                child: ZoneMarker(
                  nodeId: 'root',
                  choices: const [
                    DraftChoice(
                      choiceId: 'door',
                      label: 'Open',
                      targetNodeId: 'next',
                      isDefault: true,
                      x: 0.25,
                      y: 0.65,
                      radius: 0.12,
                    ),
                  ],
                  targets: const [],
                  onZoneMoved: (_, x, y) => moved = (x, y),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    expect(
      tester.getCenter(find.byKey(const ValueKey('zone-ring-root-door'))),
      tester.getCenter(find.byKey(const ValueKey('zone-door'))),
    );
    await tester.tap(find.byKey(const ValueKey('zone-door')));
    await tester.pump();
    final marker = tester.widget<Container>(
      find.byKey(const ValueKey('zone-ring-root-door')),
    );
    final border = (marker.decoration! as BoxDecoration).border! as Border;
    expect(border.top.width, 2);

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('zone-door'))),
    );
    await gesture.moveBy(const Offset(20, 0));
    await tester.pump();
    for (var i = 0; i < 4; i++) {
      await gesture.moveBy(const Offset(10, 0));
      await tester.pump();
    }
    await gesture.up();
    await tester.pump();
    expect(moved, isNotNull);
    expect(moved!.$1, greaterThan(0.25));
    expect(moved!.$2, 0.65);
  });

  test(
    'preview announces when narration starts rather than when it finishes',
    () async {
      final gate = Completer<void>();
      final narrator = _Narrator(startGate: gate);
      final bloc = FeedBloc.preview(playback: _playback, narrator: narrator);
      expect(narrator.prepared, 'https://example.com/voice.m4a');
      expect(bloc.state.muted, isFalse);
      bloc.add(const PauseReached());
      await bloc.stream.firstWhere(
        (state) => state.phase == FeedPhase.speaking,
      );
      expect(bloc.state.previewCueStarted, isFalse);
      expect(narrator.played, isFalse);
      gate.complete();
      await bloc.stream.firstWhere((state) => state.previewCueStarted);
      expect(narrator.played, isTrue);
      narrator.finish();
      await bloc.stream.firstWhere((state) => state.phase == FeedPhase.window);
      await bloc.close();
      expect(narrator.disposed, isTrue);
    },
  );

  testWidgets('hotspots appear when the voice starts and stay visible', (
    tester,
  ) async {
    final gate = Completer<void>();
    final narrator = _Narrator(startGate: gate);
    final bloc = FeedBloc.preview(playback: _playback, narrator: narrator);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      var closed = false;
      final closing = bloc.close().then((_) => closed = true);
      for (var i = 0; i < 30 && !closed; i++) {
        await tester.pump();
        await tester.runAsync(() async {});
      }
      expect(closed, isTrue);
      await closing;
    });
    await tester.pumpWidget(
      MaterialApp(
        home: BlocProvider.value(
          value: bloc,
          child: const FeedView(preview: true),
        ),
      ),
    );
    await _settleMedia(tester);
    media.events[1]!.add(VideoEvent(eventType: VideoEventType.completed));
    await _settleMedia(tester);
    expect(bloc.state.phase, FeedPhase.speaking);
    expect(find.byType(ChoiceZone), findsNothing);

    gate.complete();
    await tester.pump();
    await tester.pump();
    expect(bloc.state.phase, FeedPhase.speaking);
    expect(find.byType(ChoiceZone), findsOneWidget);

    narrator.finish();
    await tester.pump();
    await tester.pump();
    expect(bloc.state.phase, FeedPhase.window);
    expect(find.byType(ChoiceZone), findsOneWidget);
  });

  testWidgets('preview opens the current draft as a full-screen feed', (
    tester,
  ) async {
    media.size = const Size(480, 832);
    final calls = <String>[];
    final users = _Users();
    final editor = await _openEditor(
      tester,
      calls,
      auth: AuthRepository(auth: _Auth(), users: users),
    );
    editor.add(
      const NodeFieldChanged(
        nodeId: 'root',
        choiceLabels: {'door': 'Open the gate'},
      ),
    );
    await tester.pump();
    expect(editor.hasUnsavedNodeEdits('root'), isTrue);
    expect(editor.state.nodes.single.choices.single.label, 'Open the gate');

    await tester.tap(find.byKey(const ValueKey('preview-node-root')));
    await _settleMedia(tester);

    expect(find.byType(CreatePreview), findsOneWidget);
    expect(find.byType(Dialog), findsNothing);
    expect(find.byType(FeedView), findsOneWidget);
    expect(tester.getSize(find.byType(NodeVideo)), const Size(390, 844));
    expect(find.byType(NavigationBar), findsNothing);
    expect(
      tester.widget<NodeVideo>(find.byType(NodeVideo)).fit,
      BoxFit.fitWidth,
    );
    final fittedVideo = tester.renderObject<RenderBox>(
      find.byType(VideoPlayer),
    );
    final videoOrigin = tester.getTopLeft(find.byType(NodeVideo));
    expect(
      fittedVideo.localToGlobal(Offset.zero) - videoOrigin,
      offsetMoreOrLessEquals(const Offset(0, 84), epsilon: 0.01),
    );
    expect(
      fittedVideo.localToGlobal(fittedVideo.size.bottomRight(Offset.zero)) -
          videoOrigin,
      offsetMoreOrLessEquals(const Offset(390, 760), epsilon: 0.01),
    );
    expect(tester.widget<StoryChip>(find.byType(StoryChip)).title, 'Temple');
    expect(tester.widget<StoryChip>(find.byType(StoryChip)).author, 'Identity');
    expect(users.requestedUid, 'author');
    users.account.complete(
      const UserAccount(uid: 'author', displayName: 'Profile name'),
    );
    await tester.pump();
    await tester.pump();
    expect(
      tester.widget<StoryChip>(find.byType(StoryChip)).author,
      'Profile name',
    );
    expect(media.urls.values, ['https://example.com/scene.mp4']);
    expect(media.playing[1], isTrue);
    expect(media.volumes[1], 1);

    // Muting substitutes the subtitle for the voice; the hotspots must
    // appear as that cue begins, while it is still on screen.
    await tester.tap(find.byTooltip('Mute'));
    await tester.pump();
    media.events[1]!.add(VideoEvent(eventType: VideoEventType.completed));
    await _settleMedia(tester);
    expect(find.byType(SubtitleLine), findsOneWidget);
    expect(find.text('Choose a path'), findsOneWidget);
    expect(find.byType(ChoiceZone), findsOneWidget);
    final zone = tester.widget<ChoiceZone>(find.byType(ChoiceZone));
    expect(zone.label, 'Open the gate');
    expect(zone.icon, 'door');
    expect(zone.iconColor, 'amber');
    expect(zone.radius, 0.12);
    // Tappable: pressing a hotspot starts a hold like the player feed;
    // only a full hold navigates to the finished target scene.
    expect(zone.enabled, isTrue);
    expect(zone.compact, isTrue);
    expect(zone.video.screen, const Size(390, 844));
    expect(
      tester.getSize(find.byKey(const ValueKey('visible-ring-door'))),
      const Size(40, 40),
    );
    expect(
      tester.getCenter(find.byKey(const ValueKey('visible-ring-door'))) -
          tester.getTopLeft(find.byType(NodeVideo)),
      offsetMoreOrLessEquals(const Offset(99.9375, 523.4), epsilon: 0.01),
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('ring-door'))).width,
      closeTo(91.26, 0.01),
    );

    final preview = tester.element(find.byType(FeedView)).read<FeedBloc>();
    expect(preview.state.phase, FeedPhase.speaking);
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(find.byType(ChoiceZone), findsOneWidget);
    // A hold starts like in the feed, so opening another story mid-hold
    // is ignored just the same.
    preview.add(const HoldStarted('door'));
    preview.add(const StoryOpened(storyId: 'other'));
    await tester.pump();
    expect(preview.state.phase, FeedPhase.holding);

    await tester.tap(find.byKey(const ValueKey('close-preview')));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {});
    await tester.pump();
    expect(find.byType(CreatePreview), findsNothing);
    expect(find.byType(CreateNodeScreen), findsOneWidget);
    expect(editor.hasUnsavedNodeEdits('root'), isTrue);
    expect(editor.state.nodes.single.choices.single.label, 'Open the gate');
    expect(calls, isEmpty);
    expect(media.disposed, contains(1));
  });

  testWidgets('ending preview plays the clip and closing cue before the card', (
    tester,
  ) async {
    final calls = <String>[];
    await _openEditor(tester, calls, ending: true);
    await tester.tap(find.byKey(const ValueKey('preview-node-root')));
    await _settleMedia(tester);
    expect(media.playing[1], isTrue);
    expect(find.byType(EndingCard), findsNothing);

    await tester.tap(find.byTooltip('Mute'));
    await tester.pump();
    media.events[1]!.add(VideoEvent(eventType: VideoEventType.completed));
    await _settleMedia(tester);
    expect(find.text('The story ends'), findsOneWidget);
    expect(find.byType(EndingCard), findsNothing);
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    final card = tester.widget<EndingCard>(find.byType(EndingCard));
    expect(card.name, 'A new dawn');
    expect(card.type, 'open');
    expect(find.byType(ChoiceZone), findsNothing);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.runAsync(() async {});
    await tester.pump();
    expect(find.byType(CreatePreview), findsNothing);
    expect(find.byType(CreateNodeScreen), findsOneWidget);
    expect(calls, isEmpty);
    expect(media.disposed, contains(1));
  });

  test('preview holds play a finished target, even mid-narration', () async {
    final narrator = _Narrator();
    final bloc = FeedBloc.preview(
      playback: _playback,
      narrator: narrator,
      resolvePreview: (id) =>
          (playback: id == 'next' ? _nextPlayback : null, exists: id == 'next'),
      previewNodeLabel: (id) => id == 'next' ? '1A' : id,
    );
    // Zones hidden while the clip plays: the hold is ignored.
    bloc.add(const HoldStarted('door'));
    await pumpEventQueue();
    expect(bloc.state.phase, FeedPhase.playing);
    expect(bloc.state.playback?.node.nodeId, 'root');

    bloc.add(const PauseReached());
    await bloc.stream.firstWhere((state) => state.previewCueStarted);
    expect(bloc.state.phase, FeedPhase.speaking);

    // Like the feed, the hold runs its full 1.5 seconds and only then
    // jumps to the target scene. A short press never navigates.
    bloc.add(const HoldStarted('door'));
    await bloc.stream.firstWhere((state) => state.phase == FeedPhase.holding);
    bloc.add(const HoldCancelled());
    await bloc.stream.firstWhere((state) => state.phase == FeedPhase.window);
    expect(bloc.state.playback?.node.nodeId, 'root');

    bloc.add(const HoldStarted('door'));
    await bloc.stream.firstWhere((state) => state.phase == FeedPhase.holding);
    bloc.add(const HoldCompleted());
    await bloc.stream.firstWhere(
      (state) => state.playback?.node.nodeId == 'next',
    );
    expect(bloc.state.phase, FeedPhase.playing);
    expect(bloc.state.playback?.node.videoUrl, 'https://example.com/next.mp4');
    expect(bloc.state.previewNotice, isNull);
    await bloc.close();
    expect(narrator.disposed, isTrue);
  });

  test('preview holds on unfinished targets raise a notice and stay', () async {
    final narrator = _Narrator();
    final bloc = FeedBloc.preview(
      playback: _playback,
      narrator: narrator,
      resolvePreview: (_) => (playback: null, exists: true),
      previewNodeLabel: (id) => id == 'next' ? '1A' : id,
    );
    bloc.add(const PauseReached());
    await bloc.stream.firstWhere((state) => state.previewCueStarted);
    narrator.finish();
    await bloc.stream.firstWhere((state) => state.phase == FeedPhase.window);

    bloc.add(const HoldStarted('door'));
    await bloc.stream.firstWhere((state) => state.phase == FeedPhase.holding);
    bloc.add(const HoldCompleted());
    await bloc.stream.firstWhere((state) => state.previewNoticeSerial == 1);
    expect(bloc.state.phase, FeedPhase.window);
    expect(bloc.state.holdChoiceId, isNull);
    expect(bloc.state.playback?.node.nodeId, 'root');
    expect(bloc.state.previewNotice, 'Node "1A" not finished yet');
    expect(bloc.state.previewNoticeTarget, 'next');

    // Repeats replay the notice instead of merging into one.
    bloc.add(const HoldStarted('door'));
    await bloc.stream.firstWhere((state) => state.phase == FeedPhase.holding);
    bloc.add(const HoldCompleted());
    await bloc.stream.firstWhere((state) => state.previewNoticeSerial == 2);
    expect(bloc.state.previewNotice, 'Node "1A" not finished yet');
    expect(bloc.state.previewNoticeTarget, 'next');
    await bloc.close();
  });

  test('preview notices on unknown targets carry no edit target', () async {
    final narrator = _Narrator();
    final bloc = FeedBloc.preview(
      playback: _playback,
      narrator: narrator,
      resolvePreview: (_) => (playback: null, exists: false),
      previewNodeLabel: (id) => id,
    );
    bloc.add(const PauseReached());
    await bloc.stream.firstWhere((state) => state.previewCueStarted);
    narrator.finish();
    await bloc.stream.firstWhere((state) => state.phase == FeedPhase.window);

    bloc.add(const HoldStarted('door'));
    await bloc.stream.firstWhere((state) => state.phase == FeedPhase.holding);
    bloc.add(const HoldCompleted());
    await bloc.stream.firstWhere((state) => state.previewNoticeSerial == 1);
    expect(bloc.state.previewNotice, 'Node "next" not finished yet');
    expect(bloc.state.previewNoticeTarget, isNull);
    await bloc.close();
  });

  testWidgets('preview holds walk finished scenes like the feed', (
    tester,
  ) async {
    final calls = <String>[];
    await _openEditor(
      tester,
      calls,
      moreNodes: [
        MapEntry('next', {
          'title': 'The descent',
          'isEnding': false,
          'videoUrl': 'https://example.com/next.mp4',
          'videoStatus': 'ready',
          'videoWidth': 720,
          'videoHeight': 1280,
          'durationSeconds': 8,
          'ttsText': 'Second line',
          'ttsDurationSeconds': 2,
          'choices': [
            {
              'choiceId': 'stairs',
              'targetNodeId': 'deep',
              'label': 'Descend',
              'isDefault': true,
              'x': 0.5,
              'y': 0.5,
              'radius': 0.15,
            },
          ],
        }),
        MapEntry('deep', {
          'title': 'The deep',
          'isEnding': false,
          'videoStatus': 'pending',
          'ttsText': 'Third line',
          'ttsDurationSeconds': 2,
          'choices': <Object>[],
        }),
      ],
    );
    await tester.tap(find.byKey(const ValueKey('preview-node-root')));
    await _settleMedia(tester);
    final preview = tester.element(find.byType(FeedView)).read<FeedBloc>();

    await tester.tap(find.byTooltip('Mute'));
    await tester.pump();
    media.events[1]!.add(VideoEvent(eventType: VideoEventType.completed));
    await _settleMedia(tester);
    expect(find.byType(ChoiceZone), findsOneWidget);

    // The finished target plays once the hold covers the screen,
    // framed with its own metadata.
    await _holdChoice(tester, 'ring-door');
    expect(preview.state.phase, FeedPhase.playing);
    expect(preview.state.playback?.node.nodeId, 'next');
    expect(
      tester.widget<FeedView>(find.byType(FeedView)).previewVideoSize,
      const Size(720, 1280),
    );
    expect(media.urls.values, contains('https://example.com/next.mp4'));

    // The next step behaves like the feed: clip, cue, then hotspots.
    final nextTexture = media.urls.keys.last;
    media.events[nextTexture]!.add(
      VideoEvent(eventType: VideoEventType.completed),
    );
    await _settleMedia(tester);
    expect(find.text('Second line'), findsOneWidget);
    expect(find.byType(ChoiceZone), findsOneWidget);
    expect(tester.widget<ChoiceZone>(find.byType(ChoiceZone)).label, 'Descend');

    // The unfinished target keeps the scene, falls back to the window,
    // and names itself. The messenger mirrors the snackbar on every root
    // Scaffold, so the covered editor holds a copy too: scope to the
    // preview route.
    await _holdChoice(tester, 'ring-stairs');
    expect(preview.state.phase, FeedPhase.window);
    expect(preview.state.playback?.node.nodeId, 'next');
    expect(
      find.descendant(
        of: find.byType(CreatePreview),
        matching: find.text('Node "2AA" not finished yet'),
      ),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('close-preview')));
    await tester.pumpAndSettle();
    expect(calls, isEmpty);
  });

  testWidgets('preview notice opens its scene; back returns to the hub', (
    tester,
  ) async {
    await _openEditor(
      tester,
      <String>[],
      moreNodes: [
        MapEntry('next', {
          'title': 'The descent',
          'isEnding': false,
          'videoStatus': 'idle',
          'ttsText': 'Second line',
          'ttsDurationSeconds': 2,
          'choices': <Object>[],
        }),
      ],
      withHub: true,
    );
    await tester.tap(find.byKey(const ValueKey('preview-node-root')));
    await _settleMedia(tester);
    final preview = tester.element(find.byType(FeedView)).read<FeedBloc>();

    await tester.tap(find.byTooltip('Mute'));
    await tester.pump();
    media.events[1]!.add(VideoEvent(eventType: VideoEventType.completed));
    await _settleMedia(tester);

    await _holdChoice(tester, 'ring-door');
    expect(preview.state.playback?.node.nodeId, 'root');
    expect(
      find.descendant(
        of: find.byType(CreatePreview),
        matching: find.text('Node "1A" not finished yet'),
      ),
      findsOneWidget,
    );

    // The notice chevron closes the preview and swaps the editor for
    // the unfinished node. The entrance animation must finish first
    // (500ms, well under the 4s auto-dismiss) so the tap lands on
    // screen.
    final chevron = find.descendant(
      of: find.byType(CreatePreview),
      matching: find.byKey(const ValueKey('notice-open-node')),
    );
    await tester.pump(const Duration(milliseconds: 500));
    expect(chevron, findsOneWidget);
    await tester.tap(chevron);
    await tester.pumpAndSettle();
    expect(find.byType(CreatePreview), findsNothing);
    final screens = find.byType(CreateNodeScreen, skipOffstage: false);
    expect(screens, findsOneWidget);
    expect(tester.widget<CreateNodeScreen>(screens).nodeId, 'next');
    expect(tester.widget<AppBar>(find.byType(AppBar)).centerTitle, isFalse);
    expect(find.text('The descent'), findsWidgets);

    // Back lands on the scene hub, not the previous editor.
    await tester.tap(find.byKey(const ValueKey('wizard-leave')));
    await tester.pumpAndSettle();
    expect(find.text('Scene hub'), findsOneWidget);
    expect(find.byType(CreateNodeScreen), findsNothing);
  });

  testWidgets('preview notices on unknown targets offer no edit action', (
    tester,
  ) async {
    await _openEditor(tester, <String>[]);
    await tester.tap(find.byKey(const ValueKey('preview-node-root')));
    await _settleMedia(tester);

    await tester.tap(find.byTooltip('Mute'));
    await tester.pump();
    media.events[1]!.add(VideoEvent(eventType: VideoEventType.completed));
    await _settleMedia(tester);

    await _holdChoice(tester, 'ring-door');
    expect(
      find.descendant(
        of: find.byType(CreatePreview),
        matching: find.text('Node "next" not finished yet'),
      ),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('notice-open-node')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('close-preview')));
    await tester.pumpAndSettle();
  });

  testWidgets('preview shows like, comment and save actions', (tester) async {
    await _openEditor(tester, <String>[]);
    await tester.tap(find.byKey(const ValueKey('preview-node-root')));
    await _settleMedia(tester);

    AnimatedOpacity rail() => tester.widget<AnimatedOpacity>(
      find.byKey(const ValueKey('action-rail')),
    );
    expect(rail().opacity, 1);
    expect(find.byKey(const ValueKey('rail-like')), findsOneWidget);
    expect(find.byKey(const ValueKey('rail-comment')), findsOneWidget);
    expect(find.byKey(const ValueKey('rail-save')), findsOneWidget);
    expect(find.text('Like'), findsOneWidget);
    expect(find.text('Comment'), findsOneWidget);
    expect(find.text('Save'), findsOneWidget);

    Finder iconIn(String key, IconData icon) => find.descendant(
      of: find.byKey(ValueKey(key)),
      matching: find.byIcon(icon),
    );

    await tester.tap(find.byKey(const ValueKey('rail-like')));
    await tester.pump();
    expect(iconIn('rail-like', Icons.favorite), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('rail-like')));
    await tester.pump();
    expect(iconIn('rail-like', Icons.favorite_border), findsOneWidget);

    expect(iconIn('rail-save', Icons.bookmark_border), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('rail-save')));
    await tester.pump();
    expect(iconIn('rail-save', Icons.bookmark), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('rail-comment')));
    await tester.pump();
    expect(
      find.descendant(
        of: find.byType(CreatePreview),
        matching: find.text('Comments are not available in preview.'),
      ),
      findsOneWidget,
    );

    // The rail fades out while the hotspots are up, and taps pass
    // through instead of toggling.
    await tester.tap(find.byTooltip('Mute'));
    await tester.pump();
    media.events[1]!.add(VideoEvent(eventType: VideoEventType.completed));
    await _settleMedia(tester);
    expect(find.byType(ChoiceZone), findsOneWidget);
    expect(rail().opacity, 0);
    await tester.tap(
      find.byKey(const ValueKey('rail-like')),
      warnIfMissed: false,
    );
    await tester.pump();
    expect(iconIn('rail-like', Icons.favorite_border), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('close-preview')));
    await tester.pumpAndSettle();
  });

  testWidgets('preview still opens if the author profile cannot be read', (
    tester,
  ) async {
    await _openEditor(
      tester,
      <String>[],
      auth: AuthRepository(auth: _Auth(), users: _Users(failRead: true)),
    );
    await tester.tap(find.byKey(const ValueKey('preview-node-root')));
    await _settleMedia(tester);
    expect(find.byType(CreatePreview), findsOneWidget);
    expect(tester.widget<StoryChip>(find.byType(StoryChip)).author, 'Identity');
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const ValueKey('close-preview')));
    await tester.pumpAndSettle();
  });
}

const _playback = Playback(
  runId: 'preview',
  status: .active,
  story: PlaybackStory(storyId: 'story', title: 'Temple', authorName: 'A'),
  node: PlaybackNode(
    nodeId: 'root',
    title: 'Gate',
    isEnding: false,
    videoUrl: 'https://example.com/scene.mp4',
    durationSeconds: 10,
    videoFrameLastBlurData: '',
    ttsText: 'Choose a path',
    ttsAudioUrl: 'https://example.com/voice.m4a',
    ttsDurationSeconds: 2,
  ),
  choices: [
    PlaybackChoice(
      choiceId: 'door',
      label: 'Open',
      targetNodeId: 'next',
      isDefault: true,
      x: 0.25,
      y: 0.65,
      radius: 0.12,
      targetSecret: true,
      target: null,
    ),
  ],
);

const _nextPlayback = Playback(
  runId: 'preview',
  status: .active,
  story: PlaybackStory(storyId: 'story', title: 'Temple', authorName: 'A'),
  node: PlaybackNode(
    nodeId: 'next',
    title: 'Descent',
    isEnding: false,
    videoUrl: 'https://example.com/next.mp4',
    durationSeconds: 8,
    videoFrameLastBlurData: '',
    ttsText: 'Second line',
    ttsDurationSeconds: 2,
  ),
  choices: [
    PlaybackChoice(
      choiceId: 'stairs',
      label: 'Descend',
      targetNodeId: 'deep',
      isDefault: true,
      x: 0.5,
      y: 0.5,
      radius: 0.15,
      targetSecret: true,
      target: null,
    ),
  ],
);

Future<CreateBloc> _openEditor(
  WidgetTester tester,
  List<String> calls, {
  bool ending = false,
  AuthRepository? auth,
  List<MapEntry<String, Map<String, dynamic>>>? moreNodes,
  bool withHub = false,
}) async {
  await tester.binding.setSurfaceSize(const Size(390, 844));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final bloc = CreateBloc(
    auth: auth,
    repository: testCreateRepository(
      createDraftDoc: ({required authorId, required title}) async => 'story',
      fetchStoryDoc: (_) async => {
        'authorId': 'author',
        'title': 'Temple',
        'rootNodeId': 'root',
      },
      fetchNodeDocs: (_) async => [
        MapEntry<String, Map<String, dynamic>>('root', {
          'title': 'The gate',
          'isEnding': ending,
          'endingName': ending ? 'A new dawn' : null,
          'endingType': ending ? 'open' : null,
          'videoUrl': 'https://example.com/scene.mp4',
          'videoStatus': 'ready',
          'videoWidth': 480,
          'videoHeight': 854,
          'durationSeconds': 10,
          'ttsText': ending ? 'The story ends' : 'Choose a path',
          'ttsDurationSeconds': 2,
          'choices': ending
              ? <Object>[]
              : [
                  {
                    'choiceId': 'door',
                    'targetNodeId': 'next',
                    'label': 'Enter',
                    'isDefault': true,
                    'icon': 'door',
                    'iconColor': 'amber',
                    'x': 0.25,
                    'y': 0.65,
                    'radius': 0.12,
                  },
                ],
        }),
        ...?moreNodes,
      ],
      callFunction: (name, _) async {
        calls.add(name);
        return {};
      },
    ),
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    var closed = false;
    final closing = bloc.close().then((_) => closed = true);
    for (var i = 0; i < 30 && !closed; i++) {
      await tester.pump();
      await tester.runAsync(() async {});
    }
    expect(closed, isTrue);
    await closing;
  });
  bloc.add(const DraftOpened('story'));
  await bloc.stream.firstWhere((state) => state.hasDraft);
  Widget editor() => CreateNodeScreen(
    bloc: bloc,
    nodeId: 'root',
    pickVideo: null,
    newTakeId: () => 'take',
  );
  await tester.pumpWidget(
    MaterialApp(
      // A hub route below the editor, like the canvas in production,
      // so back-navigation tests have somewhere to land.
      home: withHub
          ? Builder(
              builder: (context) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  Navigator.of(context)
                      .push(MaterialPageRoute(builder: (_) => editor()));
                });
                return const Scaffold(body: Center(child: Text('Scene hub')));
              },
            )
          : editor(),
    ),
  );
  await tester.pump();
  if (withHub) await tester.pumpAndSettle();
  return bloc;
}

Future<void> _settleMedia(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
  for (var i = 0; i < 4; i++) {
    await tester.pump();
  }
}

/// Holds a preview hotspot for the full 1.5 seconds, like the feed: the
/// circle covers the screen and only then does the scene change. A plain
/// tap presses and releases, which cancels the hold and stays put.
Future<void> _holdChoice(WidgetTester tester, String ringKey) async {
  final gesture = await tester.startGesture(
    tester.getCenter(find.byKey(ValueKey(ringKey))),
  );
  await tester.pump();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 1500));
  await tester.pump();
  await gesture.up();
  await tester.pump();
}

class _Narrator implements Narrator {
  _Narrator({this.startGate});

  final Completer<void>? startGate;
  String? prepared;
  bool played = false;
  bool disposed = false;
  VoidCallback? _onEnded;

  @override
  Future<void> prepare(String url) async => prepared = url;

  @override
  void unlock() {}

  @override
  Future<bool> play({required VoidCallback onEnded}) async {
    _onEnded = onEnded;
    await startGate?.future;
    played = true;
    return true;
  }

  void finish() => _onEnded!();

  @override
  void stop() => _onEnded = null;

  @override
  void dispose() => disposed = true;
}

class _PreviewMediaPlatform extends FakeMediaPlatform {
  Size size = const Size(480, 854);

  @override
  VideoEvent initialized() => VideoEvent(
    eventType: VideoEventType.initialized,
    duration: const Duration(seconds: 10),
    size: size,
  );
}

class _Auth implements AuthGateway {
  @override
  AuthIdentity get currentIdentity =>
      const AuthIdentity(uid: 'author', displayName: 'Identity');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Users implements UserDirectory {
  _Users({this.failRead = false});

  final bool failRead;
  final account = Completer<UserAccount?>();
  String? requestedUid;

  @override
  Future<UserAccount?> read(String uid) {
    requestedUid = uid;
    if (failRead) return Future.error(StateError('Profile unavailable'));
    return account.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
