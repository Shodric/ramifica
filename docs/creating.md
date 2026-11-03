# Creating stories

The Create tab walks an author through each scene with a wizard. The single definition of "complete" is `firstMissingForStep` in `lib/features/create/steps/wizard_gates.dart`; the footer Continue and the stepper chips both read it. Step ids are logical and stable: Voice is always step 2, even on nodes that skip Scenes.

## Steps and gates

| Step | Needs to continue |
|---|---|
| Idea (root chip) | Nothing. The premise records the idea; it never gates Continue. |
| 0 · Info | A scene title (1–40 chars) plus the narrator line. |
| 1 · Scenes | The root start frame (`S`) ready. Children skip this step entirely. |
| 2 · Voice | A non-blank narrator line plus a generated voice (`ttsStatus` ready). |
| 3 · Clip | A generated clip (`videoStatus` ready). |
| 4 · Options | At least one option with labels 1–24 chars. Vacuous on endings. |

Continue names the first missing piece until the step is complete. Typing, step changes, and leaving the scene never schedule writes: manual edits stay local, marked Unsaved changes, until Save, Apply, or a generation request persists them.

## Root and children

The root carries the Idea chip and owns the Scenes step. Children skip Scenes and inherit `S` from the parent clip's last frame, so the Clip gate enforces the parent clip instead. Options sit last so zones land on the finished clip's last frame. Endings take an ending name (max 40) instead of choices.

Text limits are shared with the backend (`catalog.json`): title 40, narration 280, option labels 24, media prompts 2000, at most two choices.

## Generation and approval

Each medium is generated on the backend and approved by the author: text and scene proposals (`generateNodeText`, `proposeStoryOutline`), start/end frames (`generateNodeImage`), narration voice (`generateNodeVoice`), and the clip (`generateNodeVideo`). Prompts are editable before Generate; Another take keeps the previous take visible until a validated replacement arrives. Models and credentials are in [AI configuration](ai-configuration.md); formats and the upload path are in [Media pipeline](media-pipeline.md).

## Apply and choice icons

Apply fills only empty author fields and missing A/B branches, preserving existing choice IDs, destinations, geometry, defaults, and the manual title. Stable per-slot request IDs make retries safe and recover legacy orphans. After a successful apply the client fires one `decideChoiceIcon` call per unstyled choice and merges each answer only while the choice is still unstyled, so a late answer never overwrites a manual pick. A failed decision stays silent and the display fallback remains.

## Publish

Publishing requires saved edits and validates the graph in Dart (`functions/src/publish/validateStory.ts` mirrors the shape). It stages sanitized projections in batches under `publications/{id}`, then activates only if the story revision is still current. Staged publications stay unreadable to players.

## Worked example

[history.md](../history.md) is a complete branching tree — premise, cast, narrator lines, options, and prompts — with eight endings. Use it as the shape a finished story takes.
