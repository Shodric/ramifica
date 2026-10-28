import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ramifica/app/app.dart';
import 'package:ramifica/core/cue_clock.dart';
import 'package:ramifica/core/prefetcher.dart';
import 'package:ramifica/core/warm_slot.dart';
import 'package:ramifica/core/functions_client.dart';
import 'package:ramifica/data/models/app_failure.dart';
import 'package:ramifica/data/models/playback.dart';
import 'package:ramifica/data/models/user.dart';
import 'package:ramifica/data/repositories/auth_repository.dart';
import 'package:ramifica/data/repositories/run_repository.dart';
import 'package:ramifica/features/feed/feed_bloc.dart';
import 'package:ramifica/features/feed/feed_event.dart';
import 'package:ramifica/features/feed/feed_state.dart';
import 'package:ramifica/features/feed/feed_view.dart';
import 'package:ramifica/features/feed/node_video.dart';
import 'package:ramifica/features/feed/story_chip.dart';

void main() {
  test('an active run loads then plays', () async {
    final calls = <_Call>[];
    final bloc = FeedBloc(repository: _runs(calls, _active));
    addTearDown(bloc.close);
    final phases = <FeedPhase>[];
    final sub = bloc.stream.listen((state) => phases.add(state.phase));
    addTearDown(sub.cancel);

    bloc.add(const StoryOpened(storyId: ' story_temple '));
    await bloc.stream.firstWhere((state) => state.phase == FeedPhase.playing);
    await Future<void>.delayed(Duration.zero);

    expect(phases, [FeedPhase.loading, FeedPhase.playing]);
    expect(calls[0].name, 'startRun');
    expect(calls[0].data, {'storyId': 'story_temple'});
    expect(calls[1].name, 'loadPlayback');
    expect(calls[1].data, {'runId': 'run_1'});
    expect(bloc.state.runId, 'run_1');
    expect(bloc.state.failure, isNull);
    final secret = bloc.state.playback!.choices.last;
    expect(secret.targetSecret, isTrue);
    expect(secret.target, isNull);
    expect(
      bloc.state.playback!.choices.first.target!.videoUrl,
      'https://example.com/next.mp4',
    );
  });

  test('an ended run enters ending', () async {
    final bloc = FeedBloc(repository: _runs([], _ended));
    addTearDown(bloc.close);

    bloc.add(const StoryOpened(storyId: 'story_temple'));
    await bloc.stream.firstWhere((state) => state.phase == FeedPhase.ending);

    expect(bloc.state.phase, FeedPhase.ending);
    expect(bloc.state.playback!.node.isEnding, isTrue);
    expect(bloc.state.playback!.node.endingName, 'The door');
  });

  test('a failure while opening stays failed', () async {
    var loads = 0;
    final bloc = FeedBloc(
      repository: RunRepository(
        functions: FunctionsClient(
          call: (name, data) async {
            if (name == 'loadPlayback') loads += 1;
            throw const AppFailure(.offline);
          },
        ),
      ),
    );
    addTearDown(bloc.close);

    bloc.add(const StoryOpened(storyId: 'story_temple'));
    await bloc.stream.firstWhere((state) => state.phase == FeedPhase.failed);

    expect(bloc.state.failure, 'No connection');
    expect(bloc.state.playback, isNull);
    expect(loads, 0);
  });

  test('a malformed playback is invalid', () async {
    final bloc = FeedBloc(
      repository: RunRepository(
        functions: FunctionsClient(
          call: (name, data) async {
            if (name == 'startRun') {
              return {
                'runId': 'run_1',
                'storyId': 'story_temple',
                'status': 'active',
              };
            }
            return {'runId': 'run_1'};
          },
        ),
      ),
    );
    addTearDown(bloc.close);

    bloc.add(const StoryOpened(storyId: 'story_temple'));
    await bloc.stream.firstWhere((state) => state.phase == FeedPhase.failed);

    expect(bloc.state.failure, 'That action is not valid');
  });

  test('an empty story id lets the server choose', () async {
    final calls = <_Call>[];
    final bloc = FeedBloc(repository: _runs(calls, _active));
    addTearDown(bloc.close);

    bloc.add(const StoryOpened(storyId: '   '));
    await bloc.stream.firstWhere((state) => state.phase == FeedPhase.playing);

    expect(calls.first.data, <String, dynamic>{});
    expect(bloc.state.storyId, 'story_featured');
  });

  test('a second StoryOpened drops the first run', () async {
    final first = Completer<void>();
    final calls = <_Call>[];
    final bloc = FeedBloc(
      repository: _runs(calls, (name, data) async {
        if (name == 'startRun' && data?['storyId'] == 'story_old') {
          await first.future;
          return {
            'runId': 'run_old',
            'storyId': 'story_old',
            'status': 'active',
          };
        }
        return _active(name, data);
      }),
    );
    addTearDown(bloc.close);

    bloc.add(const StoryOpened(storyId: 'story_old'));
    await bloc.stream.first;
    bloc.add(const StoryOpened(storyId: 'story_new'));
    await bloc.stream.first;
    first.complete();
    await bloc.stream.firstWhere((state) => state.phase == FeedPhase.playing);

    expect(bloc.state.runId, 'run_new');
    expect(bloc.state.storyId, 'story_new');
    expect(calls.where((call) => call.data?['runId'] == 'run_old'), isEmpty);
  });

  test('PauseReached moves a playing clip to speaking', () async {
    final bloc = FeedBloc(repository: _runs([], _active));
    addTearDown(bloc.close);

    bloc.add(const StoryOpened(storyId: 'story_temple'));
    await bloc.stream.firstWhere((state) => state.phase == FeedPhase.playing);
    bloc.add(const PauseReached());
    await bloc.stream.firstWhere((state) => state.phase == FeedPhase.speaking);

    expect(bloc.state.playback, isNotNull);
    expect(bloc.state.muted, isTrue);
    bloc.add(const PauseReached());
    await Future<void>.delayed(Duration.zero);
    expect(bloc.state.phase, FeedPhase.speaking);
  });

  test('PauseReached does nothing before the clip is playing', () async {
    final bloc = FeedBloc(repository: _runs([], _active));
    addTearDown(bloc.close);

    bloc.add(const PauseReached());
    await Future<void>.delayed(Duration.zero);

    expect(bloc.state.phase, FeedPhase.loading);
  });

  test('a playing run warms the open destination', () async {
    final mounted = <String>[];
    final bloc = FeedBloc(
      repository: _runs([], _active),
      prefetcher: _warm(mounted, []),
    );
    addTearDown(bloc.close);

    bloc.add(const StoryOpened(storyId: 'story_temple'));
    await bloc.stream.firstWhere((state) => state.phase == FeedPhase.playing);

    expect(bloc.prefetcher.urls, [
      'https://example.com/video.mp4',
      'https://example.com/next.mp4',
    ]);
    expect(mounted, bloc.prefetcher.urls);
  });

  test('a failed open warms nothing', () async {
    final mounted = <String>[];
    final bloc = FeedBloc(
      repository: RunRepository(
        functions: FunctionsClient(
          call: (name, data) async => throw const AppFailure(.offline),
        ),
      ),
      prefetcher: _warm(mounted, []),
    );
    addTearDown(bloc.close);

    bloc.add(const StoryOpened(storyId: 'story_temple'));
    await bloc.stream.firstWhere((state) => state.phase == FeedPhase.failed);

    expect(mounted, isEmpty);
  });

  test('a second story replaces the warmed clips', () async {
    final disposed = <String>[];
    final bloc = FeedBloc(
      repository: _runs([], _active),
      prefetcher: _warm([], disposed),
    );
    addTearDown(bloc.close);

    bloc.add(const StoryOpened(storyId: 'story_temple'));
    await bloc.stream.firstWhere((state) => state.phase == FeedPhase.playing);
    bloc.add(const StoryOpened(storyId: 'story_new'));
    await bloc.stream.firstWhere(
      (state) =>
          state.phase == FeedPhase.playing && state.storyId == 'story_new',
    );

    expect(bloc.prefetcher.storyId, 'story_new');
    expect(disposed, [
      'https://example.com/video.mp4',
      'https://example.com/next.mp4',
    ]);
    expect(bloc.prefetcher.urls, [
      'https://example.com/video.mp4',
      'https://example.com/next.mp4',
    ]);
  });

  test('MuteToggled flips sound and clears the browser mute', () async {
    final bloc = FeedBloc(repository: _runs([], _active));
    addTearDown(bloc.close);

    bloc.add(const MuteToggled());
    await bloc.stream.first;
    expect(bloc.state.muted, isFalse);
    expect(bloc.state.autoMuted, isFalse);

    bloc.add(const MuteToggled());
    await bloc.stream.first;
    expect(bloc.state.muted, isTrue);
    expect(bloc.state.autoMuted, isFalse);
  });

  test('a secret choice cannot carry a target', () {
    final json = _playback();
    final choices = json['choices']! as List<Object?>;
    final secret = Map<String, Object?>.from(choices[1]! as Map);
    secret['target'] = {
      'nodeId': 'node_003',
      'videoUrl': 'https://example.com/secret.mp4',
    };
    choices[1] = secret;

    expect(
      () => Playback.fromJson(json),
      throwsA(
        isA<AppFailure>().having(
          (error) => error.code,
          'code',
          AppFailureCode.invalid,
        ),
      ),
    );
  });

  testWidgets('an unsigned feed does not start a run', (tester) async {
    for (final route in ['/', '/story/story_temple']) {
      final calls = <_Call>[];
      await tester.pumpWidget(
        RamificaApp(initialRoute: route, runRepository: _runs(calls, _active)),
      );
      await tester.pump();

      expect(find.text('Continue with Google'), findsOneWidget);
      expect(find.text('Feed'), findsNothing);
      expect(calls, isEmpty);
    }
  });

  testWidgets('Explore does not start a run', (tester) async {
    final calls = <_Call>[];
    await tester.pumpWidget(
      RamificaApp(
        initialRoute: '/explore',
        runRepository: _runs(calls, _active),
      ),
    );
    await tester.pump();

    expect(calls, isEmpty);
  });

  testWidgets('a signed-in story starts one run', (tester) async {
    final auth = _Auth();
    addTearDown(auth.sessions.close);
    final calls = <_Call>[];
    await tester.pumpWidget(
      RamificaApp(
        initialRoute: '/story/story_temple',
        authRepository: AuthRepository(auth: auth, users: _Users()),
        runRepository: _runs(calls, _active),
      ),
    );
    await tester.pump();
    expect(calls, isEmpty);

    auth.identity = const AuthIdentity(uid: 'uid_1', providers: ['google.com']);
    auth.sessions.add(auth.identity);
    await tester.pumpAndSettle();

    expect(calls.map((call) => call.name), ['startRun', 'loadPlayback']);
    expect(
      tester.element(find.byType(FeedView)).read<FeedBloc>().state.phase,
      FeedPhase.playing,
    );
    expect(find.text('Feed'), findsWidgets);

    await tester.tap(find.widgetWithText(NavigationDestination, 'Profile'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(NavigationDestination, 'Feed'));
    await tester.pumpAndSettle();

    expect(calls, hasLength(2));
  });

  testWidgets('playing shows the chip and the sound control', (tester) async {
    final player = _FakeClip();
    addTearDown(player.dispose);
    final bloc = await _pumpFeed(tester, player: player, respond: _active);

    expect(find.text('The temple secret'), findsOneWidget);
    expect(find.text('by Alex Vance'), findsOneWidget);
    expect(find.text('Sound'), findsOneWidget);
    expect(find.byTooltip('Turn sound on'), findsOneWidget);
    expect(player.opens.single.play, isTrue);
    expect(player.opens.single.muted, isTrue);
    expect(_chipGate(tester).ignoring, isFalse);

    await tester.tap(find.byTooltip('Turn sound on'));
    await tester.pump();
    expect(bloc.state.muted, isFalse);
    expect(bloc.state.autoMuted, isFalse);
    expect(find.text('Sound'), findsNothing);
    expect(find.byTooltip('Mute'), findsOneWidget);

    await tester.tap(find.byTooltip('Mute'));
    await tester.pump();
    expect(bloc.state.muted, isTrue);
    expect(bloc.state.autoMuted, isFalse);
    expect(find.byTooltip('Unmute'), findsOneWidget);
    expect(player.opens, hasLength(1));
  });

  testWidgets('the ended clip fades the chip and keeps the frame', (
    tester,
  ) async {
    final player = _FakeClip();
    addTearDown(player.dispose);
    final bloc = await _pumpFeed(tester, player: player, respond: _active);
    expect(_chipOpacity(tester).opacity, 1);

    player.ended = true;
    player.notify();
    await bloc.stream.firstWhere((state) => state.phase == FeedPhase.speaking);
    await tester.pump();

    expect(player.opens, hasLength(1));
    expect(_chipGate(tester).ignoring, isTrue);
    await tester.pump(const Duration(milliseconds: 200));
    expect(_chipOpacity(tester).opacity, 0);
  });

  testWidgets('an ended run stays parked on the last frame', (tester) async {
    final player = _FakeClip();
    addTearDown(player.dispose);
    final bloc = await _pumpFeed(tester, player: player, respond: _ended);

    expect(bloc.state.phase, FeedPhase.ending);
    expect(player.opens.single.play, isFalse);
    expect(player.resumes, 0);
    expect(_chipOpacity(tester).opacity, 0);

    player.ended = true;
    player.notify();
    await tester.pump();
    expect(bloc.state.phase, FeedPhase.ending);
  });

  testWidgets('the first frame and the ended event fire once', (tester) async {
    final player = _FakeClip();
    addTearDown(player.dispose);
    var frames = 0;
    var ends = 0;

    Future<void> host({required String url, required bool play}) {
      return tester.pumpWidget(
        MaterialApp(
          home: NodeVideo(
            url: url,
            muted: true,
            play: play,
            player: player,
            onFirstFrame: () => frames++,
            onEnded: () => ends++,
          ),
        ),
      );
    }

    await host(url: 'https://example.com/a.mp4', play: true);
    await tester.pump();
    expect(frames, 1);
    expect(player.resumes, 1);
    player.notify();
    expect(frames, 1);

    player.ended = true;
    player.notify();
    expect(ends, 1);
    player.notify();
    expect(ends, 1);

    await host(url: 'https://example.com/b.mp4', play: true);
    await tester.pump();
    expect(frames, 2);
    expect(player.opens.map((open) => open.url.path), ['/a.mp4', '/b.mp4']);
  });

  testWidgets('a parked clip does not emit PauseReached', (tester) async {
    final player = _FakeClip();
    addTearDown(player.dispose);
    var ends = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: NodeVideo(
          url: 'https://example.com/video.mp4',
          muted: true,
          play: false,
          player: player,
          onFirstFrame: () {},
          onEnded: () => ends++,
        ),
      ),
    );
    await tester.pump();

    expect(player.opens.single.play, isFalse);
    expect(player.resumes, 0);
    player.ended = true;
    player.notify();
    expect(ends, 0);
  });

  testWidgets('leaving the feed pauses and coming back resumes', (
    tester,
  ) async {
    final player = _FakeClip();
    addTearDown(player.dispose);

    Future<void> host(bool enabled) {
      return tester.pumpWidget(
        MaterialApp(
          home: TickerMode(
            enabled: enabled,
            child: NodeVideo(
              url: 'https://example.com/video.mp4',
              muted: true,
              play: true,
              player: player,
              onFirstFrame: () {},
              onEnded: () {},
            ),
          ),
        ),
      );
    }

    await host(false);
    await tester.pump();
    expect(player.pauses, greaterThan(0));
    expect(player.resumes, 0);

    await host(true);
    await tester.pump();
    expect(player.resumes, 1);
  });

  testWidgets('speaking keeps the same run across tabs', (tester) async {
    final auth = _Auth();
    addTearDown(auth.sessions.close);
    final calls = <_Call>[];
    await tester.pumpWidget(
      RamificaApp(
        initialRoute: '/story/story_temple',
        authRepository: AuthRepository(auth: auth, users: _Users()),
        runRepository: _runs(calls, _active),
      ),
    );
    auth.identity = const AuthIdentity(uid: 'uid_1', providers: ['google.com']);
    auth.sessions.add(auth.identity);
    await tester.pumpAndSettle();

    final bloc = tester.element(find.byType(FeedView)).read<FeedBloc>();
    bloc.add(const PauseReached());
    await tester.pumpAndSettle();
    expect(bloc.state.phase, FeedPhase.speaking);
    expect(find.text('The temple secret'), findsOneWidget);

    await tester.tap(find.widgetWithText(NavigationDestination, 'Profile'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(NavigationDestination, 'Feed'));
    await tester.pumpAndSettle();

    expect(calls, hasLength(2));
    expect(bloc.state.phase, FeedPhase.speaking);
  });

  testWidgets('signing out drops the warmed clips', (tester) async {
    final auth = _Auth();
    addTearDown(auth.sessions.close);
    final prefetcher = _warm([], []);
    await tester.pumpWidget(
      RamificaApp(
        initialRoute: '/story/story_temple',
        authRepository: AuthRepository(auth: auth, users: _Users()),
        runRepository: _runs([], _active),
        prefetcher: prefetcher,
      ),
    );
    auth.identity = const AuthIdentity(uid: 'uid_1', providers: ['google.com']);
    auth.sessions.add(auth.identity);
    await tester.pumpAndSettle();
    expect(prefetcher.urls, isNotEmpty);

    auth.identity = null;
    auth.sessions.add(null);
    await tester.pumpAndSettle();

    expect(prefetcher.urls, isEmpty);
    expect(prefetcher.storyId, isNull);
  });
}

