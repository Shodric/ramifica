import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ramifica/app/app.dart';
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
}
