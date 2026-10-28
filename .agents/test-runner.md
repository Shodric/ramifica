# Test policy — OWNER RUNS ALL SUITES (2026-10-28)

Nobody else runs tests. Not workers, not sonic runners, not Main.
Agents verify with `flutter analyze` / `npm run lint` only (static, fast)
and then STOP. The owner executes every suite locally.

## Handoff (worker writes this and stops)

```json
{"ran": "lint|analyze only", "to_run": "<exact command>", "cwd": "<dir>"}
```

## Command catalog (for the owner)

| Suite | cwd | command | notes |
|---|---|---|---|
| functions | `functions/` | `npm run lint && npm test` | ~1 min |
| seed | `tools/seed` | `npm run build && npm run lint` | fast |
| analyze | repo root | `flutter analyze` | ~4 s, agents MAY run this |
| flutter test | repo root | `flutter test test/<f>.dart --reporter compact` | cold compile takes minutes; that is normal, not a hang |

`flutter` = `/Users/shodric/fvm/versions/3.47.8/bin/flutter` on PATH.
Emulator suites need the emulators service (project `demo-ramifica`).

## Why

Repeated agent-driven runs kept getting slower (cold compiles, retry
loops, redirect+wait polling spirals). Single runner = no duplication,
no burned tokens.