class _Call {
  const _Call(this.name, this.data);

  final String name;
  final Map<String, dynamic>? data;
}

RunRepository _runs(
  List<_Call> calls,
  Future<dynamic> Function(String name, Map<String, dynamic>? data) respond,
) {
  return RunRepository(
    functions: FunctionsClient(
      call: (name, data) async {
        calls.add(_Call(name, data));
        return respond(name, data);
      },
    ),
  );
}

Future<dynamic> _active(String name, Map<String, dynamic>? data) async {
  if (name == 'startRun') {
    final storyId = data?['storyId'] as String? ?? 'story_featured';
    return {'runId': _runFor(storyId), 'storyId': storyId, 'status': 'active'};
  }
  final runId = data?['runId'] as String? ?? 'run_1';
  return _playback(runId: runId, storyId: _storyFor(runId));
}

String _runFor(String storyId) {
  return switch (storyId) {
    'story_new' => 'run_new',
    'story_featured' => 'run_featured',
    _ => 'run_1',
  };
}

String _storyFor(String runId) {
  return switch (runId) {
    'run_new' => 'story_new',
    'run_featured' => 'story_featured',
    _ => 'story_temple',
  };
}

Future<dynamic> _ended(String name, Map<String, dynamic>? data) async {
  if (name == 'startRun') {
    return {'runId': 'run_end', 'storyId': 'story_temple', 'status': 'ended'};
  }
  return _playback(runId: 'run_end', status: 'ended', ending: true);
}

