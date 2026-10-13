# Garden: look, rendering and cost

Date of research: 2026-10-13. macOS 26.6, Apple M4, Command Line Tools only (no Xcode, no Metal compiler). Two literature passes (Terra Nil's look and free asset sets; low-cost rendering on macOS), then spikes and measurements in the app itself. The resulting rules are in `docs/design.md`, Garden.

## Why

The brief asked for a garden like Terra Nil's that grows with consistent focus, on the right of the Focus window. It has to look good and cost nothing during a session, whose budget (3% CPU, 200 MB) the camera already uses most of.

## Look

- **Terra Nil** (Free Lives, Unity) is hand-painted 2.5D: Steam tags it Colorful, Stylized, Isometric and 2.5D, and describes "lush hand-painted environments" ([Steam](https://store.steampowered.com/app/1593030/Terra_Nil/)). Barren land turns green as you restore it. Its own assets are out: extraction tools exist (AssetRipper), but its README warns that using the output may breach copyright ([GitHub](https://github.com/AssetRipper/AssetRipper)).
- **Free sets compared**: Kenney Nature Kit (CC0, 329 models: trees, rocks, ground blocks, plants), Kenney Hexagon Kit (CC0), Quaternius nature and animals (CC0 on mirrors, to check per pack), KayKit Forest (free tier CC0).
- **Chosen**: the Kenney Nature Kit 2.1 alone, so one author and one low-poly language. 49 of its models (about 400 KB of OBJ and MTL) in `Resources/Garden`, recoloured in code by material name to a natural palette. Its ground and cliff blocks are square, so the island is an 11 × 11 grid. Three shades per ground colour make the land read as patches rather than a checkerboard. The kit's waterfall model looked wrong at this scale; the stream ends in a thin sheet of water down the island's side instead. The stream grows first (dug, then filled, tile by tile from the spring), with its river pieces turned to join only the tiles already dug: a closed pool (`ground_riverTile`) for the first one, the kit's rounded end at the front, so an unfinished stream never shows the finished stream's borders.
- **Camera**: orthographic 2:1 dimetric (45° around, atan ½ down), one sun with soft shadows (16 samples). The same picture serves light and dark mode, on a quaternary box.

## Rendering

The rendering research compared the options for a panel that is usually static:

| Option | Verdict |
|---|---|
| Static bitmap plus Core Animation layers | Recommended: a still layer costs nothing per frame, and Core Animation runs committed animations in the render server, not the app |
| SwiftUI `Canvas` in a `TimelineView` | Redraws everything on the CPU every frame |
| SpriteKit | Its render loop keeps the GPU busy while it runs |
| Raw Metal | Needs compiled shaders; `xcrun --find metal` fails here (exit 72), so no `.metallib` can be built |
| SceneKit | Deprecated at WWDC 2025 (session 288), still shipping and working on macOS 26 |
| Pre-rendered sprites from Blender | Blender is not installed, and a large download |

So the garden is one composed bitmap, drawn by SceneKit's offscreen `SCNRenderer` (it loads the OBJ files without Xcode) only when the growth step changes, about once per perfect session, and cached as `garden.png` with `garden.json` (renderer version, step, total steps, each tile's centre). Both are generated output in the app's cache, not files in the repo. A render of the whole island at 1040 × 800 px takes 30–130 ms on the M4, about 270 ms the first time.

**Memory decided where it runs.** Rendering in the app took its footprint from 30 MB to a 175 MB peak and left it at 56 MB after the renderer was released: about 26 MB of SceneKit and Metal state stays, and it would have been carried into the next session, which already runs near 190 MB of its 200 MB. The app now runs its own binary with `--render-garden <steps> <dir>`; the child renders, writes the cache and exits, and the app reads the PNG with ImageIO. Measured with `--garden-demo` (two pictures drawn): 25.7 MB before drawing, 25.8 MB after. The child takes 0.15–1.5 s from launch to exit (most of it waiting on Metal; 0.03–0.06 s of its own CPU) and peaks at about 160 MB, all released when it exits. It lives only while it draws, so it is not a background helper.

## Animation

Everything moving is Core Animation, built once per event: the reveal (the new picture on top, masked by circles expanding from the tiles that grew, 1.2 s, with a sparkle on each), withering (a 3 s fade), the leaf burst on a level-up, and life (butterflies from flowering tiles, birds leaving mature trees) for 20 s after the window comes into view. Everything stops while the window is covered or minimised (`NSWindow.didChangeOcclusionStateNotification`) and during a session.

For the snapshots, `CARenderer` produced blank frames on macOS 26.6, even for a plain red layer (tried flushing, running the run loop, colour spaces, and a managed texture with a blit). The stage frames (`stage-*.png`, generated snapshots, not files in the repo) are drawn instead from the presentation tree of the view in an offscreen window (`presentation().render(in:)`); `render(in:)` leaves out masks, so the circles do not show in those frames.

## Cost

Measured on the release bundle by interleaving 30 s with nothing open and 30 s of `Focus --garden-demo`: WindowServer's CPU from its cumulative CPU time, the app's the same way, GPU from `ioreg` ("Device Utilization %") every second. The demo is a worst case: a reveal every 10 s, growing and withering in turn, with life running throughout; in use a reveal plays once per session and life for 20 s. Temporary switches turned the reveals, life and the card off one at a time. Rounds taken while the terminal was busy, or while the Mac was in use, were too noisy (idle WindowServer 7–17%) and are left out. The quiet rounds:

| 30 s window | WindowServer CPU | GPU | App CPU |
|---|---|---|---|
| Nothing open (12 windows) | 2.2–5.2% | 0.4–2.3% | — |
| Still picture: no reveals, no life (2) | 16.8%, 15.8% | 2.5%, 1.5% | 0.03% |
| Reveals and card, no life (2) | 17.4%, 13.5% | 2.9%, 3.1% | 2.0%, 0.9% |
| Reveals and life, no card (2) | 14.1%, 14.6% | 1.6%, 1.0% | 0.06%, 0.03% |
| Everything (6) | 13.2–20.9% | 1.4–5.2% | 0.6–1.8% |

- **The window, not the garden.** In every run the demo had activated the app, so the window was key with the cursor in the task field, and the still picture cost as much as everything: about 12 points of WindowServer. The static window's Core Animation tree has exactly one running animation, the system's text cursor (`NSTextInsertionIndicator`, 1 s, repeating forever), and none once the field loses focus. That cost is macOS's animated cursor in the key window, the same as typing in any app; it stops as soon as another app is in front, as during a session, and Focus never makes its window key by itself. The demo now clears the first responder so the cursor no longer hides the garden's cost.
- **The garden's animations** add nothing measurable on top: the variants differ by less than the noise (about 2 points), and GPU by about 1.5 points at most. Reveals and life cost the app 0.03–0.06%, because Core Animation runs them in the render server; the reward card's count-up is what costs the app 1–2% while it plays.
- **Memory**: drawing adds 0.1–0.2 MB to the app (the child holds the renderer). The footprint goes from 25–31 MB to 33–36 MB with the still window, and to 37–45 MB with everything playing (both pictures and the effect layers).
- **During a session** nothing animates, so the garden adds no CPU; its memory is the decoded picture (1040 × 800 × 4 bytes, about 3.3 MB) and the window.
- **Not done**: a quiet run of the demo without the cursor. The Mac was in use again before it could run, and the variants above already separate the garden from the cursor.
