import 'dart:async';
import 'dart:convert';

import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:ramifica/app/theme.dart';
import 'package:ramifica/core/widgets/app_snackbar.dart';
import 'package:ramifica/core/widgets/choice_icon.dart';
import 'package:ramifica/core/widgets/failure_text.dart';
import 'package:ramifica/data/models/draft_node.dart';
import 'package:ramifica/data/models/app_failure.dart';
import 'package:ramifica/data/repositories/auth_repository.dart';
import 'package:ramifica/data/repositories/create_repository.dart';
import 'package:ramifica/features/create/asr_socket.dart';
import 'package:ramifica/features/create/create_bloc.dart';
import 'package:ramifica/features/create/create_event.dart';
import 'package:ramifica/features/create/create_preview.dart';
import 'package:ramifica/features/create/create_state.dart';
import 'package:ramifica/features/create/draft_canvas.dart';
import 'package:ramifica/features/create/steps/fill_preview_dialog.dart';
import 'package:ramifica/features/create/steps/step_clip.dart';
import 'package:ramifica/features/create/steps/step_frames.dart';
import 'package:ramifica/features/create/steps/step_hotspots.dart';
import 'package:ramifica/features/create/steps/step_script.dart';
import 'package:ramifica/features/create/steps/step_shell.dart';
import 'package:ramifica/features/create/steps/step_voice.dart';
import 'package:ramifica/features/create/steps/wizard_gates.dart';
import 'package:uuid/uuid.dart';

/// Leave-confirmation answer: stay, drop edits, or save before exit.
enum _LeaveChoice { stay, discard, save }