Map<String, dynamic> _playback({
  String runId = 'run_1',
  String storyId = 'story_temple',
  String status = 'active',
  bool ending = false,
}) {
  return {
    'runId': runId,
    'status': status,
    'story': {
      'storyId': storyId,
      'title': 'The temple secret',
      'authorName': 'Alex Vance',
    },
    'node': {
      'nodeId': ending ? 'node_end' : 'node_001',
      'title': ending ? 'The last door' : 'The temple door',
      'isEnding': ending,
      'videoUrl': 'https://example.com/video.mp4',
      'durationSeconds': 10,
      'pauseAtSeconds': 9.967,
      'windowSeconds': 6,
      'ttsText': ending ? null : 'Enter or climb?',
      'ttsAudioUrl': ending ? null : 'https://example.com/voice.m4a',
      'ttsDurationSeconds': ending ? null : 4.1,
      'videoFrameLastBlurData': 'data:image/webp;base64,abc',
      'endingName': ending ? 'The door' : null,
      'endingType': ending ? 'tragic' : null,
    },
    'choices': ending
        ? <Object?>[]
        : [
            {
              'choiceId': 'choice_temple',
              'label': 'Enter the temple',
              'targetNodeId': 'node_002',
              'isDefault': true,
              'x': 0.25,
              'y': 0.65,
              'radius': 0.15,
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
              'x': 0.75,
              'y': 0.7,
              'radius': 0.15,
              'targetSecret': true,
              'target': null,
            },
          ],
  };
}

