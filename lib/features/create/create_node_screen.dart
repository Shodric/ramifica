import 'dart:async';
import 'dart:convert';

import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:ramifica/app/theme.dart';
import 'package:ramifica/core/widgets/failure_text.dart';
import 'package:ramifica/data/models/draft_node.dart';
import 'package:ramifica/data/models/app_failure.dart';
import 'package:ramifica/data/repositories/create_repository.dart';
import 'package:ramifica/features/create/asr_socket.dart';
import 'package:ramifica/features/create/create_bloc.dart';
import 'package:ramifica/features/create/create_event.dart';
import 'package:ramifica/features/create/create_preview.dart';
import 'package:ramifica/features/create/create_state.dart';
import 'package:ramifica/features/create/draft_canvas.dart';
import 'package:ramifica/features/create/steps/step_clip.dart';
import 'package:ramifica/features/create/steps/step_frames.dart';
import 'package:ramifica/features/create/steps/step_hotspots.dart';
import 'package:ramifica/features/create/steps/step_script.dart';
import 'package:ramifica/features/create/steps/step_shell.dart';
import 'package:ramifica/features/create/steps/step_voice.dart';
import 'package:ramifica/features/create/steps/wizard_gates.dart';
import 'package:uuid/uuid.dart';

/// Fullscreen node editor as a stepped wizard: Idea (root only), Script,
/// Scenes, Options, Voice, Clip. One step shows at a time ([IndexedStack]
/// keeps controllers alive). Continue runs the step predicate and reports
/// the first missing piece inline, never as a toast. Back and revisits are
/// always free; jumping forward stops at the first incomplete step.
///
/// Manual edits stay in the bloc until Save or a generation request. Typing,
/// changing steps, and leaving the editor do not write to the repository.
class CreateNodeScreen extends StatefulWidget {
  const CreateNodeScreen({
    super.key,
    required this.bloc,
    required this.nodeId,
    required this.pickVideo,
    required this.newTakeId,
  });

  final CreateBloc bloc;
  final String nodeId;
  final PickVideoFile? pickVideo;
  final String Function() newTakeId;

  @override
  State<CreateNodeScreen> createState() => _CreateNodeScreenState();
}

class _CreateNodeScreenState extends State<CreateNodeScreen> {
  final _premiseKey = GlobalKey<WizardPremiseState>();
  final _scriptKey = GlobalKey<StepScriptState>();
  final _sessionId = const Uuid().v4();
  var _stepIndex = 0;
  var _previewOpen = false;

  /// Idea sits before Script. The root stepper leads with that chip.
  /// Continue commits it and leaves. Child nodes hide it.
  var _premise = true;
  final List<bool> _showErrors = List.filled(wizardStepCount, false);
  String? _banner;

  @override
  void dispose() {
    // The script dictation take must not outlive the screen: late socket
    // events after this are ignored by the controller generation guard.
    unawaited(_scriptKey.currentState?.stopDictation());
    super.dispose();
  }

  /// Stops an open S1 dictation take before step changes, exits, and
  /// Continue: the take is kept (transcribe-on-stop) and late events are
  /// ignored, so switching steps never leaks audio into the new step.
  void _stopScriptDictation() {
    unawaited(_scriptKey.currentState?.stopDictation());
  }

  Future<String?> _idToken() async {
    try {
      return await FirebaseAuth.instance.currentUser?.getIdToken();
    } catch (_) {
      return null;
    }
  }

  Future<String?> _appCheckToken() async {
    try {
      return await FirebaseAppCheck.instance.getToken();
    } catch (_) {
      return null;
    }
  }

  void _save() {
    widget.bloc.add(NodeSaved(nodeId: widget.nodeId));
  }

  // Generation handlers flush the latest edits inside the bloc write queue.
  void _runMedia(VoidCallback dispatch) => dispatch();

