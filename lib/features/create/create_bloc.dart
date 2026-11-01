import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:bloc_concurrency/bloc_concurrency.dart';
import 'package:ramifica/data/models/app_failure.dart';
import 'package:ramifica/data/models/draft_node.dart';
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
    this.auth,
    this.uploadPollInterval = const Duration(seconds: 2),
    this.maxUploadPolls = 30,
    this.videoPollInterval = const Duration(seconds: 10),
    this.maxVideoPolls = 40,
  }) : super(const CreateState()) {
    on<DraftRequested>(_onDraftRequested, transformer: restartable());
    on<DraftOpened>(_onDraftOpened, transformer: restartable());
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
    on<NodeFieldChanged>(_onFieldChanged);
    on<NodeSaved>(_serialized(_onNodeSaved));
    on<NodeDeleted>(_serialized(_onNodeDeleted), transformer: droppable());
    on<StoryPublished>(
      _serialized(_onStoryPublished),
      transformer: droppable(),
    );
    on<ZonesSaved>(_serialized(_onZonesSaved), transformer: droppable());
    on<ZoneMoved>(_onZoneMoved);
    on<ChoiceAdded>(_onChoiceAdded);
    on<ChoiceRemoved>(_onChoiceRemoved);
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
    on<ImageApprovalChanged>(
      _serialized(_onImageApproval),
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
  final AuthRepository? auth;

  /// Local edit generation per node: bumped on every state-only edit so
  /// a stale save confirmation never marks newer edits as persisted.
  /// The view keeps its own dirty flag; the bloc uses this to avoid
  /// clobbering concurrent edits when a save + reload overlaps them.
  final Map<String, int> _editGeneration = {};

  void _markEdited(String nodeId) {
    if (nodeId.isEmpty) return;
    _editGeneration[nodeId] = (_editGeneration[nodeId] ?? 0) + 1;
  }

  final Map<String, int> _savedGeneration = {};
  Future<void> _operationTail = Future<void>.value();
  StreamSubscription<List<DraftNode>>? _draftSubscription;
  final _closing = Completer<void>();

  void _watch(String storyId) {
    unawaited(_draftSubscription?.cancel());
    _draftSubscription = repository
        .watchNodes(storyId)
        .listen(
          (nodes) {
            if (!isClosed && !_closing.isCompleted)
              add(DraftNodesObserved(storyId, nodes));
          },
          onError: (Object error) {
            if (!isClosed && !_closing.isCompleted)
              add(DraftNodesObserved(storyId, const [], error: error));
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
                ...nodeSavePatch(local, node.ttsText),
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
      await repository.saveNode(storyId: storyId, node: snapshot);
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
      final created = await repository.createDraft(
        authorId: author,
        title: event.title,
      );
      emit(
        CreateState(
          story: created.$1,
          nodes: [created.$2],
          openNodeId: created.$2.nodeId,
        ),
      );
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
      emit(CreateState(story: story, nodes: nodes, openNodeId: open));
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
      final change = await repository.createAndLink(
        storyId: story.storyId,
        parentNodeId: parent.nodeId,
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
    if (story == null || parent == null || !['A', 'B'].contains(event.slot))
      return;
    emit(
      state.copy(
        job: CreateJob.saving,
        jobNodeId: () => parent.nodeId,
        failure: () => null,
      ),
    );
    try {
      await _persistNode(story.storyId, parent.nodeId);
      final change = await repository.createAndLink(
        storyId: story.storyId,
        parentNodeId: parent.nodeId,
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
      final change = await repository.persistence.applyScene(
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
      emit(
        state.copy(
          story: () => story.copy(title: event.title, synopsis: event.synopsis),
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

  /// Explicit Apply flushes local edits, then fills empty fields and slots in
  /// one transaction. IDs, destinations, positions and defaults survive retries.
  Future<void> _onSceneProposalApplied(
    SceneProposalApplied event,
    Emitter<CreateState> emit,
  ) async {
    final story = state.story;
    if (story == null || _node(event.nodeId) == null) return;
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
      ))
        return;
      final p = event.proposal;
      final proposal = GeneratedNodeText(
        title: p.title,
        ttsText: p.ttsText,
        endingName: p.endingName,
        startImagePrompt: p.startImagePrompt,
        endImagePrompt: p.endImagePrompt,
        videoPrompt: p.videoPrompt,
        choices: [
          for (final c in p.choices)
            GeneratedChoice(
              label: c.label,
              icon: c.icon,
              iconColor: c.iconColor,
            ),
        ],
      );
      final change = await repository.applyScene(
        storyId: story.storyId,
        nodeId: event.nodeId,
        proposal: proposal,
      );
      if (isClosed || _closing.isCompleted) return;
      emit(
        state.copy(
          nodes: _mergeChanged(change.nodes),
          job: CreateJob.none,
          jobNodeId: () => null,
          focusChoiceId: () => null,
        ),
      );
    } on AppFailure catch (error) {
      if (!isClosed)
        emit(
          state.copy(
            job: CreateJob.none,
            jobNodeId: () => event.nodeId,
            failure: () => error.hint,
          ),
        );
    }
  }

  void _onFieldChanged(NodeFieldChanged event, Emitter<CreateState> emit) {
    if (!state.nodes.any((node) => node.nodeId == event.nodeId)) return;
    _markEdited(event.nodeId);
    emit(
      state.copy(
        nodes: [
          for (final node in state.nodes)
            if (node.nodeId == event.nodeId)
              _applyFields(node, event)
            else
              node,
        ],
        failure: () => null,
        focusChoiceId: () => null,
      ),
    );
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
  /// slot when null, taken, or invalid), inserted in slot order so the
  /// canvas puts the child exactly on the tapped mini. The sole choice
  /// carries the hold. Null on endings, past two choices, or with no
  /// free slot.
  DraftNode? _linkChoice(DraftNode node, String target, String? slot) {
    if (node.isEnding || node.choices.length >= 2) return null;
    final used = {for (final choice in node.choices) choice.slot};
    String? at;
    if ((slot == 'A' || slot == 'B') && !used.contains(slot)) {
      at = slot;
    } else {
      for (final candidate in const ['A', 'B']) {
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

  /// Zones ride the `choices` whitelist inside the full node doc, so
  /// saving zones is saving the open node.
  Future<void> _onZonesSaved(ZonesSaved event, Emitter<CreateState> emit) {
    return _saveOpenNodeAwait(emit);
  }

  /// Asks for the node voice, then reloads the nodes so the take status
  /// (and its reset approval) shows up. The backend enforces the
  /// line-approval gate; a rejection lands as [failure].
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

  /// Deletes the open node through `deleteNode`, then reloads the nodes so
  /// the canvas drops it. The server guards the root and targeted nodes;
  /// a rejection lands as [CreateState.failure] and nothing is removed.
  /// When the open node is gone, the root reopens (or the first survivor).
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
      await repository.deleteNode(storyId: story.storyId, nodeId: nodeId);
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

  /// Publishes the draft through `publishStory`. A returned missing list
  /// becomes [CreateState.failure] (the server changed nothing); an empty
  /// list marks [CreateState.publishedStoryId] and the view leaves for
  /// Explore. Transport rejections land as their phrase.
  Future<void> _onStoryPublished(
    StoryPublished event,
    Emitter<CreateState> emit,
  ) async {
    final story = state.story;
    if (story == null) return;
    if (state.nodes.any((node) => _isDirty(node.nodeId))) {
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
      final missing = await repository.publishStory(storyId: story.storyId);
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
    final flushed = await _saveOpenNodeAwait(
      emit,
      nodeId: event.nodeId,
      finishJob: false,
      force: false,
    );
    if (!flushed || isClosed) return;
    emit(state.copy(job: CreateJob.generating, failure: () => null));
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
      _markEdited(event.nodeId);
      _publishNode(
        _applyFields(
          node,
          NodeFieldChanged(nodeId: event.nodeId, ttsText: line),
        ).copy(lineApproved: false, ttsApproved: false),
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
      _markEdited(targetId);
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
  /// status (and any approval reset) shows up. Display + dispatch only:
  /// generation runs server-side.
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

  /// Records a frame approval or rejection, then reloads the nodes so
  /// inheritance side effects (an E approval opening the child video
  /// gate) show up.
  Future<void> _onImageApproval(
    ImageApprovalChanged event,
    Emitter<CreateState> emit,
  ) async {
    await _runImaging(
      emit,
      event.nodeId,
      () => repository.approveNodeImage(
        storyId: state.story!.storyId,
        nodeId: event.nodeId,
        which: event.which,
        approved: event.approved,
        expectedHash: event.which == 'start'
            ? _node(event.nodeId)?.startHash
            : _node(event.nodeId)?.endHash,
      ),
      saveEdits: false,
    );
  }

  /// Asks for the node video (inheriting the approved parent E as S),
  /// then reloads the nodes so the job status shows up. The backend
  /// enforces the approval gate; a rejection lands as [failure]. When the
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
      emit(state.copy(uploadProgress: () => 1));
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
        // Live nodes while waiting: a trigger-written `pending` shows
        // through the running pill once the echo is close.
        emit(state.copy(nodes: _mergeReload(nodes)));
      }
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
      lineApproved: changed ? false : null,
      ttsApproved: changed ? false : null,
      ttsStatus: changed ? 'idle' : null,
      ttsAudioUrl: changed ? () => null : null,
      ttsDurationSeconds: changed ? () => null : null,
    );
  }
  if (event.visibility != null) {
    next = next.copy(visibility: event.visibility);
  }
  if (event.lineApproved != null) {
    next = next.copy(lineApproved: event.lineApproved);
  }
  if (event.ttsApproved != null) {
    next = next.copy(ttsApproved: event.ttsApproved);
  }
  if (event.startImagePrompt != null) {
    final cleaned = event.startImagePrompt!.trim();
    next = next.copy(startImagePrompt: () => cleaned.isEmpty ? null : cleaned);
  }
  if (event.endImagePrompt != null) {
    final cleaned = event.endImagePrompt!.trim();
    next = next.copy(endImagePrompt: () => cleaned.isEmpty ? null : cleaned);
  }
  if (event.videoPrompt != null) {
    final cleaned = event.videoPrompt!.trim();
    next = next.copy(videoPrompt: () => cleaned.isEmpty ? null : cleaned);
  }
  if (event.endingName != null) {
    final cleaned = event.endingName!.trim();
    next = next.copy(endingName: () => cleaned.isEmpty ? null : cleaned);
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
    'too-large' => 'Videos must be 100 MB or smaller.',
    'unknown-target' => const AppFailure(.invalid).phrase,
    'not-author' || 'not-draft' => const AppFailure(.denied).phrase,
    'encode-unavailable' => 'Video encoding is unavailable',
    _ => const AppFailure(.failed).phrase,
  };
}
