import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ramifica/core/widgets/status_pill.dart';
import 'package:ramifica/data/models/app_failure.dart';
import 'package:ramifica/data/models/user.dart';
import 'package:ramifica/data/repositories/auth_repository.dart';
import 'package:ramifica/data/repositories/create_repository.dart';
import 'package:ramifica/features/create/create_bloc.dart';
import 'package:ramifica/features/create/create_event.dart';
import 'package:ramifica/features/create/create_view.dart';
import 'package:ramifica/features/create/draft_canvas.dart';

void main() {
  group('CreateView', () {
    testWidgets('an empty tab offers a draft', (tester) async {
      final bloc = CreateBloc(repository: _repo(null));
      addTearDown(bloc.close);
      await tester.pumpWidget(MaterialApp(home: CreateView(bloc: bloc)));

      expect(find.text('Your drafts live here.'), findsOneWidget);
      await tester.tap(find.text('Start a draft'));
      await tester.pumpAndSettle();

      expect(bloc.state.hasDraft, isTrue);
      expect(bloc.state.openNodeId, 'node_1');
    });

    testWidgets('the canvas selects nodes and the inspector edits them', (
      tester,
    ) async {
      final bloc = await _pumpDraft(tester);

      // Titles, secrets, and orphans draw on the canvas painter, which
      // widget finders cannot see; selection through it is asserted below.

      // Tapping the leaf selects it in the inspector.
      final layout = layoutDraft(bloc.state.nodes, rootNodeId: 'node_1');
      final origin = tester.getTopLeft(find.byType(DraftCanvas));
      await tester.tapAt(origin + layout.positions['node_2']!);
      await tester.pumpAndSettle();
      expect(bloc.state.openNodeId, 'node_2');

      // Manual edits write bloc state through the fields.
      await tester.enterText(
        find.byKey(const ValueKey('title-node_2')),
        'Typed leaf',
      );
      await tester.pump();
      expect(bloc.state.openNode?.title, 'Typed leaf');
    });

    testWidgets('Spark fills empties but keeps manual edits', (tester) async {
      final calls = <_Call>[];
      final bloc = await _pumpDraft(tester, calls);

      await tester.enterText(
        find.byKey(const ValueKey('title-node_1')),
        'Typed root',
      );
      await tester.pump();
      await tester.tap(find.text('Spark'));
      await tester.pumpAndSettle();

      expect(calls.single.name, 'generateNodeText');
      expect(bloc.state.openNode?.title, 'Typed root');
      expect(bloc.state.openNode?.ttsText, 'What should they do next?');
    });

    testWidgets('Regenerate overwrites manual edits', (tester) async {
      final bloc = await _pumpDraft(tester);

      await tester.enterText(
        find.byKey(const ValueKey('title-node_1')),
        'Typed root',
      );
      await tester.pump();
      await tester.tap(find.text('Regenerate'));
      await tester.pumpAndSettle();

      expect(bloc.state.openNode?.title, 'Spark title');
    });

    testWidgets('Save sends the edited node and missing is listed', (
      tester,
    ) async {
      final calls = <_Call>[];
      await _pumpDraft(tester, calls);

      expect(find.textContaining('needs a ready video'), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is StatusPill && widget.status == StatusPillState.idle,
        ),
        findsOneWidget,
      );

      await tester.enterText(
        find.byKey(const ValueKey('title-node_1')),
        'Typed root',
      );
      await tester.pump();
      calls.clear();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final save = calls.singleWhere((call) => call.name == 'saveNode');
      final sent = (save.data['node'] as Map).map(
        (key, value) => MapEntry(key.toString(), value),
      );
      expect(sent['title'], 'Typed root');
    });

    testWidgets('a failure shows its phrase', (tester) async {
      final bloc = CreateBloc(
        repository: CreateRepository(
          createDraftDoc: ({required authorId, required title}) async =>
              throw const AppFailure(.offline),
          fetchStoryDoc: (_) async => throw const AppFailure(.offline),
          fetchNodeDocs: (_) async => const [],
          callFunction: (name, data) async => throw const AppFailure(.offline),
        ),
      );
      addTearDown(bloc.close);
      await tester.pumpWidget(MaterialApp(home: CreateView(bloc: bloc)));

      await tester.tap(find.text('Start a draft'));
      await tester.pumpAndSettle();

      // No author id and no signed-in identity: fails before any network.
      expect(find.text('That action is not valid'), findsOneWidget);
    });

    testWidgets('root shows S controls, child hides them', (tester) async {
      final bloc = await _pumpMediaDraft(tester);

      // S-vs-E comparison labels render for the open root.
      expect(find.text('Start'), findsOneWidget);
      expect(find.text('End'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('approve-start-node_1')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('approve-end-node_1')), findsOneWidget);

      // Tapping the leaf selects it in the inspector.
      final layout = layoutDraft(bloc.state.nodes, rootNodeId: 'node_1');
      final origin = tester.getTopLeft(find.byType(DraftCanvas));
      await tester.tapAt(origin + layout.positions['node_2']!);
      await tester.pumpAndSettle();
      expect(bloc.state.openNodeId, 'node_2');

      // The child inherits S: no S controls, but its own E controls.
      expect(find.byKey(const ValueKey('approve-start-node_2')), findsNothing);
      expect(find.byKey(const ValueKey('approve-end-node_2')), findsOneWidget);
    });

    testWidgets('approve dispatches the end-frame approval', (tester) async {
      final calls = <_Call>[];
      await _pumpMediaDraft(tester, calls);

      final approve = find.byKey(const ValueKey('approve-end-node_1'));
      await tester.ensureVisible(approve);
      await tester.pumpAndSettle();
      await tester.tap(approve);
      await tester.pumpAndSettle();

      final sent = calls.singleWhere((call) => call.name == 'approveNodeImage');
      expect(sent.data['nodeId'], 'node_1');
      expect(sent.data['which'], 'end');
      expect(sent.data['approved'], isTrue);
    });

    testWidgets('reject flips an approved end frame off', (tester) async {
      final calls = <_Call>[];
      await _pumpMediaDraft(tester, calls, _mediaDocs(approved: true));

      // The approved pill marks the approved E frame.
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is StatusPill && widget.status == StatusPillState.approved,
        ),
        findsWidgets,
      );

      final reject = find.byKey(const ValueKey('reject-end-node_1'));
      await tester.ensureVisible(reject);
      await tester.pumpAndSettle();
      await tester.tap(reject);
      await tester.pumpAndSettle();

      final sent = calls.singleWhere((call) => call.name == 'approveNodeImage');
      expect(sent.data['which'], 'end');
      expect(sent.data['approved'], isFalse);
    });

    testWidgets('gated video shows the message and disables generation', (
      tester,
    ) async {
      final bloc = await _pumpMediaDraft(tester);

      final layout = layoutDraft(bloc.state.nodes, rootNodeId: 'node_1');
      final origin = tester.getTopLeft(find.byType(DraftCanvas));
      await tester.tapAt(origin + layout.positions['node_2']!);
      await tester.pumpAndSettle();
      expect(bloc.state.openNodeId, 'node_2');

      // The parent E is unapproved: the gate message shows and the video
      // button is disabled.
      expect(
        find.text('The parent end frame must be approved first.'),
        findsOneWidget,
      );
      final generate = tester.widget<OutlinedButton>(
        find.byKey(const ValueKey('gen-video-node_2')),
      );
      expect(generate.onPressed, isNull);
    });

    testWidgets('a stale child video shows the desync badge', (tester) async {
      final bloc = await _pumpMediaDraft(tester);

      final layout = layoutDraft(bloc.state.nodes, rootNodeId: 'node_1');
      final origin = tester.getTopLeft(find.byType(DraftCanvas));
      await tester.tapAt(origin + layout.positions['node_2']!);
      await tester.pumpAndSettle();
      expect(bloc.state.openNodeId, 'node_2');

      // The parent regenerated E after this child inherited S.
      expect(find.textContaining('Out of sync'), findsOneWidget);
    });

    testWidgets('the upload button hides without a picker', (tester) async {
      await _pumpMediaDraft(tester);

      expect(find.byKey(const ValueKey('upload-video-node_1')), findsNothing);
    });

    testWidgets('retakes, video generate, and voice status show', (
      tester,
    ) async {
      await _pumpMediaDraft(tester);

      // Generated S and E frames offer another take (same generate call).
      expect(find.text('Another take'), findsNWidgets(2));
      // No video yet: the generate label stays.
      expect(find.text('Generate video'), findsOneWidget);
      // Voice has no take callable: status only.
      expect(find.text('Voice'), findsOneWidget);
      expect(find.text('No narrator voice yet.'), findsOneWidget);
    });

    testWidgets('a node video offers another take', (tester) async {
      await _pumpUploadDraft(
        tester,
        docs: [
          MapEntry('node_1', {
            ..._mediaDocs().first.value,
            'videoUrl': 'https://cdn.example/v.mp4',
          }),
        ],
      );

      // S row, E row, and the video button all retake.
      expect(find.text('Another take'), findsNWidgets(3));
      expect(find.text('Generate video'), findsNothing);
    });

    testWidgets('upload dispatches, shows progress, then clears', (
      tester,
    ) async {
      final calls = <_Call>[];
      final gate = Completer<void>();
      final bloc = await _pumpUploadDraft(
        tester,
        calls: calls,
        upload:
            ({
              required path,
              required contentType,
              required bytes,
              onProgress,
            }) async {
              calls.add(
                _Call('uploadNodeVideo', {
                  'path': path,
                  'contentType': contentType,
                  'byteLength': bytes.length,
                }),
              );
              onProgress?.call(0.5);
              await gate.future;
            },
      );

      final upload = find.byKey(const ValueKey('upload-video-node_1'));
      await tester.ensureVisible(upload);
      await tester.pumpAndSettle();
      await tester.tap(upload);
      await tester.pump();

      // In flight: the trigger path is hit and progress shows.
      expect(calls, hasLength(1));
      expect(
        calls.single.data['path'],
        'uploads/uid_1/story_1_node_1_take_1.mp4',
      );
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(find.text('50%'), findsOneWidget);

      gate.complete();
      await tester.pumpAndSettle();

      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(bloc.state.failure, isNull);
    });

    testWidgets('a bad pick is rejected without network', (tester) async {
      final calls = <_Call>[];
      await _pumpUploadDraft(
        tester,
        calls: calls,
        pick: () async =>
            const PickedVideoFile(contentType: 'video/avi', bytes: [1, 2, 3]),
      );

      final upload = find.byKey(const ValueKey('upload-video-node_1'));
      await tester.ensureVisible(upload);
      await tester.pumpAndSettle();
      await tester.tap(upload);
      await tester.pumpAndSettle();

      expect(
        find.text('Only mp4 or mov videos can be uploaded.'),
        findsOneWidget,
      );
      expect(calls.where((call) => call.name == 'uploadNodeVideo'), isEmpty);
    });

    testWidgets('a trigger failure surfaces its phrase', (tester) async {
      await _pumpUploadDraft(
        tester,
        docs: [
          MapEntry('node_1', {
            ..._mediaDocs().first.value,
            'uploadError': 'encode-failed',
          }),
        ],
      );

      final upload = find.byKey(const ValueKey('upload-video-node_1'));
      await tester.ensureVisible(upload);
      await tester.pumpAndSettle();
      await tester.tap(upload);
      await tester.pumpAndSettle();

      expect(find.text('Something failed'), findsOneWidget);
    });
  });
}

