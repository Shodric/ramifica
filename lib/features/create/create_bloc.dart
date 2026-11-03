import 'dart:async';
import 'dart:convert';

import 'package:bloc/bloc.dart';
import 'package:bloc_concurrency/bloc_concurrency.dart';
import 'package:flutter/foundation.dart';
import 'package:ramifica/data/models/app_failure.dart';
import 'package:ramifica/data/models/draft_node.dart';
import 'package:ramifica/data/models/draft_story.dart';
import 'package:ramifica/data/persistence/draft_persistence.dart';
import 'package:ramifica/data/persistence/publication.dart';
import 'package:ramifica/data/repositories/auth_repository.dart';
import 'package:ramifica/data/repositories/create_repository.dart';
import 'package:ramifica/features/create/create_event.dart';
import 'package:ramifica/features/create/create_state.dart';
import 'package:uuid/uuid.dart';

/// Draft, nodes, and Spark proposals for the Create tab.
///
/// The signed-in uid comes from [auth]'s current identity when
/// [DraftRequested] carries no author id, so a mid-session account change
/// cannot draft on a stale id. Tests pass the author id in the event and
/// leave [auth] null.
class CreateBloc extends Bloc<CreateEvent, CreateState> {
  CreateBloc({
    required this.repository,
    DraftPersistence? drafts,
    ClientPublisher? publisher,
    this.auth,
    this.uploadPollInterval = const Duration(seconds: 2),
    this.maxUploadPolls = 30,
    this.videoPollInterval = const Duration(seconds: 10),
    this.maxVideoPolls = 40,
  }) : drafts = drafts ?? repository.persistence,
       publisher = publisher ?? repository.publisher,
       super(const CreateState()) {
    on<DraftRequested>(_onDraftRequested, transformer: restartable());
    on<DraftOpened>(_onDraftOpened, transformer: restartable());
    on<StoriesRequested>(_onStoriesRequested, transformer: restartable());
    on<NodeSelected>(_onNodeSelected);
    on<DraftNodesObserved>((event, emit) {
      if (event.storyId != state.story?.storyId) return;
      if (event.error != null) {
        emit(
          state.copy(
            failure: () => 'Could not sync the draft. Retry when connected.',
          ),
        );
      } else {
        emit(state.copy(nodes: _mergeReload(event.nodes)));
      }
    });
    on<NodeAdded>(_serialized(_onNodeAdded), transformer: droppable());
    on<HotspotAdded>(_serialized(_onHotspotAdded), transformer: droppable());
    on<OutlineApplied>(
      _serialized(_onOutlineApplied),
      transformer: droppable(),
    );
    on<SceneProposalApplied>(
      _serialized(_onSceneProposalApplied),
      transformer: droppable(),
    );
    on<StoryFieldChanged>((event, emit) {
      final story = state.story;
      if (story == null) return;
      final next = story.copy(title: event.title, synopsis: event.synopsis);
      if (next == story) return;
      _storyEditGeneration++;
      final stories = [
        for (final entry in state.stories)
          if (entry.storyId == story.storyId) next else entry,
      ];
      emit(
        state.copy(story: () => next, stories: stories, failure: () => null),
      );
    });
    on<NodeFieldChanged>(_onFieldChanged);
    on<NodeSaved>(_serialized(_onNodeSaved));
    on<StorySaved>(_serialized(_onStorySaved));
    on<EditsDiscarded>(_serialized(_onEditsDiscarded));
    on<CoverGenerateRequested>(
      _serialized(_onCoverGenerate),
      transformer: droppable(),
    );
    on<NodeDeleted>(_serialized(_onNodeDeleted), transformer: droppable());
    on<StoryPublished>(
      _serialized(_onStoryPublished),
      transformer: droppable(),
    );
    on<StoryUnpublished>(
      _serialized(_onStoryUnpublished),
      transformer: droppable(),
    );
    on<StoryDeleted>(_serialized(_onStoryDeleted), transformer: droppable());
    on<ZonesSaved>(_serialized(_onZonesSaved), transformer: droppable());
    on<ZoneMoved>(_onZoneMoved);
    on<ChoiceAdded>(_onChoiceAdded);
    on<ChoiceRemoved>(_onChoiceRemoved);
    on<ChoiceCutToggled>(_onChoiceCutToggled);
    on<NodeEndingToggled>(_onNodeEndingToggled);
    on<ChoiceIconDecided>(_onChoiceIconDecided);
    on<TextGenerateRequested>(
      _serialized(_onGenerate),
      transformer: droppable(),
    );
    on<VoiceGenerateRequested>(
      _serialized(_onVoiceGenerate),
      transformer: droppable(),
    );
    on<NarrationGenerateRequested>(
      _serialized(_onNarrationGenerate),
      transformer: droppable(),
    );
    on<ImageGenerateRequested>(
      _serialized(_onImageGenerate),
      transformer: droppable(),
    );
    on<VideoGenerateRequested>(
      _serialized(_onVideoGenerate),
      transformer: droppable(),
    );
    on<VideoUploadRequested>(
      _serialized(_onVideoUpload),
      transformer: droppable(),
    );
    on<VideoUploadProgressed>(_onVideoUploadProgressed);
  }
  final CreateRepository repository;

  /// Direct client writes for every authoring mutation. Defaults to the
  /// repository's stack; tests inject a memory-backed writer.
  final DraftPersistence drafts;

  /// Client-side publisher for the draft checklist. Null only when the
  /// repository was built without one; publishing then fails closed.
  final ClientPublisher? publisher;
  final AuthRepository? auth;

  /// Local edit generation per node: bumped on every state-only edit so
  /// a stale save confirmation never marks newer edits as persisted.
  /// The view keeps its own dirty flag; the bloc uses this to avoid
  /// clobbering concurrent edits when a save + reload overlaps them.
  final Map<String, int> _editGeneration = {};

  final _dirtyFields = <String, Map<String, int>>{};
  void _markEdited(
    String nodeId, {
    Iterable<String> fields = const ['choices'],
  }) {
    if (nodeId.isEmpty) return;
    final generation = (_editGeneration[nodeId] ?? 0) + 1;
    _editGeneration[nodeId] = generation;
    final versions = _dirtyFields.putIfAbsent(nodeId, () => {});
    for (final field in fields) {
      versions[field] = generation;
    }
  }

  final Map<String, int> _savedGeneration = {};
  int _storyEditGeneration = 0, _storySavedGeneration = 0;
  bool get hasUnsavedStoryEdits =>
      _storyEditGeneration != _storySavedGeneration;
  Future<void> _persistStory() async {
    while (hasUnsavedStoryEdits && !isClosed) {
      final snapshot = state.story;
      if (snapshot == null) return;
      final generation = _storyEditGeneration;
      final title = snapshot.title.trim();
      final synopsis = snapshot.synopsis.trim();
      if (title.isEmpty && synopsis.isEmpty) {
        throw const AppFailure(.invalid);
      }
      await drafts.updateStory(
        snapshot.storyId,
        title: title.isEmpty ? null : title,
        synopsis: synopsis.isEmpty ? null : synopsis,
      );
      _storySavedGeneration = generation;
    }
  }

  Future<void> _operationTail = Future<void>.value();
  StreamSubscription<List<DraftNode>>? _draftSubscription;
  final _closing = Completer<void>();

  void _watch(String storyId) {
    unawaited(_draftSubscription?.cancel());
    _draftSubscription = drafts
        .watchNodes(storyId)
        .listen(
          (nodes) {
            if (!isClosed && !_closing.isCompleted) {
              add(DraftNodesObserved(storyId, nodes));
            }
          },
          onError: (Object error) {
            if (!isClosed && !_closing.isCompleted) {
              add(DraftNodesObserved(storyId, const [], error: error));
            }
          },
        );
  }

  List<DraftNode> _mergeChanged(List<DraftNode> changed) {
    final byId = {for (final node in state.nodes) node.nodeId: node};
    for (final node in changed) {
      byId[node.nodeId] = node;
    }
    return _mergeReload(byId.values.toList());
  }

