import 'package:bloc/bloc.dart';
import 'package:bloc_concurrency/bloc_concurrency.dart';
import 'package:ramifica/data/models/app_failure.dart';
import 'package:ramifica/data/models/draft_node.dart';
import 'package:ramifica/data/repositories/auth_repository.dart';
import 'package:ramifica/data/repositories/create_repository.dart';
import 'package:ramifica/features/create/create_event.dart';
import 'package:ramifica/features/create/create_state.dart';

/// Draft, nodes, and Spark proposals for the Create tab.
///
/// The signed-in uid comes from [auth]'s current identity when
/// [DraftRequested] carries no author id, so a mid-session account change
/// cannot draft on a stale id. Tests pass the author id in the event and
/// leave [auth] null.
class CreateBloc extends Bloc<CreateEvent, CreateState> {
  CreateBloc({required this.repository, this.auth})
    : super(const CreateState()) {
    on<DraftRequested>(_onDraftRequested, transformer: restartable());
    on<DraftOpened>(_onDraftOpened, transformer: restartable());
    on<NodeSelected>(_onNodeSelected);
    on<NodeAdded>(_onNodeAdded, transformer: droppable());
    on<NodeFieldChanged>(_onFieldChanged);
    on<NodeSaved>(_onNodeSaved, transformer: droppable());
    on<TextGenerateRequested>(_onGenerate, transformer: restartable());
  }

  final CreateRepository repository;
  final AuthRepository? auth;

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
      emit(
        CreateState(
          story: story,
          nodes: nodes,
          openNodeId: open,
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

  void _onNodeSelected(NodeSelected event, Emitter<CreateState> emit) {
    final id = event.nodeId.trim();
    if (id.isEmpty) return;
    if (state.nodes.any((node) => node.nodeId == id)) {
      emit(state.copy(openNodeId: () => id, failure: () => null));
    }
  }

  Future<void> _onNodeAdded(
    NodeAdded event,
    Emitter<CreateState> emit,
  ) async {
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
            if (node.nodeId == event.nodeId) _applyFields(node, event) else node,
        ],
        failure: () => null,
      ),
    );
  }

  Future<void> _onNodeSaved(
    NodeSaved event,
    Emitter<CreateState> emit,
  ) async {
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
    next = next.copy(windowSeconds: () => event.windowSeconds);
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
