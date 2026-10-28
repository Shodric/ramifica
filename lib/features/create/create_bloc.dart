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
  }) : super(const CreateState()) {
    on<DraftRequested>(_onDraftRequested, transformer: restartable());
    on<DraftOpened>(_onDraftOpened, transformer: restartable());
    on<NodeSelected>(_onNodeSelected);
    on<NodeAdded>(_onNodeAdded, transformer: droppable());
    on<NodeFieldChanged>(_onFieldChanged);
    on<NodeSaved>(_onNodeSaved, transformer: droppable());
    on<ZonesSaved>(_onZonesSaved, transformer: droppable());
    on<WindowSaved>(_onWindowSaved, transformer: droppable());
    on<ZoneMoved>(_onZoneMoved);
    on<ChoiceAdded>(_onChoiceAdded);
    on<ChoiceRemoved>(_onChoiceRemoved);
    on<TextGenerateRequested>(_onGenerate, transformer: restartable());
    on<VoiceGenerateRequested>(_onVoiceGenerate, transformer: restartable());
    on<ImageGenerateRequested>(_onImageGenerate, transformer: restartable());
    on<ImageApprovalChanged>(_onImageApproval, transformer: droppable());
    on<VideoGenerateRequested>(_onVideoGenerate, transformer: restartable());
    on<VideoUploadRequested>(_onVideoUpload, transformer: restartable());
    on<VideoUploadProgressed>(_onVideoUploadProgressed);
  }
  final CreateRepository repository;
  final AuthRepository? auth;

  /// Delay between trigger-observation polls after an upload.
  final Duration uploadPollInterval;

  /// How many trigger-observation polls run before the upload fails
  /// closed. Bounds the `uploading` job when the trigger is slow.
  final int maxUploadPolls;

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
    } on AppFailure catch (error) {
      emit(
        state.copy(
          job: CreateJob.none,
          jobNodeId: () => null,
          failure: () => error.phrase,
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
    } on AppFailure catch (error) {
      emit(
        state.copy(
          job: CreateJob.none,
          jobNodeId: () => null,
          failure: () => error.phrase,
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
    final parent = state.openNode;
    if (story == null || parent == null) return;
    emit(
      state.copy(
        job: CreateJob.saving,
        jobNodeId: () => parent.nodeId,
        failure: () => null,
      ),
    );
    try {
      final nodeId = await repository.createNode(
        storyId: story.storyId,
        parentNodeId: parent.nodeId,
      );
      final nodes = await repository.fetchNodes(story.storyId);
      emit(
        state.copy(
          nodes: nodes,
          openNodeId: () => nodeId,
          job: CreateJob.none,
          jobNodeId: () => null,
          failure: () => null,
        ),
      );
    } on AppFailure catch (error) {
      emit(
        state.copy(
          job: CreateJob.none,
          jobNodeId: () => parent.nodeId,
          failure: () => error.phrase,
        ),
      );
    }
  }

  void _onFieldChanged(NodeFieldChanged event, Emitter<CreateState> emit) {
    if (!state.nodes.any((node) => node.nodeId == event.nodeId)) return;
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
      ),
    );
  }

  /// Moves one choice zone, clamping to the 0-1 frame so the payload can
  /// never fail the `saveNode` zone check. Unknown nodes and choices are
  /// ignored.
  void _onZoneMoved(ZoneMoved event, Emitter<CreateState> emit) {
    if (!state.nodes.any((node) => node.nodeId == event.nodeId)) return;
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
      ),
    );
  }

  /// Adds a choice with a center-frame zone pointing at its target.
  /// Ignored on endings, past two choices, blank targets, and unknown
  /// nodes.
  void _onChoiceAdded(ChoiceAdded event, Emitter<CreateState> emit) {
    final target = event.targetNodeId.trim();
    if (target.isEmpty) return;
    final index = state.nodes.indexWhere(
      (node) => node.nodeId == event.nodeId,
    );
    if (index < 0) return;
    final node = state.nodes[index];
    if (node.isEnding || node.choices.length >= 2) return;
    final choices = [
      ...node.choices,
      DraftChoice(
        choiceId: const Uuid().v4(),
        label: '',
        targetNodeId: target,
        // The sole choice carries the hold; a second one waits for the
        // author to pick the default explicitly.
        isDefault: node.choices.isEmpty,
      ),
    ];
    emit(
      state.copy(
        nodes: [
          for (final current in state.nodes)
            if (current.nodeId == event.nodeId)
              current.copy(choices: choices)
            else
              current,
        ],
        failure: () => null,
      ),
    );
  }

  /// Removes a choice and its zone. When the default goes and choices
  /// remain, the first survivor inherits the default so the checklist can
  /// still pass. Unknown nodes and choices are ignored.
  void _onChoiceRemoved(ChoiceRemoved event, Emitter<CreateState> emit) {
    final index = state.nodes.indexWhere(
      (node) => node.nodeId == event.nodeId,
    );
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
      survivors = [
        survivors.first.copy(isDefault: true),
        ...survivors.skip(1),
      ];
    }
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
      ),
    );
  }

  Future<void> _onNodeSaved(NodeSaved event, Emitter<CreateState> emit) {
    return _saveOpenNode(emit);
  }

  /// Zones ride the `choices` whitelist inside the full node doc, so
  /// saving zones is saving the open node.
  Future<void> _onZonesSaved(ZonesSaved event, Emitter<CreateState> emit) {
    return _saveOpenNode(emit);
  }

  /// The window rides `windowSeconds` inside the full node doc, so
  /// saving the window is saving the open node.
  Future<void> _onWindowSaved(WindowSaved event, Emitter<CreateState> emit) {
    return _saveOpenNode(emit);
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

  /// Shared save runner: persists the open node through `saveNode`.
  Future<void> _saveOpenNode(Emitter<CreateState> emit) async {
    final story = state.story;
    final node = state.openNode;
    if (story == null || node == null) return;
    emit(
      state.copy(
        job: CreateJob.saving,
        jobNodeId: () => node.nodeId,
        failure: () => null,
      ),
    );
    try {
      await repository.saveNode(storyId: story.storyId, node: node);
      emit(
        state.copy(
          job: CreateJob.none,
          jobNodeId: () => null,
          failure: () => null,
        ),
      );
    } on AppFailure catch (error) {
      emit(
        state.copy(
          job: CreateJob.none,
          jobNodeId: () => node.nodeId,
          failure: () => error.phrase,
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
    emit(
      state.copy(
        job: CreateJob.generating,
        jobNodeId: () => node.nodeId,
        failure: () => null,
      ),
    );
    try {
      final proposal = await repository.generateNodeText(
        storyId: story.storyId,
        nodeId: node.nodeId,
        prompt: event.prompt,
      );
      emit(
        state.copy(
          nodes: [
            for (final current in state.nodes)
              if (current.nodeId == node.nodeId)
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
      emit(
        state.copy(
          job: CreateJob.none,
          jobNodeId: () => node.nodeId,
          failure: () => error.phrase,
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
      ),
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
      ),
    );
  }

  /// Asks for the node video (inheriting the approved parent E as S),
  /// then reloads the nodes so the job status shows up. The backend
  /// enforces the approval gate; a rejection lands as [failure].
  Future<void> _onVideoGenerate(
    VideoGenerateRequested event,
    Emitter<CreateState> emit,
  ) async {
    await _runImaging(
      emit,
      event.nodeId,
      () => repository.generateNodeVideo(
        storyId: state.story!.storyId,
        nodeId: event.nodeId,
      ),
    );
  }

  /// Shared imaging runner: unknown nodes and missing drafts are ignored,
  /// the job pill runs while the call is in flight, and the nodes reload
  /// after so server-side status is the source of truth.
  Future<void> _runImaging(
    Emitter<CreateState> emit,
    String nodeId,
    Future<void> Function() call,
  ) async {
    final story = state.story;
    if (story == null) return;
    if (!state.nodes.any((node) => node.nodeId == nodeId)) return;
    emit(
      state.copy(
        job: CreateJob.imaging,
        jobNodeId: () => nodeId,
        failure: () => null,
      ),
    );
    try {
      await call();
      final nodes = await repository.fetchNodes(story.storyId);
      emit(
        state.copy(
          nodes: nodes,
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
          failure: () => error.phrase,
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
      var nodes = await repository.fetchNodes(story.storyId);
      var marker = await repository.fetchUploadMarker(
        storyId: story.storyId,
        nodeId: event.nodeId,
      );
      var polls = 0;
      while (marker.takeId != takeId && polls < maxUploadPolls) {
        polls++;
        await Future<void>.delayed(uploadPollInterval);
        if (isClosed) return;
        nodes = await repository.fetchNodes(story.storyId);
        marker = await repository.fetchUploadMarker(
          storyId: story.storyId,
          nodeId: event.nodeId,
        );
        // Live nodes while waiting: a trigger-written `pending` shows
        // through the running pill once the echo is close.
        emit(state.copy(nodes: nodes));
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
          failure: () => error.phrase,
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
  if (event.ttsText != null) next = next.copy(ttsText: event.ttsText);
  if (event.visibility != null) {
    next = next.copy(visibility: event.visibility);
  }
  if (event.windowSeconds != null) {
    // Clamp to the `saveNode` window (3-15) so an out-of-range step can
    // never fail the save.
    next = next.copy(windowSeconds: () => event.windowSeconds!.clamp(3, 15));
  }
  if (event.lineApproved != null) {
    next = next.copy(lineApproved: event.lineApproved);
  }
  if (event.ttsApproved != null) {
    next = next.copy(ttsApproved: event.ttsApproved);
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
