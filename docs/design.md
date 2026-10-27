# Design

Visual spec for the Ramifica client. Product behavior stays in [architecture.md](architecture.md). When a type weight here disagrees with that file, architecture wins: Montserrat ships only at 700, for the story title, the ending name, and the screen title. Everything else is Plus Jakarta Sans 400, 600, or 700.

The font files are WOFF2 assets in `assets/fonts/`, subset latin and latin-ext. The app does not request them from Google Fonts at runtime. Both families are under the SIL Open Font License (`assets/fonts/OFL.txt`).

## Colors

| Token | Value | Use |
|---|---|---|
| `hotspot` | `#00F2FE` | Choice zone, active tab, primary button, portal ring. |
| `nodeActive` | `#4FACFE` | Visited node and map edge. |
| `nodeLocked` | `#2A2A38` | Lock and unexplored edge. |
| `surface` | `#131318` | Backgrounds. |
| `textPrimary` | `#FFFFFF` | Text. On video it gets the shadow below. |
| `textSecondary` | `#A0A0B0` | Meta. |
| `glass` | white at 12% | Bars, sheets, pills. |
| `glassBorder` | white at 18% | 1 px edge of a glass surface. |
| `error` | `#FFB4AB` | Failures. |

Text on video uses a black shadow at 75% opacity, offset 2 px, blur 8 px.

## Type

| Role | Family | Size | Weight | Line |
|---|---|---|---|---|
| Screen title | Montserrat | 28 | 700 | 34 |
| Body | Plus Jakarta Sans | 16 | 400 | 24 |
| Label | Plus Jakarta Sans | 14 | 600 | 18 |
| Meta | Plus Jakarta Sans | 12 | 400 | 16 |

## Glass

A floating surface is white at 12%, a 16 px blur, and a 1 px border of white at 18%. Cards use a 16 px corner radius. Pills and hotspots are full circles.

## Shared widgets

| Widget | Role |
|---|---|
| `GlassPanel` | The glass surface above. Padding defaults to 16. |
| `FailureText` | The phrase a bloc already wrote, in `error`, plus Retry when a callback is set. |
| `EmptyState` | One sentence. A button only when it has a label and a callback. |
| `StatusPill` | `idle`, `running`, `ready`, `failed`. |

## Surfaces still to build

These belong to later screens. The tokens above are what they use.

- A choice hotspot is a circle with a `#00F2FE` border. Holding it fills a ring for one second.
- The map sits on `surface`. A visited edge uses `nodeActive`. An unexplored edge uses `nodeLocked`.
- Creator inputs are white at 6% with a `glassBorder`. Focus moves the border to `hotspot`.