class _Auth implements AuthGateway {
  final sessions = StreamController<AuthIdentity?>();
  AuthIdentity? identity;

  @override
  Stream<AuthIdentity?> authStateChanges() => sessions.stream;

  @override
  AuthIdentity? get currentIdentity => identity;

  @override
  Future<void> signInWithGooglePopup() async {}

  @override
  Future<void> signInWithGoogleRedirect() async {}

  @override
  Future<void> completeGoogleRedirect() async {}

  @override
  Future<void> signInWithEmail({
    required String email,
    required String password,
  }) async {}

  @override
  Future<void> signUpWithEmail({
    required String email,
    required String password,
  }) async {}

  @override
  Future<void> sendPasswordReset(String email) async {}

  @override
  Future<void> signOut() async {}
}

class _Users implements UserDirectory {
  @override
  Future<void> create(UserAccount user) async {}

  @override
  Future<bool> exists(String uid) async => true;

  @override
  Future<UserAccount?> read(String uid) async => null;

  @override
  Future<void> updateProfile({
    required String uid,
    String? displayName,
    String? handle,
    String? photoUrl,
    required String locale,
  }) async {}
}

Future<FeedBloc> _pumpFeed(
  WidgetTester tester, {
  required _FakeClip player,
  required Future<dynamic> Function(String name, Map<String, dynamic>? data)
  respond,
}) async {
  final bloc = FeedBloc(repository: _runs([], respond), clock: _StillClock());
  addTearDown(bloc.close);
  await tester.pumpWidget(
    MaterialApp(
      home: BlocProvider.value(
        value: bloc,
        child: FeedView(clipPlayer: player),
      ),
    ),
  );
  bloc.add(const StoryOpened(storyId: 'story_temple'));
  await tester.pumpAndSettle();
  return bloc;
}

