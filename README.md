# iOS video idle-cost repro

Standalone reproduction for the Realize iOS report: after browsing feed videos the
whole app becomes laggy (scrolling frame by frame, other screens slow).

Suspected cause: `PostVideo` initializes a `VideoPlayerController` as soon as the
card is built but shows only the thumbnail until play is tapped. In
`video_player_avfoundation` (2.8.4, unchanged in 2.12.0) registering the texture
starts a `CADisplayLink` that only stops after the engine pulls a frame from the
texture. A texture that is never shown is never pulled, so every vsync calls
`textureFrameAvailable` and the engine redraws the last frame forever.

The app runs these 20-second phases with no input:

| Phase | What is on screen | Expected |
|---|---|---|
| controlIdle | Thumbnails, no controllers | idle |
| bugFeed | 3 cards, controllers initialized, thumbnails only (Realize pattern) | busy |
| bugUnderOtherScreen | Same cards, another screen pushed on top | busy |
| fixLazyInit | 3 cards, controller created only on tap (not tapped) | idle |
| shownThenPaused | 3 cards, controllers initialized and video shown, paused | idle |
| controlIdleEnd | Thumbnails again, controllers disposed | idle |

## Run without an iPhone or Mac

Push this repo to GitHub and run the `iOS Simulator idle-cost repro` workflow. The
job summary shows a table of average app CPU % per phase plus native stack
counts; raw `sample` dumps are in the `repro-results` artifact.

## Run on a Mac

```bash
flutter pub get
flutter build ios --simulator --debug
python3 tool/measure_ios_sim.py
```
