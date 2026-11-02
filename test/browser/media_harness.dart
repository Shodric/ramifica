// Browser-only harness: real editor and real media players, simulated AI, no keys.
import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:ramifica/app/theme.dart';
import 'package:ramifica/data/persistence/document_store.dart';
import 'package:ramifica/data/persistence/draft_persistence.dart';
import 'package:ramifica/data/repositories/create_repository.dart';
import 'package:ramifica/features/create/create_bloc.dart';
import 'package:ramifica/features/create/create_event.dart';
import 'package:ramifica/features/create/create_node_screen.dart';

import '../support/memory_document_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Uri.base.queryParameters['semantics'] == 'on') {
    SemanticsBinding.instance.ensureSemantics();
  }
  Element? elementFor(String key) {
    Element? found;
    void visit(Element element) {
      if (found != null) return;
      if (element.widget.key == ValueKey(key)) {
        found = element;
        return;
      }
      element.visitChildElements(visit);
    }

    WidgetsBinding.instance.rootElement?.visitChildElements(visit);
    return found;
  }

  globalContext.setProperty(
    'ramificaTestBounds'.toJS,
    ((JSString name) {
      final element = elementFor(name.toDart);
      final render = element?.findRenderObject();
      if (render is! RenderBox || !render.hasSize) return 'null'.toJS;
      final origin = render.localToGlobal(Offset.zero);
      return jsonEncode({
        'x': origin.dx,
        'y': origin.dy,
        'width': render.size.width,
        'height': render.size.height,
        'enabled': switch (element?.widget) {
          IconButton(onPressed: final callback) => callback != null,
          ButtonStyleButton(onPressed: final callback) => callback != null,
          _ => true,
        },
      }).toJS;
    }).toJS,
  );
  globalContext.setProperty(
    'ramificaTestText'.toJS,
    ((JSString text) {
      var found = false;
      void visit(Element element) {
        if (element.widget case Text(data: final data)
            when data == text.toDart) {
          found = true;
        }
        element.visitChildElements(visit);
      }

      WidgetsBinding.instance.rootElement?.visitChildElements(visit);
      return found.toJS;
    }).toJS,
  );
  final store = MemoryDocumentStore();
  store.documents['stories/browser'] = {
    'authorId': 'author',
    'title': 'Media test',
    'synopsis': 'Local fixtures; no generation providers',
    'rootNodeId': 'root',
    'status': 'draft',
    'revision': 0,
  };
  final base = Uri.base.origin;
  final storagePort = Uri.base.queryParameters['storage'];
  String fixture(String name) => storagePort == null
      ? '$base/fixtures/$name'
      : 'http://127.0.0.1:$storagePort/v0/b/demo-ramifica-plan.appspot.com/o/${Uri.encodeComponent('fixtures/$name')}?alt=media&token=fixture-token';
  store.documents['stories/browser/nodes/root'] = {
    'title': 'Gate',
    'visibility': 'visible',
    'isEnding': false,
    'ttsText': 'Which way?',
    'lineApproved': true,
    'ttsApproved': true,
    'ttsStatus': 'ready',
    'ttsAudioUrl': fixture('voice.m4a'),
    'ttsDurationSeconds': 3,
    'videoUrl': fixture('clip.mp4'),
    'videoSource': 'generated',
    'videoStatus': 'ready',
    'durationSeconds': 10,
    'videoWidth': 480,
    'videoHeight': 854,
    'videoFromHash': 'start',
    'videoFrameLastUrl': fixture('frame.png'),
    'videoFrameLastHash': 'end',
    'startImageStatus': 'ready',
    'startImageApproved': true,
    'startHash': 'start',
    'startImageSourceUrl': fixture('frame.png'),
    'startImageWidth': 480,
    'startImageHeight': 854,
    'choices': [
      {
        'choiceId': 'c',
        'label': 'Enter',
        'targetNodeId': 'end',
        'isDefault': true,
        'slot': 'A',
        'x': .5,
        'y': .5,
        'radius': .1,
      },
    ],
  };
  store.documents['stories/browser/nodes/end'] = {
    'title': 'End',
    'visibility': 'visible',
    'isEnding': true,
    'choices': [],
    'ttsText': '',
  };
  final writer = ClientDraftPersistence(store, () => 'author');
  final repository = CreateRepository(
    drafts: writer,
    createDraftDoc: ({required authorId, required title}) async => 'browser',
    fetchStoryDoc: (id) => store.get('stories/$id'),
    fetchNodeDocs: (id) => store.list('stories/$id/nodes'),
    fetchNodeDoc: (id, node) => store.get('stories/$id/nodes/$node'),
    updateStoryDoc: ({required storyId, title, synopsis}) =>
        writer.updateStory(storyId, title: title, synopsis: synopsis),
    callFunction: (name, data) async {
      if (![
        'generateNodeImage',
        'generateNodeVideo',
        'generateNodeVoice',
      ].contains(name)) {
        throw StateError('Unexpected callable $name');
      }
      final path = 'stories/browser/nodes/root';
      final old = store.documents[path]!;
      final kind = name == 'generateNodeVoice'
          ? 'voice'
          : name == 'generateNodeVideo'
          ? 'video'
          : '${data['which']}Image';
      final status = name == 'generateNodeVoice'
          ? 'ttsStatus'
          : name == 'generateNodeVideo'
          ? 'videoStatus'
          : '${data['which']}ImageStatus';
      await Future<void>.delayed(const Duration(milliseconds: 700));
      await store.batch([
        DocumentWrite(path, {
          status: 'pending',
          'generationKind': kind,
          'generationPhase': 'generating',
        }, merge: true),
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 700));
      await store.batch([
        DocumentWrite(path, {'generationPhase': 'processing'}, merge: true),
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 700));
      await store.batch([
        DocumentWrite(path, {
          status: 'ready',
          'generationKind': null,
          'generationPhase': null,
          if (name == 'generateNodeVideo') 'videoUrl': fixture('clip2.mp4'),
          if (name == 'generateNodeVoice') 'ttsAudioUrl': fixture('voice2.m4a'),
          if (name == 'generateNodeVoice') 'ttsDurationSeconds': 3,
          if (name == 'generateNodeImage')
            'startImageSourceUrl': '$base/fixtures/frame.png?take=2',
          if (name == 'generateNodeImage')
            'startHash': 'new-${old['startHash']}',
        }, merge: true),
      ]);
      return {'poll': false};
    },
  );
  final bloc = CreateBloc(repository: repository);
  final ready = bloc.stream.firstWhere((state) => state.hasDraft);
  bloc.add(const DraftOpened('browser'));
  await ready;
  runApp(
    MaterialApp(
      theme: RamificaTheme.data,
      home: BlocProvider.value(
        value: bloc,
        child: CreateNodeScreen(
          bloc: bloc,
          nodeId: 'root',
          pickVideo: null,
          newTakeId: () => 'take',
        ),
      ),
    ),
  );
}
