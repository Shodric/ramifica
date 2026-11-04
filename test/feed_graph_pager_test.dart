import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ramifica/app/feed_graph_pager.dart';
import 'package:ramifica/app/shell_bloc.dart';
import 'package:ramifica/app/shell_event.dart';
import 'package:ramifica/app/shell_state.dart';
import 'package:ramifica/core/cue_clock.dart';
import 'package:ramifica/core/functions_client.dart';
import 'package:ramifica/core/prefetcher.dart';
import 'package:ramifica/core/warm_slot.dart';
import 'package:ramifica/data/repositories/graph_repository.dart';
import 'package:ramifica/data/repositories/run_repository.dart';
import 'package:ramifica/features/create/draft_canvas.dart';
import 'package:ramifica/features/feed/feed_bloc.dart';
import 'package:ramifica/features/feed/feed_event.dart';
import 'package:ramifica/features/feed/feed_state.dart';
import 'package:ramifica/features/feed/feed_view.dart';
import 'package:ramifica/features/feed/node_video.dart';

const _png =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8'
    'z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

void main() {
  testWidgets('a leftward drag past halfway opens the tree', (tester) async {
    final shell = ShellBloc();
    addTearDown(shell.close);
    await _pumpPager(tester, shell: shell);

    await tester.fling(
      find.byType(FeedView),
      const Offset(-300, 0),
      1000,
    );
    await tester.pumpAndSettle();

    expect(shell.state.tab, ShellTab.graph);
    expect(shell.state.storyId, 'story_temple');
    expect(find.byType(DraftCanvas), findsOneWidget);
    expect(find.text('The temple door'), findsNWidgets(2));
    expect(find.text('You are here'), findsOneWidget);
    expect(find.byType(Image), findsNWidgets(2));
    expect(_page(tester), 1);
  });

  testWidgets('a short drag snaps back to the feed', (tester) async {
    final shell = ShellBloc();
    addTearDown(shell.close);
    await _pumpPager(tester, shell: shell);

    await tester.drag(find.byType(FeedView), const Offset(-100, 0));
    await tester.pumpAndSettle();

    expect(shell.state.tab, ShellTab.feed);
    expect(find.byType(DraftCanvas), findsNothing);
    expect(_page(tester), 0);
  });

  testWidgets('swipes on the tree never page', (tester) async {
    final shell = ShellBloc();
    addTearDown(shell.close);
    await _pumpPager(tester, shell: shell);
    await tester.fling(
      find.byType(FeedView),
      const Offset(-300, 0),
      1000,
    );
    await tester.pumpAndSettle();
    expect(shell.state.tab, ShellTab.graph);

    await tester.fling(
      find.byType(DraftCanvas),
      const Offset(-300, 0),
      1000,
    );
    await tester.pumpAndSettle();
    expect(shell.state.tab, ShellTab.graph);
    expect(_page(tester), 1);

    await tester.fling(
      find.byType(DraftCanvas),
      const Offset(300, 0),
      1000,
    );
    await tester.pumpAndSettle();
    expect(shell.state.tab, ShellTab.graph);
    expect(_page(tester), 1);
  });

  testWidgets('an external tab selection jumps without animating', (
    tester,
  ) async {
    final shell = ShellBloc();
    addTearDown(shell.close);
    await _pumpPager(tester, shell: shell);

    shell.add(const TabSelected(.graph, storyId: 'story_temple'));
    await tester.pump();
    await tester.pump();

    // Two frames only: an animation would still be mid-flight with a
    // fractional page. A jump lands exactly.
    expect(shell.state.tab, ShellTab.graph);
    expect(_page(tester), 1);
    await tester.pumpAndSettle();
    expect(find.byType(DraftCanvas), findsOneWidget);
    expect(find.text('You are here'), findsOneWidget);
  });

  testWidgets('dragging mid-hold cancels the hold and stays on the feed', (
    tester,
  ) async {
    final shell = ShellBloc();
    addTearDown(shell.close);
    final feed = await _pumpPager(tester, shell: shell);
    await _window(tester, feed);

    final gesture = await tester.startGesture(_ring(tester, 'choice_ridge'));
    await tester.pump();
    await tester.pump();
    expect(feed.state.phase, FeedPhase.holding);

    await gesture.moveBy(const Offset(-100, 0));
    await tester.pump();
    expect(feed.state.phase, FeedPhase.window);
    expect(feed.state.holdChoiceId, isNull);

    await gesture.up();
    await tester.pumpAndSettle();
    expect(feed.state.phase, FeedPhase.window);
    expect(shell.state.tab, ShellTab.feed);
    expect(_page(tester), 0);
  });

  testWidgets('a pinch on the tree zooms instead of paging', (tester) async {
    final shell = ShellBloc();
    addTearDown(shell.close);
    await _pumpPager(tester, shell: shell);
    await tester.fling(
      find.byType(FeedView),
      const Offset(-300, 0),
      1000,
    );
    await tester.pumpAndSettle();
    expect(shell.state.tab, ShellTab.graph);

    final center = tester.getCenter(find.byType(DraftCanvas));
    final first = await tester.startGesture(center + const Offset(-50, 0));
    final second = await tester.startGesture(center + const Offset(50, 0));
    await first.moveBy(const Offset(-100, 0));
    await second.moveBy(const Offset(100, 0));
    await tester.pump();

    expect(shell.state.tab, ShellTab.graph);
    expect(_page(tester), 1);

    await first.up();
    await second.up();
    await tester.pumpAndSettle();
    expect(shell.state.tab, ShellTab.graph);
    expect(_page(tester), 1);
  });

  testWidgets('opening on the graph tab starts paged to the tree', (
    tester,
  ) async {
    final shell = ShellBloc(
      initial: const ShellState(tab: .graph, storyId: 'story_temple'),
    );
    addTearDown(shell.close);
    await _pumpPager(tester, shell: shell);

    expect(shell.state.tab, ShellTab.graph);
    expect(find.byType(DraftCanvas), findsOneWidget);
    expect(find.text('You are here'), findsOneWidget);
    expect(_page(tester), 1);
  });
}

