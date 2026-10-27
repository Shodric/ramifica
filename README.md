# Ramifica

Vertical interactive video. A clip plays, then pauses. A narrator asks which decision the protagonist should take, and you choose by holding a point on the scene for one second.

Ramifica is a standalone demo for a Meta hackathon. The first version is a Flutter web app, installed as a PWA and hosted on Firebase.

## Architecture

Client layers, routes, and theme tokens: [docs/architecture.md](docs/architecture.md). Visual spec: [docs/design.md](docs/design.md).

Code, docs, and UI copy in this repo are English. The web build is `flutter build web` (dart2js, CanvasKit).

## Play

A story is a chain of vertical clips. Each clip carries the picture and sound of its scene, including dialogue when the scene has it.

At the decision point the video pauses and the clip's audio stops. An off-screen narrator asks what the protagonist should do and names the options. That voice is separate from the clip. With sound, the question is spoken. While muted, it appears as a subtitle.

You choose by holding a zone on the scene for one second. A circle grows from that point until it covers the frame. Letting go early cancels the choice. If the time to choose runs out, the story takes the default option through the same one-second transition.

The next clip starts from its first frame. The run is saved.

## Runs and the map

You can keep more than one run of the same story. A finished run stays on its ending card. Starting again from the beginning keeps the endings already unlocked.

The map shows where you have been. An unplayed branch is a lock, with no title and no image, until you reach it.

## This version

Phase 1 is the playable demo: one story you can watch, choose through, and resume. Video, narrator audio, and images live in Firebase Storage and play from URLs, so a clip can start before the file has finished downloading.

Sign-in is required. Google, or email and password.

The playable build is in progress.