class _Call {
  const _Call(this.name, this.data);

  final String name;
  final Map<String, dynamic> data;
}

Future<CreateBloc> _pumpDraft(WidgetTester tester, [List<_Call>? calls]) async {
  final bloc = CreateBloc(repository: _repo(calls));
  addTearDown(bloc.close);
  bloc.add(const DraftOpened('story_1'));
  await bloc.stream.firstWhere((state) => state.hasDraft);
  await tester.pumpWidget(MaterialApp(home: CreateView(bloc: bloc)));
  await tester.pumpAndSettle();
  return bloc;
}

Future<CreateBloc> _pumpMediaDraft(
  WidgetTester tester, [
  List<_Call>? calls,
  List<MapEntry<String, Map<String, dynamic>>>? docs,
]) async {
  final bloc = CreateBloc(repository: _repo(calls, docs: docs ?? _mediaDocs()));
  addTearDown(bloc.close);
  bloc.add(const DraftOpened('story_1'));
  await bloc.stream.firstWhere((state) => state.hasDraft);
  await tester.pumpWidget(MaterialApp(home: CreateView(bloc: bloc)));
  await tester.pumpAndSettle();
  return bloc;
}

/// Pumps the open root with an upload picker and an identified author, so
/// [VideoUploadRequested] resolves `uid_1` like production.
Future<CreateBloc> _pumpUploadDraft(
  WidgetTester tester, {
  List<_Call>? calls,
  List<MapEntry<String, Map<String, dynamic>>>? docs,
  UploadVideoFile? upload,
  PickVideoFile? pick,
  String takeId = 'take_1',
}) async {
  final resolved = (docs ?? _mediaDocs()).map((doc) {
    if (doc.key == 'node_1' && !doc.value.containsKey('uploadTakeId')) {
      return MapEntry(doc.key, {...doc.value, 'uploadTakeId': takeId});
    }
    return doc;
  }).toList();
  final bloc = CreateBloc(
    repository: _repo(calls, docs: resolved, upload: upload),
    auth: _auth('uid_1'),
  );
  addTearDown(bloc.close);
  bloc.add(const DraftOpened('story_1'));
  await bloc.stream.firstWhere((state) => state.hasDraft);
  await tester.pumpWidget(
    MaterialApp(
      home: CreateView(
        bloc: bloc,
        pickVideo:
            pick ??
            () async =>
                const PickedVideoFile(contentType: 'video/mp4', bytes: [1]),
        newTakeId: () => takeId,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return bloc;
}

AuthRepository _auth(String? uid) =>
    AuthRepository(auth: _Gateway(uid), users: _Users());

class _Gateway implements AuthGateway {
  _Gateway(this.uid);

  final String? uid;

  @override
  AuthIdentity? get currentIdentity =>
      uid == null ? null : AuthIdentity(uid: uid!);

  @override
  Stream<AuthIdentity?> authStateChanges() =>
      Stream<AuthIdentity?>.value(currentIdentity);

  @override
  Future<void> completeGoogleRedirect() async {}

  @override
  Future<void> sendPasswordReset(String email) async {}

  @override
  Future<void> signInWithEmail({
    required String email,
    required String password,
  }) async {}

  @override
  Future<void> signInWithGooglePopup() async {}

  @override
  Future<void> signInWithGoogleRedirect() async {}

  @override
  Future<void> signOut() async {}

  @override
  Future<void> signUpWithEmail({
    required String email,
    required String password,
  }) async {}
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

/// Root with generated-but-unapproved S/E plus a stale child: the child
/// inherited `hash-old` while the parent E is now `hash-e1`, and its
/// video sits at `idle` waiting to re-inherit.
List<MapEntry<String, Map<String, dynamic>>> _mediaDocs({
  bool approved = false,
}) {
  return [
    MapEntry('node_1', {
      'title': 'Root',
      'visibility': 'visible',
      'isEnding': false,
      'videoStatus': 'idle',
      'windowSeconds': 6,
      'ttsText': '',
      'lineApproved': false,
      'ttsStatus': 'idle',
      'startImageSourceUrl': 'https://frames.invalid/s.webp',
      'startImageStatus': 'ready',
      'startHash': 'hash-s',
      'startImageApproved': approved,
      'endImageSourceUrl': 'https://frames.invalid/e1.webp',
      'endImageStatus': 'ready',
      'endHash': 'hash-e1',
      'endImageApproved': approved,
      'choices': [
        {
          'choiceId': 'c1',
          'label': '',
          'targetNodeId': 'node_2',
          'isDefault': true,
          'x': 0.25,
          'y': 0.65,
          'radius': 0.15,
        },
      ],
    }),
    const MapEntry('node_2', {
      'title': 'Leaf',
      'visibility': 'visible',
      'isEnding': true,
      'endingName': 'Escape',
      'endingType': 'abierto',
      'videoStatus': 'idle',
      'startFromNodeId': 'node_1',
      'startParentEndHash': 'hash-old',
      'endImageSourceUrl': 'https://frames.invalid/e2.webp',
      'endImageStatus': 'ready',
      'endHash': 'hash-e2',
      'endImageApproved': false,
    }),
  ];
}

CreateRepository _repo(
  List<_Call>? calls, {
  List<MapEntry<String, Map<String, dynamic>>>? docs,
  UploadVideoFile? upload,
}) {
  return CreateRepository(
    createDraftDoc: ({required authorId, required title}) async => 'story_1',
    fetchStoryDoc: (_) async => {
      'authorId': 'uid_1',
      'title': 'Temple',
      'synopsis': '',
      'status': 'draft',
      'rootNodeId': 'node_1',
    },
    fetchNodeDocs: (_) async =>
        docs ??
        [
          MapEntry('node_1', {
            'title': 'Root',
            'visibility': 'visible',
            'isEnding': false,
            'videoStatus': 'idle',
            'windowSeconds': 6,
            'ttsText': '',
            'lineApproved': false,
            'ttsStatus': 'idle',
            'choices': [
              {
                'choiceId': 'c1',
                'label': '',
                'targetNodeId': 'node_2',
                'isDefault': true,
                'x': 0.25,
                'y': 0.65,
                'radius': 0.15,
              },
            ],
          }),
          const MapEntry('node_2', {
            'title': 'Leaf',
            'visibility': 'secret',
            'isEnding': true,
            'endingName': 'Escape',
            'endingType': 'abierto',
          }),
        ],
    callFunction: (name, data) async {
      calls?.add(_Call(name, data));
      return switch (name) {
        'createNode' => {'nodeId': 'node_1'},
        'generateNodeText' => {
          'title': 'Spark title',
          'ttsText': 'What should they do next?',
          'choices': [
            {'label': 'Enter'},
            {'label': 'Climb'},
          ],
          'endingName': null,
        },
        _ => <String, dynamic>{},
      };
    },
    uploadVideoFile:
        upload ??
        ({
          required path,
          required contentType,
          required bytes,
          onProgress,
        }) async {
          calls?.add(
            _Call('uploadNodeVideo', {
              'path': path,
              'contentType': contentType,
              'byteLength': bytes.length,
            }),
          );
          onProgress?.call(1);
        },
  );
}
