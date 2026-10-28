import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:ramifica/app/theme.dart';
import 'package:ramifica/core/widgets/empty_state.dart';
import 'package:ramifica/core/widgets/failure_text.dart';
import 'package:ramifica/data/repositories/auth_repository.dart';
import 'package:ramifica/data/repositories/create_repository.dart';
import 'package:ramifica/data/repositories/firebase_auth_gateway.dart';
import 'package:ramifica/features/create/create_bloc.dart';
import 'package:ramifica/features/create/create_event.dart';
import 'package:ramifica/features/create/create_state.dart';
import 'package:ramifica/features/create/draft_canvas.dart';
import 'package:ramifica/features/create/node_inspector.dart';

/// Create tab: draft canvas plus the inspector. Creates its own bloc
/// like Explore; tests inject [bloc] and read recorded events instead of
/// touching Firebase.
class CreateView extends StatefulWidget {
  const CreateView({super.key, this.bloc, this.repository, this.authRepository});

  final CreateBloc? bloc;
  final CreateRepository? repository;
  final AuthRepository? authRepository;

  @override
  State<CreateView> createState() => _CreateViewState();
}

class _CreateViewState extends State<CreateView> {
  CreateBloc? _bloc;

  @override
  void initState() {
    super.initState();
    if (widget.bloc != null) {
      _bloc = widget.bloc;
      return;
    }
    try {
      _bloc = CreateBloc(
        repository:
            widget.repository ?? createFirebaseCreateRepository(),
        auth: widget.authRepository ?? createFirebaseAuthRepository(),
      );
    } catch (_) {
      _bloc = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final bloc = _bloc;
    if (bloc == null) {
      return const Scaffold(
        body: SafeArea(
          child: Center(
            child: EmptyState(message: 'Create is unavailable right now.'),
          ),
        ),
      );
    }
    return Scaffold(
      body: SafeArea(
        child: BlocProvider.value(
          value: bloc,
          child: BlocBuilder<CreateBloc, CreateState>(
            builder: (context, state) => _body(context, state),
          ),
        ),
      ),
    );
  }

  Widget _body(BuildContext context, CreateState state) {
    final bloc = context.read<CreateBloc>();
    return Padding(
      padding: const .all(16),
      child: Column(
        crossAxisAlignment: .stretch,
        children: [
          Row(
            children: [
              const Text('Create', style: RamificaText.screenTitle),
              const Spacer(),
              if (state.hasDraft && state.openNode != null)
                OutlinedButton(
                  onPressed: state.job == CreateJob.none
                      ? () => bloc.add(const NodeAdded())
                      : null,
                  child: const Text('Add node'),
                ),
            ],
          ),
          const SizedBox(height: 12),
          if (state.failure != null) ...[
            FailureText(message: state.failure!),
            const SizedBox(height: 12),
          ],
          if (!state.hasDraft)
            Expanded(
              child: Center(
                child: EmptyState(
                  message: 'Your drafts live here.',
                  actionLabel: 'Start a draft',
                  onAction: () => bloc.add(const DraftRequested()),
                ),
              ),
            )
          else ...[
            Expanded(
              flex: 2,
              child: DraftCanvas(
                nodes: state.nodes,
                orphans: state.orphanNodeIds,
                openNodeId: state.openNodeId,
                rootNodeId: state.story?.rootNodeId,
                onSelect: (id) => bloc.add(NodeSelected(id)),
              ),
            ),
            const SizedBox(height: 12),
            if (state.openNode != null)
              Flexible(
                flex: 3,
                child: SingleChildScrollView(
                  child: NodeInspector(
                    node: state.openNode!,
                    status: state.statusOf(state.openNodeId!),
                    missing: state.missingFor(state.openNode!),
                    busy: state.job == CreateJob.saving ||
                        state.job == CreateJob.generating ||
                        state.job == CreateJob.imaging,
                    isRoot: state.isRoot(state.openNodeId!),
                    parent: state.parentOf(state.openNode!),
                    videoGateMessage:
                        state.videoGateMessage(state.openNode!),
                    videoDesynced: state.videoDesynced(state.openNode!),
                    onTitleChanged: (value) => bloc.add(
                      NodeFieldChanged(
                        nodeId: state.openNodeId!,
                        title: value,
                      ),
                    ),
                    onLineChanged: (value) => bloc.add(
                      NodeFieldChanged(
                        nodeId: state.openNodeId!,
                        ttsText: value,
                      ),
                    ),
                    onChoiceLabelChanged: (choiceId, label) => bloc.add(
                      NodeFieldChanged(
                        nodeId: state.openNodeId!,
                        choiceLabels: {choiceId: label},
                      ),
                    ),
                    onVisibilityChanged: (visibility) => bloc.add(
                      NodeFieldChanged(
                        nodeId: state.openNodeId!,
                        visibility: visibility,
                      ),
                    ),
                    onSave: () => bloc.add(const NodeSaved()),
                    onGenerate: () =>
                        bloc.add(const TextGenerateRequested()),
                    onRegenerate: () => bloc.add(
                      const TextGenerateRequested(regenerate: true),
                    ),
                    onImageApprovalChanged: (which, approved) => bloc.add(
                      ImageApprovalChanged(
                        nodeId: state.openNodeId!,
                        which: which,
                        approved: approved,
                      ),
                    ),
                    onImageGenerate: (which) => bloc.add(
                      ImageGenerateRequested(
                        nodeId: state.openNodeId!,
                        which: which,
                      ),
                    ),
                    onVideoGenerate: () => bloc.add(
                      VideoGenerateRequested(state.openNodeId!),
                    ),
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}