  Future<void> _refreshNode(
    String storyId,
    String nodeId,
    Emitter<CreateState> emit,
  ) async {
    final node = await repository.fetchNode(storyId, nodeId);
    if (node != null && !isClosed && !emit.isDone) {
      emit(state.copy(nodes: _mergeChanged([node])));
    }
  }

  @override
  Future<void> close() async {
    if (!_closing.isCompleted) _closing.complete();
    await _draftSubscription?.cancel();
    return super.close();
  }

  // Serializes all writes, not just events of the same type. Each queued
  // operation reads the latest state when it starts, rather than saving a
  // snapshot captured before another operation completed.
  Future<void> Function(E, Emitter<CreateState>) _serialized<
    E extends CreateEvent
  >(Future<void> Function(E, Emitter<CreateState>) handler) => (event, emit) {
    final operation = _operationTail.then((_) async {
      if (!isClosed && !emit.isDone) await handler(event, emit);
    });
    _operationTail = operation.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );
    return operation;
  };

  DraftNode? _node(String nodeId) {
    for (final node in state.nodes) {
      if (node.nodeId == nodeId) return node;
    }
    return null;
  }

  bool _isDirty(String nodeId) =>
      (_editGeneration[nodeId] ?? 0) != (_savedGeneration[nodeId] ?? 0);

  /// Manual edits stay local until Save, Apply, or generation persists them.
  bool hasUnsavedNodeEdits(String nodeId) => _isDirty(nodeId);

  /// Completes after queued writes and the latest local revision are saved.
  Future<bool> flushNode(String nodeId) {
    final completion = Completer<bool>();
    if (isClosed) return Future<bool>.value(false);
    add(NodeSaved(nodeId: nodeId, completion: completion));
    return completion.future;
  }

  void _publishNode(DraftNode node, Emitter<CreateState> emit) {
    emit(
      state.copy(
        nodes: [
          for (final existing in state.nodes)
            if (existing.nodeId == node.nodeId) node else existing,
        ],
      ),
    );
  }

  /// Keep unsaved author edits while accepting server-owned media fields.
  List<DraftNode> _mergeReload(List<DraftNode> remote) {
    final merged = <DraftNode>[];
    for (final node in remote) {
      final local = _node(node.nodeId);
      merged.add(
        local != null && _isDirty(node.nodeId)
            ? DraftNode.fromMap(node.nodeId, {
                ...node.toJson(),
                for (final entry
                    in (_dirtyFields[node.nodeId] ?? <String, int>{}).entries)
                  if (entry.value > (_savedGeneration[node.nodeId] ?? 0))
                    entry.key: local.toJson()[entry.key],
              })
            : node,
      );
    }
    final ids = remote.map((node) => node.nodeId).toSet();
    merged.addAll(
      state.nodes.where(
        (node) => !ids.contains(node.nodeId) && _isDirty(node.nodeId),
      ),
    );
    return merged;
  }

  Future<void> _persistNode(
    String storyId,
    String nodeId, {
    bool force = false,
  }) async {
    var save = force || _isDirty(nodeId);
    while (save && !isClosed) {
      final snapshot = _node(nodeId);
      if (snapshot == null) return;
      final revision = _editGeneration[nodeId] ?? 0;
      await drafts.save(storyId, snapshot);
      _savedGeneration[nodeId] = revision;
      save = _isDirty(nodeId);
    }
  }

  /// Delay between trigger-observation polls after an upload.
  final Duration uploadPollInterval;

  /// How many trigger-observation polls run before the upload fails
  /// closed. Bounds the `uploading` job when the trigger is slow.
  final int maxUploadPolls;

  /// Delay between video-job polls after a generate tap.
  final Duration videoPollInterval;

  /// How many video-job polls run before generation fails closed. Bounds
  /// the `imaging` job; a later tap resumes the same backend job.
  final int maxVideoPolls;

  Future<void> _onDraftRequested(
    DraftRequested event,
    Emitter<CreateState> emit,
  ) async {
    final author =
        event.authorId?.trim() ?? auth?.auth.currentIdentity?.uid.trim() ?? '';
    if (author.isEmpty) {
      emit(state.copy(failure: () => const AppFailure(.invalid).phrase));
      return;
    }
    emit(
      state.copy(
        job: CreateJob.loading,
        jobNodeId: () => null,
        failure: () => null,
      ),
    );
    try {
      final created = await drafts.createDraft(author, event.title);
      emit(
        CreateState(
          story: created.$1,
          nodes: [created.$2],
          stories: _upsertStory(created.$1),
          openNodeId: created.$2.nodeId,
        ),
      );
      _storyEditGeneration = _storySavedGeneration = 0;
      _editGeneration.clear();
      _savedGeneration.clear();
      _dirtyFields.clear();
      _watch(created.$1.storyId);
    } on AppFailure catch (error) {
      emit(
        state.copy(
          job: CreateJob.none,
          jobNodeId: () => null,
          failure: () => error.hint,
        ),
      );
    }
  }

  Future<void> _onDraftOpened(
    DraftOpened event,
    Emitter<CreateState> emit,
  ) async {
    final storyId = event.storyId.trim();
    if (storyId.isEmpty) {
      emit(state.copy(failure: () => const AppFailure(.invalid).phrase));
      return;
    }
    emit(
      state.copy(
        job: CreateJob.loading,
        jobNodeId: () => null,
        failure: () => null,
      ),
    );
    try {
      final story = await repository.fetchDraft(storyId);
      if (story == null) throw const AppFailure(.invalid);
      final nodes = await repository.fetchNodes(storyId);
      final root = story.rootNodeId;
      final open = nodes.any((node) => node.nodeId == root)
          ? root
          : (nodes.isEmpty ? null : nodes.first.nodeId);
      emit(
        CreateState(
          story: story,
          nodes: nodes,
          stories: state.stories,
          openNodeId: open,
        ),
      );
      _storyEditGeneration = _storySavedGeneration = 0;
      _editGeneration.clear();
      _savedGeneration.clear();
      _dirtyFields.clear();
      _watch(storyId);
    } on AppFailure catch (error) {
      emit(
        state.copy(
          job: CreateJob.none,
          jobNodeId: () => null,
          failure: () => error.hint,
        ),
      );
    }
  }

  Future<void> _onStoriesRequested(
    StoriesRequested event,
    Emitter<CreateState> emit,
  ) async {
    final author =
        event.authorId?.trim() ?? auth?.auth.currentIdentity?.uid.trim() ?? '';
    if (author.isEmpty) return;
    try {
      final stories = await repository.fetchAuthorStories(authorId: author);
      emit(state.copy(stories: stories, failure: () => null));
    } on AppFailure catch (error) {
      emit(state.copy(failure: () => error.hint));
    }
  }

  /// Inserts or replaces [story] in the creations list, newest first
  /// (missing dates sort last, ties break by title like the fetch).
  List<DraftStory> _upsertStory(DraftStory story) {
    final rest = [
      for (final entry in state.stories)
        if (entry.storyId != story.storyId) entry,
    ];
    final next = [...rest, story];
    next.sort((a, b) {
      final au = a.updatedAt;
      final bu = b.updatedAt;
      if (au == null && bu == null) return a.title.compareTo(b.title);
      if (au == null) return 1;
      if (bu == null) return -1;
      return bu.compareTo(au);
    });
    return next;
  }

  void _onNodeSelected(NodeSelected event, Emitter<CreateState> emit) {
    final id = event.nodeId.trim();
    if (id.isEmpty) return;
    if (state.nodes.any((node) => node.nodeId == id)) {
      emit(state.copy(openNodeId: () => id, failure: () => null));
    }
  }

  Future<void> _onNodeAdded(NodeAdded event, Emitter<CreateState> emit) async {
    final story = state.story;
    final parent = _node(event.parentNodeId ?? '') ?? state.openNode;
    if (story == null || parent == null) return;
    emit(
      state.copy(
        job: CreateJob.saving,
        jobNodeId: () => parent.nodeId,
        failure: () => null,
      ),
    );
    try {
      await _persistNode(story.storyId, parent.nodeId);
      final change = await drafts.createAndLink(
        story.storyId,
        parent.nodeId,
        slot: event.slot,
      );
      emit(
        state.copy(
          nodes: _mergeChanged(change.nodes),
          openNodeId: () => change.selectedId,
          job: CreateJob.none,
          jobNodeId: () => null,
        ),
      );
    } on AppFailure catch (error) {
      emit(
        state.copy(
          job: CreateJob.none,
          jobNodeId: () => parent.nodeId,
          failure: () => error.hint,
        ),
      );
    }
  }

  /// Hotspot path: creates a child under [event.nodeId] on [event.slot]
  /// and links it as a choice — mirroring [_onNodeAdded] but without
  /// navigation. The parent stays open and the new choice carries the
  /// slot's default icon and color with an empty label; the state sets
  /// `focusChoiceId` so the hotspots step focuses the new label field.
  /// Ignored without a draft, on unknown parents, on taken slots, and
  /// past the two-choice cap in [_linkChoice].
  Future<void> _onHotspotAdded(
    HotspotAdded event,
    Emitter<CreateState> emit,
  ) async {
    final story = state.story;
    final parent = _node(event.nodeId);
    if (story == null || parent == null || !['A', 'B'].contains(event.slot)) {
      return;
    }
    emit(
      state.copy(
        job: CreateJob.saving,
        jobNodeId: () => parent.nodeId,
        failure: () => null,
      ),
    );
    try {
      await _persistNode(story.storyId, parent.nodeId);
      final change = await drafts.createAndLink(
        story.storyId,
        parent.nodeId,
        slot: event.slot,
      );
      final linked = change.nodes.firstWhere((n) => n.nodeId == parent.nodeId);
      final choice = linked.choices
          .where((c) => c.targetNodeId == change.selectedId)
          .firstOrNull;
      emit(
        state.copy(
          nodes: _mergeChanged(change.nodes),
          focusChoiceId: () => choice?.choiceId,
          job: CreateJob.none,
          jobNodeId: () => null,
        ),
      );
    } on AppFailure catch (error) {
      emit(
        state.copy(
          job: CreateJob.none,
          jobNodeId: () => parent.nodeId,
          failure: () => error.hint,
        ),
      );
    }
  }

  /// Voice-outline path: applies a proposed story outline without
  /// navigating. Updates the story doc when a non-blank title or synopsis
  /// arrives, sets the root narrator line, and creates one child per
  /// option (max two, slots A then B) with clamped labels and catalogued
  /// icons. Malformed options are skipped.
  Future<void> _onOutlineApplied(
    OutlineApplied event,
    Emitter<CreateState> emit,
  ) async {
    final story = state.story;
    final root = _node(story?.rootNodeId ?? '');
    if (story == null || root == null) return;
    emit(
      state.copy(
        job: CreateJob.saving,
        jobNodeId: () => root.nodeId,
        failure: () => null,
      ),
    );
    try {
      await _persistNode(story.storyId, root.nodeId);
      final storyGeneration = _storyEditGeneration;
      final change = await drafts.applyScene(
        story.storyId,
        root.nodeId,
        {
          '_storyTitle': event.title,
          '_synopsis': event.synopsis,
          'ttsText': event.narratorLine,
        },
        [
          for (final c in event.options)
            {'label': c.label, 'icon': c.icon, 'iconColor': c.iconColor},
        ],
      );
      _storySavedGeneration = storyGeneration;
      emit(
        state.copy(
          story: () => state.story!.copy(
            title: _storyEditGeneration == storyGeneration ? event.title : null,
            synopsis: _storyEditGeneration == storyGeneration
                ? event.synopsis
                : null,
          ),
          nodes: _mergeChanged(change.nodes),
          job: CreateJob.none,
          jobNodeId: () => null,
        ),
      );
    } on AppFailure catch (error) {
      emit(
        state.copy(
          job: CreateJob.none,
          jobNodeId: () => root.nodeId,
          failure: () => error.hint,
        ),
      );
    }
  }

  /// Explicit Apply flushes local edits, then overwrites reviewed fields and
  /// slots in one transaction. IDs, destinations, positions and defaults
  /// survive retries; missing slots create branches, never deletes.
  Future<void> _onSceneProposalApplied(
    SceneProposalApplied event,
    Emitter<CreateState> emit,
  ) async {
    final story = state.story;
    if (story == null || _node(event.nodeId) == null) {
      _completeProposal(event, false);
      return;
    }
    emit(
      state.copy(
        job: CreateJob.saving,
        jobNodeId: () => event.nodeId,
        failure: () => null,
      ),
    );
    try {
      if (!await _saveOpenNodeAwait(
        emit,
        nodeId: event.nodeId,
        finishJob: false,
        force: false,
      )) {
        _completeProposal(event, false);
        return;
      }
      final p = event.proposal;
      final change = await drafts.applyScene(
        story.storyId,
        event.nodeId,
        {
          'title': p.title,
          'ttsText': p.ttsText,
          'endingName': p.endingName,
          'startImagePrompt': p.startImagePrompt,
          'videoPrompt': p.videoPrompt,
        },
        [
          for (final c in p.choices)
            {'label': c.label, 'icon': c.icon, 'iconColor': c.iconColor},
        ],
      );
      if (isClosed || _closing.isCompleted) {
        _completeProposal(event, false);
        return;
      }
      emit(
        state.copy(
          nodes: _mergeChanged(change.nodes),
          job: CreateJob.none,
          jobNodeId: () => null,
          focusChoiceId: () => null,
        ),
      );
      _decideIcons(event.nodeId, event.proposal);
      _completeProposal(event, true);
    } on AppFailure catch (error) {
      if (!isClosed) {
        emit(
          state.copy(
            job: CreateJob.none,
            jobNodeId: () => event.nodeId,
            failure: () => error.hint,
          ),
        );
      }
      _completeProposal(event, false);
    }
  }

  void _completeProposal(SceneProposalApplied event, bool applied) {
    if (!(event.completion?.isCompleted ?? true)) {
      event.completion!.complete(applied);
    }
  }

  /// Fires one icon decision per unstyled choice, without awaiting: the
  /// user only sees icons at the Options step, so each answer merges when
  /// it lands via [ChoiceIconDecided]. Manual picks are set by then or
  /// win at merge time.
  void _decideIcons(String nodeId, SceneProposal proposal) {
    final story = state.story;
    if (story == null || isClosed) return;
    final node = _node(nodeId);
    if (node == null) return;
    final previous = _incomingLabel(node);
    for (final choice in node.choices) {
      if (!_needsIcon(choice)) continue;
      final label = choice.label.trim();
      if (label.isEmpty) continue;
      unawaited(
        _decideOneIcon(
          storyId: story.storyId,
          nodeId: nodeId,
          choiceId: choice.choiceId,
          label: label,
          siblings: [
            for (final other in node.choices)
              if (other.choiceId != choice.choiceId &&
                  other.label.trim().isNotEmpty)
                other.label.trim(),
          ],
          previousDecision: previous,
          sceneTitle: proposal.title,
          narratorLine: proposal.ttsText,
          videoPrompt: proposal.videoPrompt,
        ),
      );
    }
  }

  Future<void> _decideOneIcon({
    required String storyId,
    required String nodeId,
    required String choiceId,
    required String label,
    required List<String> siblings,
    required String? previousDecision,
    required String? sceneTitle,
    required String? narratorLine,
    required String? videoPrompt,
  }) async {
    try {
      final decided = await repository.decideChoiceIcon(
        storyId: storyId,
        nodeId: nodeId,
        choiceLabel: label,
        siblingLabels: siblings,
        previousDecision: previousDecision,
        sceneTitle: sceneTitle,
        narratorLine: narratorLine,
        videoPrompt: videoPrompt,
      );
      if (isClosed || _closing.isCompleted) return;
      if (decided.icon == null && decided.iconColor == null) return;
      add(
        ChoiceIconDecided(
          nodeId: nodeId,
          choiceId: choiceId,
          icon: decided.icon,
          iconColor: decided.iconColor,
        ),
      );
    } catch (_) {
      // Background styling never surfaces: the index fallback stays.
    }
  }

  /// True when a choice still needs a decision: no icon, or the link
  /// placeholder pair (`createAndLink` defaults). Anything else is a
  /// manual or earlier pick and must never be overwritten.
  bool _needsIcon(DraftChoice choice) {
    if (choice.icon == null) return true;
    if (choice.slot == 'A') {
      return choice.icon == 'compass' && choice.iconColor == 'cyan';
    }
    if (choice.slot == 'B') {
      return choice.icon == 'moon' && choice.iconColor == 'blue';
    }
    return false;
  }

  /// Label of the choice taken to reach [node], so the decision model
  /// knows where the scene comes from. Null for the root and orphans.
  String? _incomingLabel(DraftNode node) {
    final parent = state.parentOf(node);
    if (parent == null) return null;
    for (final choice in parent.choices) {
      if (choice.targetNodeId == node.nodeId &&
          choice.label.trim().isNotEmpty) {
        return choice.label.trim();
      }
    }
    return null;
  }

  void _onChoiceIconDecided(
    ChoiceIconDecided event,
    Emitter<CreateState> emit,
  ) {
    final node = _node(event.nodeId);
    if (node == null) return;
    final at = node.choices.indexWhere(
      (choice) => choice.choiceId == event.choiceId,
    );
    if (at < 0 || !_needsIcon(node.choices[at])) return;
    _markEdited(event.nodeId);
    emit(
      state.copy(
        nodes: [
          for (final current in state.nodes)
            if (current.nodeId == event.nodeId)
              current.copy(
                choices: [
                  for (var i = 0; i < current.choices.length; i++)
                    if (i == at)
                      current.choices[i].copy(
                        icon: event.icon,
                        iconColor: event.iconColor,
                      )
                    else
                      current.choices[i],
                ],
              )
            else
              current,
        ],
      ),
    );
    add(NodeSaved(nodeId: event.nodeId));
  }

  void _onFieldChanged(NodeFieldChanged event, Emitter<CreateState> emit) {
    final before = _node(event.nodeId);
    if (before == null) return;
    final after = _applyFields(before, event);
    final old = before.toJson(), next = after.toJson();
    final fields = [
      for (final key in next.keys)
        if (jsonEncode(old[key]) != jsonEncode(next[key])) key,
    ];
    if (fields.isEmpty) return;
    _markEdited(event.nodeId, fields: fields);
    _publishNode(after, emit);
  }

  /// Moves one choice zone, clamping to the 0-1 frame so the payload can
  /// never fail the `saveNode` zone check. Unknown nodes and choices are
  /// ignored.
  void _onZoneMoved(ZoneMoved event, Emitter<CreateState> emit) {
    if (!state.nodes.any((node) => node.nodeId == event.nodeId)) return;
    _markEdited(event.nodeId);
    emit(
      state.copy(
        nodes: [
          for (final node in state.nodes)
            if (node.nodeId == event.nodeId)
              node.copy(
                choices: [
                  for (final choice in node.choices)
                    if (choice.choiceId == event.choiceId)
                      choice.copy(
                        x: event.x.clamp(0, 1).toDouble(),
                        y: event.y.clamp(0, 1).toDouble(),
                      )
                    else
                      choice,
                ],
              )
            else
              node,
        ],
        failure: () => null,
        focusChoiceId: () => null,
      ),
    );
  }

  /// Adds a choice with a center-frame zone pointing at its target.
  /// Ignored on endings, past two choices, blank targets, and unknown
  /// nodes.
  void _onChoiceAdded(ChoiceAdded event, Emitter<CreateState> emit) {
    final target = event.targetNodeId.trim();
    if (target.isEmpty) return;
    final index = state.nodes.indexWhere((node) => node.nodeId == event.nodeId);
    if (index < 0) return;
    final linked = _linkChoice(state.nodes[index], target, null);
    if (linked == null) return;
    _markEdited(event.nodeId);
    emit(
      state.copy(
        nodes: [
          for (final current in state.nodes)
            if (current.nodeId == event.nodeId) linked else current,
        ],
        failure: () => null,
        focusChoiceId: () => null,
      ),
    );
  }

  /// Slot rank: unslotted legacy choices first (old drafts keep append
  /// order), then `A`, then `B`.
  int _slotRank(String? slot) => slot == 'A'
      ? 0
      : slot == 'B'
      ? 1
      : -1;

  /// Adds a blank choice pointing at [target] on [slot] (or the first free
  /// open slot when null, taken, cut, or invalid), inserted in slot order
  /// canvas puts the child exactly on the tapped mini. The sole choice
  /// carries the hold. Null on endings, past two choices, or with no
  /// free slot.
  DraftNode? _linkChoice(DraftNode node, String target, String? slot) {
    if (node.isEnding || node.choices.length >= 2) return null;
    final used = {for (final choice in node.choices) choice.slot};
    String? at;
    if ((slot == 'A' || slot == 'B') &&
        !used.contains(slot) &&
        // The first check narrowed slot to A/B; `==` cannot promote it.
        !node.isSlotCut(slot!)) {
      at = slot;
    } else {
      for (final candidate in node.openSlots) {
        if (!used.contains(candidate)) {
          at = candidate;
          break;
        }
      }
    }
    if (at == null) return null;
    final choice = DraftChoice(
      choiceId: const Uuid().v4(),
      label: '',
      targetNodeId: target,
      isDefault: node.choices.isEmpty,
      slot: at,
      x: DraftChoice.defaultXFor(at),
    );
    final next = [...node.choices];
    var index = next.length;
    for (var i = 0; i < next.length; i++) {
      if (_slotRank(next[i].slot) > _slotRank(at)) {
        index = i;
        break;
      }
    }
    next.insert(index, choice);
    return node.copy(choices: next);
  }

  /// Removes a choice and its zone. When the default goes and choices
  /// remain, the first survivor inherits the default so the checklist can
  /// still pass. Unknown nodes and choices are ignored.
  void _onChoiceRemoved(ChoiceRemoved event, Emitter<CreateState> emit) {
    final index = state.nodes.indexWhere((node) => node.nodeId == event.nodeId);
    if (index < 0) return;
    final node = state.nodes[index];
    if (!node.choices.any((choice) => choice.choiceId == event.choiceId)) {
      return;
    }
    var survivors = [
      for (final choice in node.choices)
        if (choice.choiceId != event.choiceId) choice,
    ];
    if (survivors.isNotEmpty &&
        survivors.every((choice) => !choice.isDefault)) {
      survivors = [survivors.first.copy(isDefault: true), ...survivors.skip(1)];
    }
    _markEdited(event.nodeId);
    emit(
      state.copy(
        nodes: [
          for (final current in state.nodes)
            if (current.nodeId == event.nodeId)
              current.copy(choices: survivors)
            else
              current,
        ],
        failure: () => null,
        focusChoiceId: () => null,
      ),
    );
  }

  /// Effective branch slot of [choice]: its slot when set, else the
  /// legacy position-derived slot. Mirrors persistence `_slot`.
  String _choiceSlot(DraftNode node, DraftChoice choice) {
    if (choice.slot == 'A' || choice.slot == 'B') return choice.slot!;
    final free = ['A', 'B']
      ..removeWhere((slot) => node.choices.any((c) => c.slot == slot));
    final legacy = node.choices
        .where((c) => c.slot != 'A' && c.slot != 'B')
        .toList();
    final index = legacy.indexOf(choice);
    return index >= 0 && index < free.length ? free[index] : '';
  }

  /// Toggles the cut mark on a branch. Cutting a slot that already holds
  /// a scene, or the last open slot, is rejected with a failure so the
  /// snack says why; uncutting is always allowed. Unknown nodes, endings,
  /// and invalid slots are ignored.
  void _onChoiceCutToggled(ChoiceCutToggled event, Emitter<CreateState> emit) {
    final slot = event.slot;
    if (slot != 'A' && slot != 'B') return;
    final index = state.nodes.indexWhere((node) => node.nodeId == event.nodeId);
    if (index < 0) return;
    final node = state.nodes[index];
    if (node.isEnding) return;
    final cut = {...node.cutSlots};
    if (cut.contains(slot)) {
      cut.remove(slot);
    } else {
      if (node.choices.any((c) => _choiceSlot(node, c) == slot)) {
        emit(state.copy(failure: () => 'That path already has a scene.'));
        return;
      }
      if (node.openSlots.length <= 1) {
        emit(state.copy(failure: () => 'One path must stay open.'));
        return;
      }
      cut.add(slot);
    }
    _markEdited(event.nodeId);
    emit(
      state.copy(
        nodes: [
          for (final current in state.nodes)
            if (current.nodeId == event.nodeId)
              current.copy(cutSlots: cut)
            else
              current,
        ],
        failure: () => null,
        focusChoiceId: () => null,
      ),
    );
  }

  /// Flips the final-node switch. Turning final on drops every Option
  /// and clears cut marks; turning it off reopens both slots. The UI
  /// confirms before sending `true` with Options present. Unknown nodes
  /// and no-op flips are ignored.
  void _onNodeEndingToggled(
    NodeEndingToggled event,
    Emitter<CreateState> emit,
  ) {
    final index = state.nodes.indexWhere((node) => node.nodeId == event.nodeId);
    if (index < 0) return;
    final node = state.nodes[index];
    if (node.isEnding == event.isEnding) return;
    final next = event.isEnding
        ? node.copy(isEnding: true, choices: const [], cutSlots: const {})
        : node.copy(isEnding: false);
    _markEdited(event.nodeId);
    emit(
      state.copy(
        nodes: [
          for (final current in state.nodes)
            if (current.nodeId == event.nodeId) next else current,
        ],
        failure: () => null,
        focusChoiceId: () => null,
      ),
    );
  }

  /// Restores the stored node + story docs over unsaved edits. Fetch
  /// failures leave the local edits in place: nothing is lost.
  Future<void> _onEditsDiscarded(
    EditsDiscarded event,
    Emitter<CreateState> emit,
  ) async {
    final story = state.story;
    if (story == null || isClosed) return;
    _editGeneration[event.nodeId] = _savedGeneration[event.nodeId] ?? 0;
    _dirtyFields.remove(event.nodeId);
    _storyEditGeneration = _storySavedGeneration;
    try {
      final fresh = await repository.fetchNode(story.storyId, event.nodeId);
      final draft = await repository.fetchDraft(story.storyId);
      if (isClosed || emit.isDone) return;
      emit(
        state.copy(
          nodes: fresh == null
              ? null
              : [
                  for (final node in state.nodes)
                    if (node.nodeId == fresh.nodeId) fresh else node,
                ],
          story: draft == null ? null : () => draft,
          stories: draft == null
              ? null
              : [
                  for (final entry in state.stories)
                    if (entry.storyId == draft.storyId) draft else entry,
                ],
          failure: () => null,
        ),
      );
    } on AppFailure {
      // Offline or gone: the unsaved edits stay put.
    }
  }

  Future<void> _onNodeSaved(NodeSaved event, Emitter<CreateState> emit) async {
    try {
      final saved = await _saveOpenNodeAwait(emit, nodeId: event.nodeId);
      if (!(event.completion?.isCompleted ?? true)) {
        event.completion!.complete(saved);
      }
    } catch (error, stack) {
      if (!(event.completion?.isCompleted ?? true)) {
        event.completion!.completeError(error, stack);
      }
      rethrow;
    }
  }

  Future<void> _onStorySaved(
    StorySaved event,
    Emitter<CreateState> emit,
  ) async {
    try {
      final saved = await _saveStoryAwait(emit);
      if (!(event.completion?.isCompleted ?? true)) {
        event.completion!.complete(saved);
      }
    } catch (error, stack) {
      if (!(event.completion?.isCompleted ?? true)) {
        event.completion!.completeError(error, stack);
      }
      rethrow;
    }
  }

  /// Flush the latest story revision, optionally keeping the enclosing
  /// cover job busy through the generation call.
  Future<bool> _saveStoryAwait(
    Emitter<CreateState> emit, {
    bool finishJob = true,
  }) async {
    final story = state.story;
    if (story == null) return true;
    emit(
      state.copy(
        job: CreateJob.saving,
        jobNodeId: () => null,
        failure: () => null,
      ),
    );
    try {
      await _persistStory();
      if (isClosed) return false;
      if (finishJob) {
        emit(
          state.copy(
            job: CreateJob.none,
            jobNodeId: () => null,
            failure: () => null,
          ),
        );
      }
      return true;
    } on AppFailure catch (error) {
      if (isClosed) return false;
      emit(
        state.copy(
          job: CreateJob.none,
          jobNodeId: () => null,
          failure: () => error.hint,
        ),
      );
      return false;
    }
  }

  /// Asks for the story key art, then points the story at the returned
  /// URL. Display + dispatch only: generation runs server-side. Pending
  /// name/description edits flush first so the cover prompt reads them;
  /// a failed flush aborts with its failure.
  Future<void> _onCoverGenerate(
    CoverGenerateRequested event,
    Emitter<CreateState> emit,
  ) async {
    final story = state.story;
    if (story == null) return;
    emit(
      state.copy(
        operationKind: 'cover',
        operationPhase: 'saving',
        job: CreateJob.imaging,
        jobNodeId: () => null,
      ),
    );
    final flushed = await _saveStoryAwait(emit, finishJob: false);
    if (!flushed || isClosed) return;
    final freshStory = state.story;
    if (freshStory == null) return;
    emit(
      state.copy(
        operationPhase: 'generating',
        job: CreateJob.imaging,
        jobNodeId: () => null,
        failure: () => null,
      ),
    );
    try {
      final url = await repository.generateStoryCover(
        storyId: freshStory.storyId,
        prompt: event.prompt,
      );
      if (isClosed || _closing.isCompleted) return;
      final current = state.story;
      if (current == null) return;
      final next = url == null ? current : current.copy(coverUrl: () => url);
      emit(
        state.copy(
          story: () => next,
          stories: [
            for (final entry in state.stories)
              if (entry.storyId == next.storyId) next else entry,
          ],
          job: CreateJob.none,
          jobNodeId: () => null,
          failure: () => null,
        ),
      );
    } on AppFailure catch (error) {
      emit(
        state.copy(
          job: CreateJob.none,
          jobNodeId: () => null,
          failure: () => error.hint,
        ),
      );
    }
  }

  /// Zones ride the `choices` whitelist inside the full node doc, so
  /// saving zones is saving the open node.
  Future<void> _onZonesSaved(ZonesSaved event, Emitter<CreateState> emit) {
    return _saveOpenNodeAwait(emit);
  }

  /// Asks for the node voice, then reloads the nodes so the take status
  /// shows up. The backend enforces the non-blank-line gate; a rejection
  /// lands as [failure].
  Future<void> _onVoiceGenerate(
    VoiceGenerateRequested event,
    Emitter<CreateState> emit,
  ) async {
    await _runImaging(
      emit,
      event.nodeId,
      () => repository.generateNodeVoice(
        storyId: state.story!.storyId,
        nodeId: event.nodeId,
      ),
    );
  }

  /// Flush the latest author revision, optionally keeping the enclosing
  /// Apply/media job busy through its subsequent reload.
  Future<bool> _saveOpenNodeAwait(
    Emitter<CreateState> emit, {
    String? nodeId,
    bool finishJob = true,
    bool force = true,
  }) async {
    final story = state.story;
    final targetId = nodeId ?? state.openNodeId;
    if (story == null || targetId == null || _node(targetId) == null) {
      return true;
    }
    emit(
      state.copy(
        job: CreateJob.saving,
        jobNodeId: () => targetId,
        failure: () => null,
      ),
    );
    try {
      await _persistStory();
      await _persistNode(story.storyId, targetId, force: force);
      if (isClosed) return false;
      if (finishJob) {
        emit(
          state.copy(
            job: CreateJob.none,
            jobNodeId: () => null,
            failure: () => null,
          ),
        );
      }
      return true;
    } on AppFailure catch (error) {
      if (isClosed) return false;
      emit(
        state.copy(
          job: CreateJob.none,
          jobNodeId: () => targetId,
          failure: () => error.hint,
        ),
      );
      return false;
    }
  }

  /// Deletes the open node client-direct, then drops it locally so
  /// the canvas drops it. The transaction guards the root and targeted
  /// nodes; a rejection lands as [CreateState.failure] and nothing is
  /// removed. When the open node is gone, the root reopens (or the first
  /// survivor).
  Future<void> _onNodeDeleted(
    NodeDeleted event,
    Emitter<CreateState> emit,
  ) async {
    final story = state.story;
    final node = state.openNode;
    if (story == null || node == null) return;
    final nodeId = node.nodeId;
    emit(
      state.copy(
        job: CreateJob.saving,
        jobNodeId: () => nodeId,
        failure: () => null,
      ),
    );
    try {
      await drafts.delete(story.storyId, nodeId);
      final nodes = state.nodes.where((n) => n.nodeId != nodeId).toList();
      var open = state.openNodeId;
      if (!nodes.any((current) => current.nodeId == open)) {
        final root = story.rootNodeId;
        open = nodes.any((current) => current.nodeId == root)
            ? root
            : (nodes.isEmpty ? null : nodes.first.nodeId);
      }
      emit(
        state.copy(
          nodes: nodes,
          openNodeId: () => open,
          job: CreateJob.none,
          jobNodeId: () => null,
          failure: () => null,
        ),
      );
    } on AppFailure catch (error) {
      emit(
        state.copy(
          job: CreateJob.none,
          jobNodeId: () => nodeId,
          failure: () => error.hint,
        ),
      );
    }
  }

  /// Publishes the draft through the client publisher. A returned missing
  /// list becomes [CreateState.failure] (nothing was written); an empty
  /// list marks [CreateState.publishedStoryId] and the view leaves for
  /// Explore. Transport rejections land as their phrase.
  Future<void> _onStoryPublished(
    StoryPublished event,
    Emitter<CreateState> emit,
  ) async {
    final story = state.story;
    if (story == null) return;
    if (hasUnsavedStoryEdits ||
        state.nodes.any((node) => _isDirty(node.nodeId))) {
      emit(state.copy(failure: () => 'Save your changes before publishing.'));
      return;
    }
    emit(
      state.copy(
        job: CreateJob.saving,
        jobNodeId: () => null,
        failure: () => null,
      ),
    );
    try {
      final service = publisher;
      if (service == null) {
        throw const AppFailure(
          .failed,
          detail: 'Publication persistence is not configured.',
        );
      }
      final missing = await service.publish(story.storyId);
      if (missing.isNotEmpty) {
        emit(
          state.copy(
            job: CreateJob.none,
            jobNodeId: () => null,
            failure: () => missing.join('\n'),
          ),
        );
        return;
      }
      emit(
        state.copy(
          job: CreateJob.none,
          jobNodeId: () => null,
          failure: () => null,
          publishedStoryId: () => story.storyId,
          stories: [
            for (final entry in state.stories)
              if (entry.storyId == story.storyId)
                entry.copy(status: 'published')
              else
                entry,
          ],
        ),
      );
    } on AppFailure catch (error) {
      emit(
        state.copy(
          job: CreateJob.none,
          jobNodeId: () => null,
          failure: () => error.hint,
        ),
      );
    }
  }

  /// Hides the open published story: `status` returns to `draft`, so
  /// every player read rule stops matching and Publish offers again.
  /// The local copy mirrors the direct write; the list entry follows.
  Future<void> _onStoryUnpublished(
    StoryUnpublished event,
    Emitter<CreateState> emit,
  ) async {
    final story = state.story;
    if (story == null) return;
    emit(
      state.copy(
        job: CreateJob.saving,
        jobNodeId: () => null,
        failure: () => null,
      ),
    );
    try {
      await drafts.unpublishStory(story.storyId);
      if (isClosed) return;
      emit(
        state.copy(
          job: CreateJob.none,
          jobNodeId: () => null,
          failure: () => null,
          story: () => story.copy(status: 'draft'),
          stories: [
            for (final entry in state.stories)
              if (entry.storyId == story.storyId)
                entry.copy(status: 'draft')
              else
                entry,
          ],
        ),
      );
    } on AppFailure catch (error) {
      emit(
        state.copy(
          job: CreateJob.none,
          jobNodeId: () => null,
          failure: () => error.hint,
        ),
      );
    }
  }

  /// Deletes the open draft story doc: the canvas clears, the watcher
  /// stops, and [CreateState.deletedStoryId] sends the view back to the
  /// creations list. Nodes and publications stay as unreachable orphans.
  Future<void> _onStoryDeleted(
    StoryDeleted event,
    Emitter<CreateState> emit,
  ) async {
    final story = state.story;
    if (story == null) return;
    emit(
      state.copy(
        job: CreateJob.saving,
        jobNodeId: () => null,
        failure: () => null,
      ),
    );
    try {
      await drafts.deleteStory(story.storyId);
      if (isClosed) return;
      unawaited(_draftSubscription?.cancel());
      _draftSubscription = null;
      emit(
        CreateState(
          stories: [
            for (final entry in state.stories)
              if (entry.storyId != story.storyId) entry,
          ],
          deletedStoryId: story.storyId,
        ),
      );
    } on AppFailure catch (error) {
      emit(
        state.copy(
          job: CreateJob.none,
          jobNodeId: () => null,
          failure: () => error.hint,
        ),
      );
    }
  }

  Future<void> _onNarrationGenerate(
    NarrationGenerateRequested event,
    Emitter<CreateState> emit,
  ) async {
    final story = state.story;
    if (story == null || _node(event.nodeId) == null) return;
    emit(
      state.copy(
        operationKind: 'text',
        operationPhase: 'saving',
        job: CreateJob.saving,
        jobNodeId: () => event.nodeId,
      ),
    );
    final flushed = await _saveOpenNodeAwait(
      emit,
      nodeId: event.nodeId,
      finishJob: false,
      force: false,
    );
    if (!flushed || isClosed) return;
    emit(
      state.copy(
        job: CreateJob.generating,
        operationPhase: 'generating',
        failure: () => null,
      ),
    );
    try {
      final proposal = await repository.generateNodeText(
        storyId: story.storyId,
        nodeId: event.nodeId,
        purpose: 'narration',
      );
      if (isClosed || _closing.isCompleted) return;
      final node = _node(event.nodeId);
      final line = proposal.ttsText?.trim() ?? '';
      if (node == null || line.isEmpty) throw const AppFailure(.invalid);
      _markEdited(
        event.nodeId,
        fields: const [
          'ttsText',
          'ttsStatus',
          'ttsAudioUrl',
          'ttsDurationSeconds',
        ],
      );
      _publishNode(
        _applyFields(
          node,
          NodeFieldChanged(nodeId: event.nodeId, ttsText: line),
        ),
        emit,
      );
      await _persistNode(story.storyId, event.nodeId);
      if (isClosed || _closing.isCompleted) return;
      emit(state.copy(job: CreateJob.none, jobNodeId: () => null));
    } on AppFailure catch (error) {
      if (isClosed || _closing.isCompleted) return;
      emit(
        state.copy(
          job: CreateJob.none,
          jobNodeId: () => event.nodeId,
          failure: () => error.hint,
        ),
      );
    }
  }

  Future<void> _onGenerate(
    TextGenerateRequested event,
    Emitter<CreateState> emit,
  ) async {
    final story = state.story;
    final node = state.openNode;
    if (story == null || node == null) return;
    // Flush pending manual edits first: the later reload must not drop
    // them. A failed flush aborts the generation with its failure.
    final flushed = await _saveOpenNodeAwait(
      emit,
      finishJob: false,
      force: false,
    );
    if (!flushed || isClosed) return;
    final freshStory = state.story;
    final freshNode = state.openNode;
    if (freshStory == null || freshNode == null) return;
    emit(
      state.copy(
        job: CreateJob.generating,
        jobNodeId: () => freshNode.nodeId,
        failure: () => null,
      ),
    );
    try {
      final proposal = await repository.generateNodeText(
        storyId: freshStory.storyId,
        nodeId: freshNode.nodeId,
        prompt: event.prompt,
      );
      if (isClosed || _closing.isCompleted) return;
      final targetId = freshNode.nodeId;
      _markEdited(
        targetId,
        fields: const [
          'title',
          'ttsText',
          'endingName',
          'choices',
          'ttsStatus',
          'ttsAudioUrl',
          'ttsDurationSeconds',
        ],
      );
      emit(
        state.copy(
          nodes: [
            for (final current in state.nodes)
              if (current.nodeId == targetId)
                _applyProposal(current, proposal, event.regenerate)
              else
                current,
          ],
          job: CreateJob.none,
          jobNodeId: () => null,
          failure: () => null,
        ),
      );
    } on AppFailure catch (error) {
      if (isClosed || _closing.isCompleted) return;
      emit(
        state.copy(
          job: CreateJob.none,
          jobNodeId: () => freshNode.nodeId,
          failure: () => error.hint,
        ),
      );
    }
  }

  /// Asks for one node frame, then reloads the nodes so the resulting
  /// status shows up. Display + dispatch only: generation runs server-side.
  Future<void> _onImageGenerate(
    ImageGenerateRequested event,
    Emitter<CreateState> emit,
  ) async {
    await _runImaging(
      emit,
      event.nodeId,
      () => repository.generateNodeImage(
        storyId: state.story!.storyId,
        nodeId: event.nodeId,
        which: event.which,
        prompt: event.prompt,
      ),
      kind: '${event.which}Image',
    );
  }

  /// Asks for the node video (inheriting the parent clip's last frame
  /// as S), then reloads the nodes so the job status shows up. The backend
  /// enforces the ready-frame gate; a rejection lands as [failure]. When the
  /// backend reports the job still running, this re-asks until it reports
  /// done or [maxVideoPolls] is hit: the backend resumes the same stored
  /// job, so polls never bill a duplicate. Unknown nodes and missing
  /// drafts are ignored, exactly like [_runImaging].
  Future<void> _onVideoGenerate(
    VideoGenerateRequested event,
    Emitter<CreateState> emit,
  ) async {
    final story = state.story;
    if (story == null) return;
    if (!state.nodes.any((node) => node.nodeId == event.nodeId)) return;
    emit(
      state.copy(
        operationKind: 'video',
        operationPhase: 'saving',
        job: CreateJob.imaging,
        jobNodeId: () => event.nodeId,
      ),
    );
    // Flush pending manual edits first so the post-generate reload keeps
    // the revised prompt. A failed flush aborts with its failure.
    final flushed = await _saveOpenNodeAwait(
      emit,
      finishJob: false,
      force: false,
    );
    if (!flushed || isClosed) return;
    final freshStory = state.story;
    if (freshStory == null) return;
    if (!state.nodes.any((node) => node.nodeId == event.nodeId)) return;
    emit(
      state.copy(
        operationPhase: 'generating',
        job: CreateJob.imaging,
        jobNodeId: () => event.nodeId,
        failure: () => null,
      ),
    );
    try {
      var poll = await repository.generateNodeVideo(
        storyId: freshStory.storyId,
        nodeId: event.nodeId,
        prompt: event.prompt,
      );
      await _refreshNode(freshStory.storyId, event.nodeId, emit);
      var nodes = state.nodes;
      var polls = 0;
      while (poll && polls < maxVideoPolls) {
        polls++;
        // Live nodes while waiting: a backend-written `ready` shows
        // through once the poll that observed it lands.
        emit(state.copy(nodes: _mergeReload(nodes)));
        await Future.any([
          Future<void>.delayed(videoPollInterval),
          _closing.future,
        ]);
        if (isClosed || _closing.isCompleted) return;
        poll = await repository.generateNodeVideo(
          storyId: freshStory.storyId,
          nodeId: event.nodeId,
          prompt: event.prompt,
        );
        await _refreshNode(freshStory.storyId, event.nodeId, emit);
        nodes = state.nodes;
      }
      if (poll) {
        emit(
          state.copy(
            nodes: _mergeReload(nodes),
            job: CreateJob.none,
            jobNodeId: () => event.nodeId,
            failure: () => 'Video is still processing. Tap Continue generation to resume this job.',
          ),
        );
        return;
      }
      emit(
        state.copy(
          nodes: _mergeReload(nodes),
          job: CreateJob.none,
          jobNodeId: () => null,
          failure: () => null,
        ),
      );
    } on AppFailure catch (error) {
      emit(
        state.copy(
          job: CreateJob.none,
          jobNodeId: () => event.nodeId,
          failure: () => error.hint,
        ),
      );
    }
  }

  /// Shared imaging runner: unknown nodes and missing drafts are ignored,
  /// the job pill runs while the call is in flight, and the nodes reload
  /// after so server-side status is the source of truth.
  Future<void> _runImaging(
    Emitter<CreateState> emit,
    String nodeId,
    Future<void> Function() call, {
    bool saveEdits = true,
    String kind = 'voice',
  }) async {
    final story = state.story;
    if (story == null) return;
    if (!state.nodes.any((node) => node.nodeId == nodeId)) return;
    emit(
      state.copy(
        operationKind: kind,
        operationPhase: saveEdits ? 'saving' : 'generating',
        job: CreateJob.imaging,
        jobNodeId: () => nodeId,
      ),
    );
    // Flush pending manual edits first so the post-call reload keeps
    // them. A failed flush aborts with its failure.
    if (saveEdits) {
      final flushed = await _saveOpenNodeAwait(
        emit,
        nodeId: nodeId,
        finishJob: false,
        force: false,
      );
      if (!flushed || isClosed) return;
    }
    final freshStory = state.story;
    if (freshStory == null) return;
    if (!state.nodes.any((node) => node.nodeId == nodeId)) return;
    emit(
      state.copy(
        operationPhase: 'generating',
        job: CreateJob.imaging,
        jobNodeId: () => nodeId,
        failure: () => null,
      ),
    );
    try {
      await call();
      if (isClosed || _closing.isCompleted) return;
      await _refreshNode(freshStory.storyId, nodeId, emit);
      final nodes = state.nodes;
      emit(
        state.copy(
          nodes: _mergeReload(nodes),
          job: CreateJob.none,
          jobNodeId: () => null,
          failure: () => null,
        ),
      );
    } on AppFailure catch (error) {
      emit(
        state.copy(
          job: CreateJob.none,
          jobNodeId: () => nodeId,
          failure: () => error.hint,
        ),
      );
    }
  }

  /// Uploads a picked video, then holds `uploading` until the trigger's
  /// own write is observed. Unknown nodes and missing drafts are ignored;
  /// a blank uid fails without touching the network. The client-side
  /// pre-check ([validateVideoUpload]) rejects bad types and oversize
  /// files before any byte goes up. After the put, the bloc polls the
  /// trigger-written marker until its `uploadTakeId` echo matches this
  /// take — the trigger lands seconds later, so resolving on the first
  /// read would bless pre-trigger state. Only the echoed take resolves:
  /// its `uploadError` becomes the failure phrase (null means the node
  /// video is the trigger's). The poll is bounded ([maxUploadPolls] ×
  /// [uploadPollInterval]); exhaustion fails closed. Node fields stay
  /// exactly what the backend wrote throughout.
  Future<void> _onVideoUpload(
    VideoUploadRequested event,
    Emitter<CreateState> emit,
  ) async {
    final story = state.story;
    if (story == null) return;
    if (!state.nodes.any((node) => node.nodeId == event.nodeId)) return;
    final uid = auth?.auth.currentIdentity?.uid.trim() ?? '';
    if (uid.isEmpty) {
      emit(state.copy(failure: () => const AppFailure(.invalid).phrase));
      return;
    }
    final rejected = validateVideoUpload(
      contentType: event.contentType,
      byteLength: event.bytes.length,
    );
    if (rejected != null) {
      emit(
        state.copy(
          job: CreateJob.none,
          jobNodeId: () => event.nodeId,
          failure: () => rejected,
        ),
      );
      return;
    }
    emit(
      state.copy(
        operationKind: 'video',
        operationPhase: 'saving',
        job: CreateJob.saving,
        jobNodeId: () => event.nodeId,
      ),
    );
    final flushed = await _saveOpenNodeAwait(
      emit,
      nodeId: event.nodeId,
      finishJob: false,
      force: false,
    );
    if (!flushed || isClosed) return;
    final takeId = event.takeId?.trim().isNotEmpty == true
        ? event.takeId!.trim()
        : const Uuid().v4();
    emit(
      state.copy(
        operationKind: 'video',
        operationPhase: 'uploading',
        job: CreateJob.uploading,
        jobNodeId: () => event.nodeId,
        uploadProgress: () => 0,
        failure: () => null,
      ),
    );
    try {
      await repository.uploadNodeVideo(
        uid: uid,
        storyId: story.storyId,
        nodeId: event.nodeId,
        takeId: takeId,
        contentType: event.contentType,
        bytes: event.bytes,
        onProgress: (progress) => add(
          VideoUploadProgressed(nodeId: event.nodeId, progress: progress),
        ),
      );
      // Bytes are up; the trigger has not run yet. Bytes done, outcome
      // unknown: pin progress at full while the job keeps running.
      emit(state.copy(uploadProgress: () => 1, operationPhase: 'processing'));
      await _refreshNode(story.storyId, event.nodeId, emit);
      var nodes = state.nodes;
      var marker = await repository.fetchUploadMarker(
        storyId: story.storyId,
        nodeId: event.nodeId,
      );
      var polls = 0;
      while (marker.takeId != takeId && polls < maxUploadPolls) {
        polls++;
        await Future.any([
          Future<void>.delayed(uploadPollInterval),
          _closing.future,
        ]);
        if (isClosed || _closing.isCompleted) return;
        await _refreshNode(story.storyId, event.nodeId, emit);
        nodes = state.nodes;
        marker = await repository.fetchUploadMarker(
          storyId: story.storyId,
          nodeId: event.nodeId,
        );
        debugPrint(
          'upload poll: $polls/$maxUploadPolls take=$takeId '
          'marker=${marker.takeId} error=${marker.error} '
          'detail=${marker.detail}',
        );
        // Live nodes while waiting: a trigger-written `pending` shows
        // through the running pill once the echo is close.
        emit(state.copy(nodes: _mergeReload(nodes)));
      }
      debugPrint(
        'upload poll: resolved take=$takeId marker=${marker.takeId} '
        'error=${marker.error} detail=${marker.detail} polls=$polls',
      );
      if (marker.takeId != takeId) {
        emit(
          state.copy(
            nodes: nodes,
            job: CreateJob.none,
            jobNodeId: () => event.nodeId,
            uploadProgress: () => null,
            failure: () => const AppFailure(.failed).phrase,
          ),
        );
        return;
      }
      emit(
        state.copy(
          nodes: nodes,
          job: CreateJob.none,
          jobNodeId: () => marker.error == null ? null : event.nodeId,
          uploadProgress: () => null,
          failure: () =>
              marker.error == null ? null : _uploadErrorPhrase(marker.error!),
        ),
      );
    } on AppFailure catch (error) {
      emit(
        state.copy(
          job: CreateJob.none,
          jobNodeId: () => event.nodeId,
          uploadProgress: () => null,
          failure: () => error.hint,
        ),
      );
    }
  }

  /// Applies an upload progress tick while that node's upload runs.
  void _onVideoUploadProgressed(
    VideoUploadProgressed event,
    Emitter<CreateState> emit,
  ) {
    if (state.job != CreateJob.uploading) return;
    if (state.jobNodeId != event.nodeId) return;
    emit(state.copy(uploadProgress: () => event.progress.clamp(0, 1)));
  }
}