AnimatedOpacity _chipOpacity(WidgetTester tester) {
  return tester.widget<AnimatedOpacity>(
    find.ancestor(
      of: find.byType(StoryChip),
      matching: find.byType(AnimatedOpacity),
    ),
  );
}

IgnorePointer _chipGate(WidgetTester tester) {
  final element = tester.element(find.byType(StoryChip));
  IgnorePointer? gate;
  element.visitAncestorElements((ancestor) {
    if (ancestor.widget case final IgnorePointer pointer) {
      gate = pointer;
      return false;
    }
    return true;
  });
  return gate!;
}

class _StillClock implements CueClock {
  @override
  void schedule(Duration duration, void Function() fire) {}

  @override
  void cancel() {}
}

class _Open {
  const _Open({required this.url, required this.muted, required this.play});

  final Uri url;
  final bool muted;
  final bool play;
}

Prefetcher _warm(List<String> mounted, List<String> disposed) {
  return Prefetcher(open: () => _WarmSlot(mounted, disposed));
}

class _WarmSlot implements WarmSlot {
  _WarmSlot(this.mounted, this.disposed);

  final List<String> mounted;
  final List<String> disposed;
  String? _url;

  @override
  void mount(String url) {
    _url = url;
    mounted.add(url);
  }

  @override
  void dispose() {
    final url = _url;
    if (url == null) return;
    disposed.add(url);
    _url = null;
  }
}

class _FakeClip implements ClipPlayer {
  final opens = <_Open>[];
  var pauses = 0;
  var resumes = 0;

  @override
  bool ready = false;

  @override
  bool ended = false;
  var _disposed = false;
  final _listeners = <VoidCallback>[];

  void notify() {
    for (final listener in List<VoidCallback>.of(_listeners)) {
      listener();
    }
  }

  @override
  Future<void> open({
    required Uri url,
    required bool muted,
    required bool play,
  }) async {
    opens.add(_Open(url: url, muted: muted, play: play));
    ready = true;
    ended = false;
    await Future<void>.value();
    if (!_disposed) notify();
  }

  @override
  Future<void> setMuted(bool muted) async {}

  @override
  void pause() => pauses += 1;

  @override
  void resume() => resumes += 1;

  @override
  void addListener(VoidCallback listener) => _listeners.add(listener);

  @override
  void removeListener(VoidCallback listener) => _listeners.remove(listener);

  @override
  Widget buildView() => const SizedBox.expand();

  @override
  void dispose() => _disposed = true;
}