  void _snack(String message, {required bool amber}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(milliseconds: 1200),
        backgroundColor: amber
            ? RamificaColors.rewardGold
            : RamificaColors.nodeActive,
      ),
    );
  }

  String _statusText(CreateState state) {
    if (state.job == CreateJob.saving) return 'Saving...';
    if (widget.bloc.hasUnsavedNodeEdits(widget.nodeId)) {
      return 'Unsaved changes';
    }
    return 'No changes';
  }

  void _goTo(int index, DraftNode node, bool isRoot) {
    final firstIncomplete = firstIncompleteStep(node: node, isRoot: isRoot);
    if (index > firstIncomplete) {
      final missing = firstMissingForStep(
        step: firstIncomplete,
        node: node,
        isRoot: isRoot,
      );
      setState(() {
        _showErrors[firstIncomplete] = true;
        _banner = missing;
      });
      return;
    }
    if (_premise && isRoot) _premiseKey.currentState?.commit();
    _stopScriptDictation();
    setState(() {
      _premise = false;
      _stepIndex = index;
      _banner = null;
    });
  }

  void _leavePremise() {
    _premiseKey.currentState?.commit();
    _stopScriptDictation();
    setState(() {
      _premise = false;
      _stepIndex = 0;
      _banner = null;
    });
  }

  void _onContinue(DraftNode node, bool isRoot) {
    if (_premise && isRoot) {
      _leavePremise();
      return;
    }
    final missing = firstMissingForStep(
      step: _stepIndex,
      node: node,
      isRoot: isRoot,
    );
    if (missing != null) {
      setState(() {
        _showErrors[_stepIndex] = true;
        _banner = missing;
      });
      return;
    }
    _stopScriptDictation();
    if (_stepIndex < wizardStepCount - 1) {
      setState(() {
        _stepIndex++;
        _banner = null;
      });
    } else {
      _snack('Scene ready ✓', amber: false);
    }
  }

  /// Show the premise page without saving node edits. Root only.
  void _openIdea(bool isRoot) {
    if (!isRoot || _premise) return;
    _stopScriptDictation();
    setState(() {
      _premise = true;
      _banner = null;
    });
  }

  void _onBack() {
    final root = widget.bloc.state.isRoot(widget.nodeId);
    if (_premise) return;
    if (_stepIndex == 0) {
      if (!root) return;
      _stopScriptDictation();
      setState(() {
        _premise = true;
        _banner = null;
      });
      return;
    }
    _stopScriptDictation();
    setState(() {
      _stepIndex--;
      _banner = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return BlocProvider.value(
      value: widget.bloc,
      child: BlocBuilder<CreateBloc, CreateState>(
        builder: (context, state) {
          final scene = sceneIndexes(state.nodes, state.story?.rootNodeId);
          final number = scene[widget.nodeId];
          if (number == null) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (context.mounted) Navigator.of(context).maybePop();
            });
            return const Scaffold(body: SizedBox.shrink());
          }
          final node = state.nodes.firstWhere((n) => n.nodeId == widget.nodeId);
          final isRoot = state.isRoot(widget.nodeId);
          final busy =
              state.job == CreateJob.saving ||
              state.job == CreateJob.generating ||
              state.job == CreateJob.imaging ||
              state.job == CreateJob.uploading;
          final firstIncomplete = firstIncompleteStep(
            node: node,
            isRoot: isRoot,
          );
          final stepIndex = _stepIndex.clamp(0, wizardStepCount - 1);
          final showPremise = _premise && isRoot;
          final parent = state.parentOf(node);
          return PopScope(
            canPop: true,
            child: Scaffold(
              backgroundColor: RamificaColors.surface,
              appBar: AppBar(
                backgroundColor: RamificaColors.surface,
                surfaceTintColor: Colors.transparent,
                elevation: 0,
                leading: IconButton(
                  icon: const Icon(Icons.arrow_back, size: 24),
                  color: RamificaColors.textPrimary,
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
                titleSpacing: 0,
                title: Text('Create', style: RamificaText.headlineSM),
                actions: [
                  if (!showPremise)
                    TextButton.icon(
                      key: const ValueKey('wizard-save'),
                      onPressed: busy ? null : _save,
                      icon: const Icon(Icons.save_outlined, size: 20),
                      label: const Text('Save'),
                    ),
                  IconButton(
                    key: ValueKey('preview-node-${widget.nodeId}'),
                    tooltip: 'Preview',
                    icon: const Icon(Icons.visibility, size: 22),
                    color: RamificaColors.nodeActive,
                    onPressed: busy
                        ? null
                        : () async {
                            setState(() => _previewOpen = true);
                            await showCreatePreview(context, node: node);
                            if (mounted) setState(() => _previewOpen = false);
                          },
                  ),
                ],
              ),
              body: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                  child: Column(
                    crossAxisAlignment: .stretch,
                    children: [
                      WizardHeader(
                        sceneNumber: number,
                        sceneTotal: state.nodes.length,
                        title: node.title,
                        status: state.statusOf(widget.nodeId),
                        stepIndex: showPremise ? -1 : stepIndex,
                        firstIncomplete: firstIncomplete,
                        showIdea: isRoot,
                        ideaCurrent: showPremise,
                        ideaDone: !showPremise && _ideaFilled(state, node),
                        onIdea: () => _openIdea(isRoot),
                        onStepTap: (index) => _goTo(index, node, isRoot),
                      ),
                      const SizedBox(height: 16),
                      Expanded(
                        child: showPremise
                            ? WizardPremise(key: _premiseKey)
                            : IndexedStack(
                                index: stepIndex,
                                children: [
                                  _StepScroll(
                                    child: StepScript(
                                      key: _scriptKey,
                                      node: node,
                                      isRoot: isRoot,
                                      busy: busy,
                                      showErrors: _showErrors[0],
                                      socketFactory: AsrSocket.new,
                                      getIdToken: _idToken,
                                      getAppCheckToken: _appCheckToken,
                                      transcribe: (bytes) async {
                                        final slice = await widget
                                            .bloc
                                            .repository
                                            .transcribeVoice(
                                              sessionId: _sessionId,
                                              seq: 0,
                                              audioBase64: base64Encode(bytes),
                                              format: 'wav',
                                              last: true,
                                            );
                                        return slice.text;
                                      },
                                      propose: (direction) async {
                                        final storyId =
                                            widget.bloc.state.story!.storyId;
                                        if (!await widget.bloc.flushNode(
                                          widget.nodeId,
                                        )) {
                                          throw const AppFailure(.failed);
                                        }
                                        return widget.bloc.repository
                                            .generateNodeText(
                                              storyId: storyId,
                                              nodeId: widget.nodeId,
                                              prompt: direction,
                                              purpose: 'scene',
                                            );
                                      },
                                      onApplyProposal: (proposal) =>
                                          widget.bloc.add(
                                            SceneProposalApplied(
                                              nodeId: widget.nodeId,
                                              proposal: proposal,
                                            ),
                                          ),
                                      onTitleChanged: (value) => _edited(
                                        () => widget.bloc.add(
                                          NodeFieldChanged(
                                            nodeId: widget.nodeId,
                                            title: value,
                                          ),
                                        ),
                                      ),
                                      onEndingNameChanged: (value) => _edited(
                                        () => widget.bloc.add(
                                          NodeFieldChanged(
                                            nodeId: widget.nodeId,
                                            endingName: value,
                                          ),
                                        ),
                                      ),
                                      onVisibilityChanged: (visibility) =>
                                          _edited(
                                            () => widget.bloc.add(
                                              NodeFieldChanged(
                                                nodeId: widget.nodeId,
                                                visibility: visibility,
                                              ),
                                            ),
                                          ),
                                    ),
                                  ),
                                  _StepScroll(
                                    child: StepFrames(
                                      generatingWhich:
                                          state.generating(
                                            widget.nodeId,
                                            'startImage',
                                          )
                                          ? 'start'
                                          : state.generating(
                                              widget.nodeId,
                                              'endImage',
                                            )
                                          ? 'end'
                                          : null,
                                      phase: state.operationPhase,
                                      node: node,
                                      isRoot: isRoot,
                                      inheritedImageUrl:
                                          parent?.endImageSourceUrl,
                                      inheritedCaption: parent == null
                                          ? null
                                          : 'Inherited from Scene ${scene[parent.nodeId] ?? '—'}',
                                      inheritedPrompt: parent?.endImagePrompt,
                                      busy: busy,
                                      showErrors: _showErrors[1],
                                      onStartPromptChanged: (value) => _edited(
                                        () => widget.bloc.add(
                                          NodeFieldChanged(
                                            nodeId: widget.nodeId,
                                            startImagePrompt: value,
                                          ),
                                        ),
                                      ),
                                      onEndPromptChanged: (value) => _edited(
                                        () => widget.bloc.add(
                                          NodeFieldChanged(
                                            nodeId: widget.nodeId,
                                            endImagePrompt: value,
                                          ),
                                        ),
                                      ),
                                      onImageApprovalChanged:
                                          (which, approved) => _runMedia(
                                            () => widget.bloc.add(
                                              ImageApprovalChanged(
                                                nodeId: widget.nodeId,
                                                which: which,
                                                approved: approved,
                                              ),
                                            ),
                                          ),
                                      onImageGenerate: (which, prompt) =>
                                          _runMedia(
                                            () => widget.bloc.add(
                                              ImageGenerateRequested(
                                                nodeId: widget.nodeId,
                                                which: which,
                                                prompt: prompt,
                                              ),
                                            ),
                                          ),
                                    ),
                                  ),
                                  _StepScroll(
                                    child: StepHotspots(
                                      node: node,
                                      busy: busy,
                                      showErrors: _showErrors[2],
                                      isRoot: isRoot,
                                      focusChoiceId: state.focusChoiceId,
                                      targetTitles: {
                                        for (final choice in node.choices)
                                          choice.choiceId: _targetTitle(
                                            state.nodes,
                                            state.story?.rootNodeId,
                                            choice.targetNodeId,
                                            scene,
                                          ),
                                      },
                                      targets: [
                                        for (final candidate in state.nodes)
                                          if (candidate.nodeId != widget.nodeId)
                                            candidate,
                                      ],
                                      onZoneMoved: (choiceId, x, y) => _edited(
                                        () => widget.bloc.add(
                                          ZoneMoved(
                                            nodeId: widget.nodeId,
                                            choiceId: choiceId,
                                            x: x,
                                            y: y,
                                          ),
                                        ),
                                      ),
                                      onAddHotspot: (slot) => _runMedia(
                                        () => widget.bloc.add(
                                          HotspotAdded(
                                            nodeId: widget.nodeId,
                                            slot: slot,
                                          ),
                                        ),
                                      ),
                                      onOpenChild: (targetId) {
                                        widget.bloc.add(NodeSelected(targetId));
                                        Navigator.of(context).push(
                                          MaterialPageRoute(
                                            builder: (_) => CreateNodeScreen(
                                              bloc: widget.bloc,
                                              nodeId: targetId,
                                              pickVideo: widget.pickVideo,
                                              newTakeId: widget.newTakeId,
                                            ),
                                          ),
                                        );
                                      },
                                      onZoneRemoved: (choiceId) => _edited(
                                        () => widget.bloc.add(
                                          ChoiceRemoved(
                                            nodeId: widget.nodeId,
                                            choiceId: choiceId,
                                          ),
                                        ),
                                      ),
                                      onChoiceLabelChanged: (choiceId, label) =>
                                          _edited(
                                            () => widget.bloc.add(
                                              NodeFieldChanged(
                                                nodeId: widget.nodeId,
                                                choiceLabels: {choiceId: label},
                                              ),
                                            ),
                                          ),
                                      onChoiceIconChanged: (choiceId, icon) =>
                                          _edited(
                                            () => widget.bloc.add(
                                              NodeFieldChanged(
                                                nodeId: widget.nodeId,
                                                choiceIcons: {choiceId: icon},
                                              ),
                                            ),
                                          ),
                                      onChoiceIconColorChanged:
                                          (choiceId, color) => _edited(
                                            () => widget.bloc.add(
                                              NodeFieldChanged(
                                                nodeId: widget.nodeId,
                                                choiceIconColors: {
                                                  choiceId: color,
                                                },
                                              ),
                                            ),
                                          ),
                                      onAddBranch: () => _runMedia(
                                        () => widget.bloc.add(
                                          NodeAdded(
                                            parentNodeId: widget.nodeId,
                                          ),
                                        ),
                                      ),
                                      onDelete: () =>
                                          widget.bloc.add(const NodeDeleted()),
                                      deleteBlockedReason: state
                                          .deleteBlockReason(widget.nodeId),
                                    ),
                                  ),
                                  _StepScroll(
                                    child: StepVoice(
                                      active:
                                          !showPremise &&
                                          stepIndex == 3 &&
                                          !_previewOpen,
                                      generating: state.generating(
                                        widget.nodeId,
                                        'voice',
                                      ),
                                      phase: state.operationPhase,
                                      onLineChanged: (value) => _edited(
                                        () => widget.bloc.add(
                                          NodeFieldChanged(
                                            nodeId: widget.nodeId,
                                            ttsText: value,
                                          ),
                                        ),
                                      ),
                                      onLineApprovalChanged: (approved) =>
                                          _edited(
                                            () => widget.bloc.add(
                                              NodeFieldChanged(
                                                nodeId: widget.nodeId,
                                                lineApproved: approved,
                                              ),
                                            ),
                                          ),
                                      onLineGenerate: () => widget.bloc.add(
                                        NarrationGenerateRequested(
                                          widget.nodeId,
                                        ),
                                      ),
                                      node: node,
                                      busy: busy,
                                      showErrors: _showErrors[3],
                                      onVoiceGenerate: () => _runMedia(
                                        () => widget.bloc.add(
                                          VoiceGenerateRequested(widget.nodeId),
                                        ),
                                      ),
                                      onVoiceApprovalChanged: (approved) =>
                                          _edited(
                                            () => widget.bloc.add(
                                              NodeFieldChanged(
                                                nodeId: widget.nodeId,
                                                ttsApproved: approved,
                                              ),
                                            ),
                                          ),
                                    ),
                                  ),
                                  _StepScroll(
                                    child: StepClip(
                                      active:
                                          !showPremise &&
                                          stepIndex == 4 &&
                                          !_previewOpen,
                                      generating: state.generating(
                                        widget.nodeId,
                                        'video',
                                      ),
                                      phase: state.operationPhase,
                                      node: node,
                                      inheritedPrompt: parent?.endImagePrompt,
                                      busy: busy,
                                      showErrors: _showErrors[4],
                                      videoGateMessage: state.videoGateMessage(
                                        node,
                                      ),
                                      videoDesynced: state.videoDesynced(node),
                                      uploadProgress:
                                          state.job == CreateJob.uploading &&
                                              state.jobNodeId == widget.nodeId
                                          ? state.uploadProgress
                                          : null,
                                      onVideoPromptChanged: (value) => _edited(
                                        () => widget.bloc.add(
                                          NodeFieldChanged(
                                            nodeId: widget.nodeId,
                                            videoPrompt: value,
                                          ),
                                        ),
                                      ),
                                      onVideoGenerate: (prompt) => _runMedia(
                                        () => widget.bloc.add(
                                          VideoGenerateRequested(
                                            widget.nodeId,
                                            prompt: prompt,
                                          ),
                                        ),
                                      ),
                                      onUploadVideo: widget.pickVideo == null
                                          ? null
                                          : () async {
                                              final picked =
                                                  await widget.pickVideo!();
                                              if (!context.mounted ||
                                                  picked == null) {
                                                return;
                                              }
                                              _runMedia(
                                                () => widget.bloc.add(
                                                  VideoUploadRequested(
                                                    nodeId: widget.nodeId,
                                                    contentType:
                                                        picked.contentType,
                                                    bytes: picked.bytes,
                                                    takeId: widget.newTakeId(),
                                                  ),
                                                ),
                                              );
                                            },
                                    ),
                                  ),
                                ],
                              ),
                      ),
                      if (state.failure != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: FailureText(message: state.failure!),
                        )
                      else if (_banner != null)
                        WizardBanner(text: _banner!),
                      WizardFooter(
                        statusText: _statusText(state),
                        canGoBack: showPremise
                            ? false
                            : stepIndex > 0 || isRoot,
                        busy: busy,
                        onBack: _onBack,
                        onContinue: () => _onContinue(node, isRoot),
                        isLastStep:
                            !showPremise && stepIndex == wizardStepCount - 1,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// Manual author edits update only the local bloc state.
  void _edited(void Function() dispatch) => dispatch();
}

/// One scrollable step page inside the wizard stack.
class _StepScroll extends StatelessWidget {
  const _StepScroll({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: 16),
      child: child,
    );
  }
}

/// Full `Scene M (Title)` destination for the options cards.
/// Falls back to the bare scene label when the title is missing.
String _targetTitle(
  List<DraftNode> nodes,
  String? rootNodeId,
  String targetId,
  Map<String, int> scenes,
) {
  final number = scenes[targetId];
  if (number == null) return 'Scene —';
  DraftNode? target;
  for (final node in nodes) {
    if (node.nodeId == targetId) target = node;
  }
  final title = target?.title.trim() ?? '';
  if (title.isEmpty) return 'Scene $number';
  return 'Scene $number ($title)';
}

/// True when the root idea was committed: synopsis, else the narrator line.
bool _ideaFilled(CreateState state, DraftNode node) {
  final synopsis = state.story?.synopsis.trim() ?? '';
  if (synopsis.isNotEmpty) return true;
  return node.ttsText.trim().isNotEmpty;
}