/// Manual edits win: the proposal fills a field only when it is empty,
/// unless [regenerate] explicitly asks to overwrite.
DraftNode _applyProposal(
  DraftNode node,
  GeneratedNodeText proposal,
  bool regenerate,
) {
  final title = proposal.title;
  final line = proposal.ttsText;
  final ending = proposal.endingName;
  var choices = node.choices;
  if (proposal.choiceLabels.isNotEmpty) {
    choices = [
      for (var i = 0; i < choices.length; i++)
        if (i < proposal.choiceLabels.length &&
            (regenerate || choices[i].label.trim().isEmpty))
          choices[i].copy(label: proposal.choiceLabels[i])
        else
          choices[i],
    ];
  }
  return node.copy(
    title: title != null && (regenerate || node.title.trim().isEmpty)
        ? title
        : null,
    ttsText: line != null && (regenerate || node.ttsText.trim().isEmpty)
        ? line
        : null,
    endingName:
        node.isEnding &&
            ending != null &&
            (regenerate || (node.endingName?.trim().isEmpty ?? true))
        ? () => ending
        : null,
    choices: choices,
  );
}

DraftNode _applyFields(DraftNode node, NodeFieldChanged event) {
  var next = node;
  if (event.title != null) next = next.copy(title: event.title);
  if (event.ttsText != null) {
    final changed = event.ttsText!.trim() != node.ttsText.trim();
    next = next.copy(
      ttsText: event.ttsText,
      ttsStatus: changed ? 'idle' : null,
      ttsAudioUrl: changed ? () => null : null,
      ttsDurationSeconds: changed ? () => null : null,
    );
  }
  if (event.visibility != null) {
    next = next.copy(visibility: event.visibility);
  }
  if (event.startImagePrompt != null) {
    final cleaned = event.startImagePrompt!.trim();
    next = next.copy(startImagePrompt: () => cleaned.isEmpty ? null : cleaned);
  }
  if (event.videoPrompt != null) {
    final cleaned = event.videoPrompt!.trim();
    next = next.copy(videoPrompt: () => cleaned.isEmpty ? null : cleaned);
  }
  if (event.endingName != null) {
    final cleaned = event.endingName!.trim();
    next = next.copy(endingName: () => cleaned.isEmpty ? null : cleaned);
  }
  if (event.sceneDirection != null) {
    final cleaned = event.sceneDirection!.trim();
    next = next.copy(sceneDirection: () => cleaned.isEmpty ? null : cleaned);
  }
  final labels = event.choiceLabels;
  if (labels != null && labels.isNotEmpty) {
    next = next.copy(
      choices: [
        for (final choice in next.choices)
          labels.containsKey(choice.choiceId)
              ? choice.copy(label: labels[choice.choiceId])
              : choice,
      ],
    );
  }
  final icons = event.choiceIcons;
  if (icons != null && icons.isNotEmpty) {
    next = next.copy(
      choices: [
        for (final choice in next.choices)
          icons.containsKey(choice.choiceId)
              ? choice.copy(icon: icons[choice.choiceId])
              : choice,
      ],
    );
  }
  final iconColors = event.choiceIconColors;
  if (iconColors != null && iconColors.isNotEmpty) {
    next = next.copy(
      choices: [
        for (final choice in next.choices)
          iconColors.containsKey(choice.choiceId)
              ? choice.copy(iconColor: iconColors[choice.choiceId])
              : choice,
      ],
    );
  }
  return next;
}

/// The phrase for a trigger-recorded `uploadError` code (backend contract:
/// `invalid-type` | `too-large` | `unknown-target` | `not-author` |
/// `not-draft` | `encode-failed`, plus `encode-unavailable` while the node
/// sits at `pending` without an encoder). Unknown codes fail closed.
String _uploadErrorPhrase(String code) {
  return switch (code) {
    'invalid-type' => 'Only mp4 or mov videos can be uploaded.',
    'too-large' => 'Videos must be 10 MB or smaller.',
    'unknown-target' => const AppFailure(.invalid).phrase,
    'not-author' || 'not-draft' => const AppFailure(.denied).phrase,
    'encode-unavailable' => 'Video encoding is unavailable',
    _ => const AppFailure(.failed).phrase,
  };
}