/// Fullscreen node editor as a stepped wizard: Idea (root only), Info,
/// Scenes, Options, Voice, Clip. One step shows at a time ([IndexedStack]
/// keeps controllers alive). Continue saves the pending edits, runs the
/// step predicate, and reports the first missing piece inline, never as
/// a toast; it never proposes. The AppBar spark proposes values for the
/// active section only and previews them for Accept/Discard. Revisits are
/// always free; jumping forward stops at the first incomplete step.
///
/// Manual edits stay in the bloc until Continue, Finish, or a generation
/// request persists them. Typing, changing steps, and leaving the editor
/// do not write to the repository; leaving with edits asks first.
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
  // True while a child node screen is pushed on top: the covered step
  // players must stay paused and released until this screen is back.
  var _childOpen = false;
  Timer? _generationExpiry;
  String? _expiryAt;

  /// Idea sits before Info. The root stepper leads with that chip.
  /// Continue commits it and leaves. Child nodes hide it.
  var _premise = true;
  final List<bool> _showErrors = List.filled(wizardStepCount, false);
  String? _banner;

  /// True between an upload dispatch and its terminal settle. The upload
  /// failure then surfaces once as a floating snack instead of inline.
  var _uploadSnackArmed = false;

  /// Exact upload failure phrase already shown as a snack. The inline
  /// slot hides while it matches; a clear drops it so a later identical
  /// phrase from another op renders inline again.
  String? _snackedFailure;

  /// An Info Continue is mid propose+apply. Disables the footer while
  /// the proposal round-trips.
  var _scriptProposing = false;

  @override
  void dispose() {
    // The script dictation take must not outlive the screen: late socket
    // events after this are ignored by the controller generation guard.
    unawaited(_scriptKey.currentState?.stopDictation());
    _generationExpiry?.cancel();
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

  // Generation handlers flush the latest edits inside the bloc write queue.
  void _runMedia(VoidCallback dispatch) => dispatch();

  /// Persists pending edits, if any. False keeps the step: the failure
  /// surfaces through the shared failure text.
  Future<bool> _flushEdits(String nodeId) async {
    while (widget.bloc.hasUnsavedNodeEdits(nodeId) ||
        widget.bloc.hasUnsavedStoryEdits) {
      if (!mounted ||
          widget.bloc.state.story == null ||
          !widget.bloc.state.nodes.any((node) => node.nodeId == nodeId)) {
        return false;
      }
      if (!await widget.bloc.flushNode(nodeId)) return false;
    }
    return true;
  }

  /// Called only after edits are saved, discarded, or already clean.
  /// PopScope can still have the previous dirty value until the next frame;
  /// maybePop would invoke the guard again and loop before that frame runs.
  void _popEditor() {
    if (!mounted || ModalRoute.of(context)?.isCurrent != true) return;
    final navigator = Navigator.of(context);
    if (navigator.canPop()) navigator.pop();
  }

  /// Leaves to the canvas, confirming when edits are unsaved.
  Future<void> _maybeLeave() async {
    final bloc = widget.bloc;
    final dirty =
        bloc.hasUnsavedStoryEdits || bloc.hasUnsavedNodeEdits(widget.nodeId);
    if (!dirty) {
      _popEditor();
      return;
    }
    final choice = await showDialog<_LeaveChoice>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Unsaved changes'),
        content: const Text('Save your edits before leaving this scene?'),
        actions: [
          TextButton(
            key: const ValueKey('leave-stay'),
            onPressed: () => Navigator.pop(dialogContext, _LeaveChoice.stay),
            child: const Text('Keep editing'),
          ),
          TextButton(
            key: const ValueKey('leave-discard'),
            onPressed: () => Navigator.pop(dialogContext, _LeaveChoice.discard),
            child: Text(
              'Discard',
              style: TextStyle(color: RamificaColors.danger),
            ),
          ),
          FilledButton(
            key: const ValueKey('leave-save'),
            onPressed: () => Navigator.pop(dialogContext, _LeaveChoice.save),
            child: const Text('Save & exit'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    switch (choice) {
      case null:
      case _LeaveChoice.stay:
        return;
      case _LeaveChoice.discard:
        bloc.add(EditsDiscarded(nodeId: widget.nodeId));
        _popEditor();
      case _LeaveChoice.save:
        _stopScriptDictation();
        if (await _flushEdits(widget.nodeId) && mounted) {
          _popEditor();
        }
    }
  }

  /// Next visible logical step after [_stepIndex], or null on the last one.
  /// Children skip Scenes, so Info advances straight to Voice.
  int? _nextStep(bool isRoot) {
    final steps = wizardSteps(isRoot: isRoot);
    final at = steps.indexOf(_stepIndex);
    if (at < 0 || at >= steps.length - 1) return null;
    return steps[at + 1];
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
    _stopScriptDictation();
    setState(() {
      _premise = false;
      _stepIndex = index;
      _banner = null;
    });
  }

  void _leavePremise() {
    _stopScriptDictation();
    setState(() {
      _premise = false;
      _stepIndex = 0;
      _banner = null;
    });
  }

  Future<void> _onContinue(DraftNode node, bool isRoot) async {
    if (_premise && isRoot) {
      _premiseKey.currentState?.commit();
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
    if (!await _flushEdits(node.nodeId)) return;
    if (!mounted) return;
    final next = _nextStep(isRoot);
    if (next != null) {
      setState(() {
        _stepIndex = next;
        _banner = null;
      });
    } else {
      // Last step complete: back to the canvas.
      _popEditor();
    }
  }

  /// AppBar spark: proposes from the direction, narrows the answer to
  /// the active section, and previews it for Accept/Discard. Never
  /// advances the step. Failures surface once, as an error snackbar.
  Future<void> _onProposeForStep(DraftNode node, bool isRoot) async {
    if (_scriptProposing) return;
    final script = _scriptKey.currentState;
    if (script == null || !script.directionReady) return;
    final step = _stepIndex;
    setState(() => _scriptProposing = true);
    late final SceneProposal sliced;
    try {
      // Each section asks for its own scope: small shaped answers at
      // minimal reasoning, never the whole scene.
      final proposal = await script.proposeDirection(
        purpose: switch (step) {
          0 => 'info',
          1 => 'startframe',
          2 => 'narration',
          3 => 'clip',
          4 => 'options',
          _ => 'scene',
        },
      );
      if (!mounted || _stepIndex != step) return;
      if (proposal == null) {
        final reason = script.takeProposalError();
        showErrorSnackBar(
          context,
          reason ?? 'Could not propose for this section. Try again.',
        );
        return;
      }
      final section = sliceProposalForStep(
        proposal,
        step: step,
        isEnding: node.isEnding,
      );
      if (section == null) {
        showErrorSnackBar(
          context,
          'Spark had nothing for this section. '
          'Add more detail to the direction and try again.',
        );
        return;
      }
      sliced = section;
    } finally {
      // The spinner stops while the preview is reviewed.
      if (mounted) setState(() => _scriptProposing = false);
    }
    final accepted = await showFillPreview(
      context: context,
      step: step,
      proposal: sliced,
    );
    if (!mounted || _stepIndex != step || accepted != true) return;
    setState(() => _scriptProposing = true);
    try {
      final applied = await _applyProposal(node.nodeId, sliced);
      if (!mounted || _stepIndex != step) return;
      if (!applied) {
        showErrorSnackBar(
          context,
          widget.bloc.state.failure ??
              'Could not apply the proposal. Try again.',
        );
        return;
      }
      final fresh = widget.bloc.state.nodes.singleWhere(
        (n) => n.nodeId == node.nodeId,
        orElse: () => node,
      );
      final stillMissing = firstMissingForStep(
        step: step,
        node: fresh,
        isRoot: isRoot,
      );
      setState(() => _banner = stillMissing);
    } finally {
      if (mounted) setState(() => _scriptProposing = false);
    }
  }

  /// Dispatches the reviewed proposal and waits for persistence.
  Future<bool> _applyProposal(String nodeId, SceneProposal proposal) async {
    final completion = Completer<bool>();
    widget.bloc.add(
      SceneProposalApplied(
        nodeId: nodeId,
        proposal: proposal,
        completion: completion,
      ),
    );
    try {
      return await completion.future.timeout(const Duration(seconds: 30));
    } on TimeoutException {
      return false;
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

  @override
  Widget build(BuildContext context) {
    return BlocProvider.value(
      value: widget.bloc,
      child: BlocConsumer<CreateBloc, CreateState>(
        listener: (context, state) {
          // Settles on the terminal idle emission: the dispatch path goes
          // through a saving job first, so job != uploading would fire
          // early and re-snack a stale phrase.
          if (_uploadSnackArmed && state.job == CreateJob.none) {
            _uploadSnackArmed = false;
            if (state.failure case final failure?) {
              _snackedFailure = failure;
              showErrorSnackBar(context, failure);
            }
          }
          if (state.failure == null) _snackedFailure = null;
        },
        builder: (context, state) {
          final scene = sceneIndexes(state.nodes, state.story?.rootNodeId);
          final number = scene[widget.nodeId];
          final badges = levelBadges(state.nodes, state.story?.rootNodeId);
          final badge = badges[widget.nodeId];
          if (number == null) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (context.mounted) Navigator.of(context).maybePop();
            });
            return const Scaffold(body: SizedBox.shrink());
          }
          final node = state.nodes.firstWhere((n) => n.nodeId == widget.nodeId);
          if (_expiryAt != node.generationExpiresAt) {
            _expiryAt = node.generationExpiresAt;
            _generationExpiry?.cancel();
            final expiry = DateTime.tryParse(_expiryAt ?? '');
            if (expiry != null && expiry.isAfter(DateTime.now())) {
              _generationExpiry = Timer(
                expiry.difference(DateTime.now()) +
                    const Duration(milliseconds: 10),
                () {
                  if (mounted) setState(() {});
                },
              );
            }
          }
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
          final incoming = _incomingChoice(parent, state.nodes, widget.nodeId);
          // One continue action, mounted only by the active step.
          bool stepActive(int logical) =>
              !showPremise &&
              stepIndex == logical &&
              !_previewOpen &&
              !_childOpen;
          // Continue never spins for the spark (its flush included):
          // the AppBar button shows its own spinner, and stepping away
          // mid-propose aborts it.
          final continueAction = WizardContinueButton(
            busy: busy && !_scriptProposing,
            onContinue: () => _onContinue(node, isRoot),
            isLastStep: !showPremise && stepIndex == wizardStepCount - 1,
          );
          final dirty =
              widget.bloc.hasUnsavedStoryEdits ||
              widget.bloc.hasUnsavedNodeEdits(widget.nodeId);
          return PopScope(
            canPop: !dirty,
            onPopInvokedWithResult: (didPop, _) {
              if (!didPop) _maybeLeave();
            },
            child: Scaffold(
              backgroundColor: RamificaColors.surface,
              appBar: AppBar(
                backgroundColor: RamificaColors.surface,
                surfaceTintColor: Colors.transparent,
                elevation: 0,
                centerTitle: false,
                leading: IconButton(
                  key: const ValueKey('wizard-leave'),
                  tooltip: 'Back to scenes',
                  icon: const Icon(Icons.chevron_left, size: 28),
                  color: RamificaColors.textPrimary,
                  onPressed: _maybeLeave,
                ),
                titleSpacing: 0,
                title: Column(
                  crossAxisAlignment: .start,
                  mainAxisSize: .min,
                  children: [
                    Text(
                      isRoot
                          ? ((state.story?.title.trim().isNotEmpty ?? false)
                                ? state.story!.title.trim()
                                : 'Untitled story')
                          : (node.title.trim().isNotEmpty
                                ? node.title.trim()
                                : 'Untitled scene'),
                      style: RamificaText.headlineSM,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Row(
                      mainAxisSize: .min,
                      children: [
                        Text(
                          badge == null || badge.isEmpty
                              ? 'Scene $number'
                              : node.isEnding
                              ? '$badge · Final'
                              : badge,
                          key: const ValueKey('scene-level-badge'),
                          style: RamificaText.meta,
                        ),
                        if (isRoot) ...[
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              node.title.trim().isNotEmpty
                                  ? node.title.trim()
                                  : 'Untitled scene',
                              style: RamificaText.meta,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ] else if (incoming != null) ...[
                          const SizedBox(width: 6),
                          Flexible(
                            child: _IncomingChoiceLabel(
                              choice: incoming.choice,
                              index: incoming.index,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
                actions: [
                  // Section fill: proposes from the direction for the
                  // active step only, then previews for Accept/Discard.
                  if (!showPremise)
                    IconButton(
                      key: const ValueKey('wizard-fill-section'),
                      tooltip: 'Propose for this section',
                      icon: _scriptProposing
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.auto_awesome, size: 22),
                      color: RamificaColors.textPrimary,
                      onPressed:
                          busy ||
                              _scriptProposing ||
                              !(_scriptKey.currentState?.directionReady ??
                                  false) ||
                              (stepIndex == 4 && node.isEnding)
                          ? null
                          : () => _onProposeForStep(node, isRoot),
                    ),
                  if (node.videoStatus == 'ready' &&
                      (node.videoUrl ?? '').isNotEmpty)
                    IconButton(
                      key: ValueKey('preview-node-${widget.nodeId}'),
                      tooltip: 'Preview',
                      icon: const Icon(Icons.visibility, size: 22),
                      color: RamificaColors.textPrimary,
                      onPressed: busy
                          ? null
                          : () async {
                              _stopScriptDictation();
                              setState(() => _previewOpen = true);
                              try {
                                final current = widget.bloc.state;
                                final previewNode = current.nodes.firstWhere(
                                  (item) => item.nodeId == widget.nodeId,
                                  orElse: () => node,
                                );
                                final auth = widget.bloc.auth;
                                final story = current.story;
                                await showCreatePreview(
                                  context,
                                  node: previewNode,
                                  story: story,
                                  authorName:
                                      auth?.auth.currentIdentity?.displayName,
                                  nodes: current.nodes,
                                  rootNodeId: story?.rootNodeId,
                                  authorNameLookup:
                                      auth == null || story == null
                                      ? null
                                      : _previewAuthorName(
                                          auth,
                                          story.authorId,
                                        ),
                                  // The notice chevron on an unfinished
                                  // target: close the preview and open that
                                  // node for editing. Editors below the hub
                                  // are dropped, so back returns to the
                                  // scene hub instead of stacking editors.
                                  onOpenNode: (targetId) async {
                                    widget.bloc.add(NodeSelected(targetId));
                                    _stopScriptDictation();
                                    setState(() => _childOpen = true);
                                    Navigator.of(
                                      context,
                                      rootNavigator: true,
                                    ).pop();
                                    await Navigator.of(context)
                                        .pushAndRemoveUntil(
                                          MaterialPageRoute(
                                            builder: (_) => CreateNodeScreen(
                                              bloc: widget.bloc,
                                              nodeId: targetId,
                                              pickVideo: widget.pickVideo,
                                              newTakeId: widget.newTakeId,
                                            ),
                                          ),
                                          (route) => route.isFirst,
                                        );
                                    if (mounted) {
                                      setState(() => _childOpen = false);
                                    }
                                  },
                                );
                              } finally {
                                if (mounted) {
                                  setState(() => _previewOpen = false);
                                }
                              }
                            },
                    ),
                  const SizedBox(width: 8),
                ],
              ),
              body: SafeArea(
                // Horizontal page padding lives on each scrollable and
                // section, never outside: the scrollbar travels over
                // padding instead of content.
                child: Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Column(
                    crossAxisAlignment: .stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: WizardHeader(
                          sceneNumber: number,
                          sceneTotal: state.nodes.length,
                          title: node.title,
                          status: state.statusOf(widget.nodeId),
                          stepIndex: showPremise ? -1 : stepIndex,
                          firstIncomplete: firstIncomplete,
                          isRoot: isRoot,
                          showIdea: isRoot,
                          ideaCurrent: showPremise,
                          ideaDone: !showPremise && _ideaFilled(state, node),
                          onIdea: () => _openIdea(isRoot),
                          onStepTap: (index) => _goTo(index, node, isRoot),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Expanded(
                        child: showPremise
                            ? Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  16,
                                  0,
                                  16,
                                  16,
                                ),
                                child: WizardPremise(
                                  key: _premiseKey,
                                  continueAction: continueAction,
                                ),
                              )
                            : IndexedStack(
                                index: wizardDisplayIndex(
                                  step: stepIndex,
                                  isRoot: isRoot,
                                ),
                                children: [
                                  Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                      16,
                                      0,
                                      16,
                                      16,
                                    ),
                                    child: StepScript(
                                      key: _scriptKey,
                                      node: node,
                                      isRoot: isRoot,
                                      busy: busy,
                                      showErrors: _showErrors[0],
                                      active: stepActive(0),
                                      continueAction: continueAction,
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
                                      propose:
                                          (direction, {purpose}) async {
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
                                              purpose: purpose ?? 'scene',
                                            );
                                      },
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
                                      onDirectionChanged: (value) => _edited(
                                        () => widget.bloc.add(
                                          NodeFieldChanged(
                                            nodeId: widget.nodeId,
                                            sceneDirection: value,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                  if (isRoot)
                                    _StepScroll(
                                      child: StepFrames(
                                        generatingWhich:
                                            state.generating(
                                              widget.nodeId,
                                              'startImage',
                                            )
                                            ? 'start'
                                            : null,
                                        phase: state.operationPhase == 'saving'
                                            ? 'saving'
                                            : node.generationPhase ??
                                                  state.operationPhase,
                                        node: node,
                                        busy: busy,
                                        showErrors: _showErrors[1],
                                        active: stepActive(1),
                                        continueAction: continueAction,
                                        onStartPromptChanged: (value) =>
                                            _edited(
                                              () => widget.bloc.add(
                                                NodeFieldChanged(
                                                  nodeId: widget.nodeId,
                                                  startImagePrompt: value,
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
                                  Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                      16,
                                      0,
                                      16,
                                      16,
                                    ),
                                    child: StepVoice(
                                      active: stepActive(2),
                                      continueAction: continueAction,
                                      generating: state.generating(
                                        widget.nodeId,
                                        'voice',
                                      ),
                                      phase: state.operationPhase == 'saving'
                                          ? 'saving'
                                          : node.generationPhase ??
                                                state.operationPhase,
                                      onLineChanged: (value) => _edited(
                                        () => widget.bloc.add(
                                          NodeFieldChanged(
                                            nodeId: widget.nodeId,
                                            ttsText: value,
                                          ),
                                        ),
                                      ),
                                      node: node,
                                      busy: busy,
                                      showErrors: _showErrors[2],
                                      onVoiceGenerate: () => _runMedia(
                                        () => widget.bloc.add(
                                          VoiceGenerateRequested(widget.nodeId),
                                        ),
                                      ),
                                    ),
                                  ),
                                  Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                      16,
                                      0,
                                      16,
                                      16,
                                    ),
                                    child: StepClip(
                                      active: stepActive(3),
                                      continueAction: continueAction,
                                      generating: state.generating(
                                        widget.nodeId,
                                        'video',
                                      ),
                                      phase: state.operationPhase == 'saving'
                                          ? 'saving'
                                          : node.generationPhase ??
                                                state.operationPhase,
                                      node: node,
                                      busy: busy,
                                      showErrors: _showErrors[3],
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
                                              try {
                                                final picked =
                                                    await widget.pickVideo!();
                                                if (!context.mounted ||
                                                    picked == null) {
                                                  return;
                                                }
                                                _runMedia(() {
                                                  _uploadSnackArmed = true;
                                                  widget.bloc.add(
                                                    VideoUploadRequested(
                                                      nodeId: widget.nodeId,
                                                      contentType:
                                                          picked.contentType,
                                                      bytes: picked.bytes,
                                                      takeId: widget
                                                          .newTakeId(),
                                                    ),
                                                  );
                                                });
                                              } on AppFailure catch (error) {
                                                if (context.mounted) {
                                                  showErrorSnackBar(
                                                    context,
                                                    error.hint,
                                                  );
                                                }
                                              } catch (_) {
                                                if (context.mounted) {
                                                  showErrorSnackBar(
                                                    context,
                                                    'Could not read the selected clip. Try again.',
                                                  );
                                                }
                                              }
                                            },
                                    ),
                                  ),
                                  _StepScroll(
                                    child: StepHotspots(
                                      node: node,
                                      busy: busy,
                                      showErrors: _showErrors[4],
                                      active: stepActive(4),
                                      continueAction: continueAction,
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
                                      onOpenChild: (targetId) async {
                                        widget.bloc.add(NodeSelected(targetId));
                                        // Covered players must not keep
                                        // playing behind the child screen.
                                        _stopScriptDictation();
                                        setState(() => _childOpen = true);
                                        await Navigator.of(context).push(
                                          MaterialPageRoute(
                                            builder: (_) => CreateNodeScreen(
                                              bloc: widget.bloc,
                                              nodeId: targetId,
                                              pickVideo: widget.pickVideo,
                                              newTakeId: widget.newTakeId,
                                            ),
                                          ),
                                        );
                                        if (mounted) {
                                          setState(() => _childOpen = false);
                                        }
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
                                ],
                              ),
                      ),
                      if (state.failure != null &&
                          state.failure != _snackedFailure)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                          child: FailureText(message: state.failure!),
                        )
                      else if (_banner != null)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                          child: WizardBanner(text: _banner!),
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
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
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

/// Incoming choice into [nodeId] with its index in the linking parent,
/// for the AppBar choice chip. Prefers the recorded parent's link; falls
/// back to the first choice anywhere pointing at the node, so legacy
/// nodes without `startFromNodeId` still show it. Null for the root and
/// unlinked nodes.
({DraftChoice choice, int index})? _incomingChoice(
  DraftNode? parent,
  List<DraftNode> nodes,
  String nodeId,
) {
  if (parent != null) {
    for (var i = 0; i < parent.choices.length; i++) {
      if (parent.choices[i].targetNodeId == nodeId) {
        return (choice: parent.choices[i], index: i);
      }
    }
  }
  for (final node in nodes) {
    for (var i = 0; i < node.choices.length; i++) {
      if (node.choices[i].targetNodeId == nodeId) {
        return (choice: node.choices[i], index: i);
      }
    }
  }
  return null;
}

/// AppBar label for the choice taken to reach a child: the author's
/// icon and label in the author's color. Empty labels read `Option A/B`.
class _IncomingChoiceLabel extends StatelessWidget {
  const _IncomingChoiceLabel({required this.choice, required this.index});

  final DraftChoice choice;
  final int index;

  @override
  Widget build(BuildContext context) {
    final accent = choiceIconColor(
      choice.iconColor,
      choice.slot == 'B' ? RamificaColors.nodeActive : RamificaColors.hotspot,
    );
    final label = choice.label.trim().isNotEmpty
        ? choice.label.trim()
        : 'Option ${(choice.slot?.trim().isNotEmpty ?? false) ? choice.slot!.trim() : (index == 0 ? 'A' : 'B')}';
    return Row(
      key: const ValueKey('incoming-choice'),
      mainAxisSize: .min,
      children: [
        Icon(choiceIconData(choice.icon, index), size: 12, color: accent),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            label,
            style: RamificaText.meta.copyWith(color: accent),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

/// True when the root idea was committed: synopsis, else the narrator line.
bool _ideaFilled(CreateState state, DraftNode node) {
  final synopsis = state.story?.synopsis.trim() ?? '';
  if (synopsis.isNotEmpty) return true;
  return node.ttsText.trim().isNotEmpty;
}

Future<String> _previewAuthorName(AuthRepository auth, String authorId) async {
  try {
    final name = (await auth.users.read(authorId))?.displayName?.trim() ?? '';
    return name.isEmpty ? 'Unknown' : name;
  } catch (_) {
    final name = auth.auth.currentIdentity?.displayName?.trim() ?? '';
    return name.isEmpty ? 'Unknown' : name;
  }
}