double? _page(WidgetTester tester) {
  return tester.widget<PageView>(find.byType(PageView)).controller!.page;
}

Future<FeedBloc> _pumpPager(
  WidgetTester tester, {
  required ShellBloc shell,
}) async {
  final bloc = FeedBloc(
    repository: _runs(),
    prefetcher: Prefetcher(open: _Slot.new),
    clock: _Clock(),
  );
  addTearDown(() => _closeBloc(tester, bloc));
  final graphCalls = <_Call>[];
  await tester.pumpWidget(
    MaterialApp(
      home: MultiBlocProvider(
        providers: [
          BlocProvider<ShellBloc>.value(value: shell),
          BlocProvider<FeedBloc>.value(value: bloc),
        ],
        child: FeedGraphPager(
          storyId: 'story_temple',
          graphRepository: _graphs(
            graphCalls,
            (name, data) async => _stubs(),
          ),
          clipPlayer: _Clip(),
        ),
      ),
    ),
  );
  bloc.add(const StoryOpened(storyId: 'story_temple'));
  await tester.pumpAndSettle();
  return bloc;
}

Future<void> _window(WidgetTester tester, FeedBloc bloc) async {
  bloc.add(const PauseReached());
  await tester.pumpAndSettle();
  expect(bloc.state.phase, FeedPhase.window);
}

Offset _ring(WidgetTester tester, String choiceId) {
  return tester.getCenter(find.byKey(ValueKey('ring-$choiceId')));
}

Future<void> _closeBloc(WidgetTester tester, FeedBloc bloc) async {
  await tester.pumpWidget(const SizedBox.shrink());
  // Drain both fake frames and asynchronous stream cancellation before
  // leaving the test's clock, as in the preview widget tests.
  var closed = false;
  final closing = bloc.close().then((_) => closed = true);
  for (var i = 0; i < 30 && !closed; i++) {
    await tester.pump();
    await tester.runAsync(() async {});
  }
  expect(closed, isTrue);
  await closing;
}

class _Call {
  const _Call(this.name, this.data);

  final String name;
  final Map<String, dynamic>? data;
}

RunRepository _runs() {
  return RunRepository(
    execute: FunctionsClient(
      call: (name, data) async {
        if (name == 'startRun') {
          return {
            'runId': 'run_1',
            'storyId': 'story_temple',
            'status': 'active',
          };
        }
        if (name == 'loadPlayback') {
          return _playback();
        }
        throw StateError('unexpected $name');
      },
    ).call,
  );
}

GraphRepository _graphs(
  List<_Call> calls,
  Future<dynamic> Function(String name, Map<String, dynamic>? data) respond,
) {
  return GraphRepository(
    execute: FunctionsClient(
      call: (name, data) async {
        calls.add(_Call(name, data));
        return respond(name, data);
      },
    ).call,
  );
}

Map<String, dynamic> _playback() {
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
      'ttsText': null,
      'ttsAudioUrl': null,
      'ttsDurationSeconds': null,
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

Map<String, dynamic> _stubs() {
  return {
    'currentNodeId': 'node_001',
    'nodes': [
      {
        'nodeId': 'node_001',
        'title': 'The temple door',
        'isEnding': false,
        'visited': true,
        'secret': false,
        'choiceCount': 10,
        'imageBlurData': 'data:image/png;base64,$_png',
        'childIds': ['node_002', 'node_003'],
        'choices': [
          {
            'choiceId': 'c_enter',
            'label': 'Enter the room',
            'count': 6,
            'icon': 'key',
            'iconColor': 'gold',
          },
          {
            'choiceId': 'c_climb',
            'label': 'Climb the ridge',
            'count': 4,
            'icon': 'flag',
            'iconColor': 'blue',
          },
        ],
      },
      {
        'nodeId': 'node_002',
        'title': 'The inner room',
        'isEnding': false,
        'visited': true,
        'secret': false,
        'choiceCount': 0,
        'imageBlurData': 'data:image/png;base64,$_png',
        'childIds': <String>[],
      },
      {
        'nodeId': 'node_003',
        'title': null,
        'isEnding': false,
        'visited': false,
        'secret': true,
        'choiceCount': 4,
        'childIds': <String>[],
      },
    ],
  };
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

class _Slot implements WarmSlot {
  @override
  void mount(String url) {}

  @override
  void dispose() {}
}

class _Clock implements CueClock {
  Duration? scheduled;

  @override
  void schedule(Duration duration, void Function() fire) {
    scheduled = duration;
  }

  @override
  void cancel() {
    scheduled = null;
  }
}
