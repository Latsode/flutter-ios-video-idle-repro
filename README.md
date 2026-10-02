# iOS video idle-cost repro

Standalone reproduction for the Realize iOS report: after browsing feed videos the
whole app becomes laggy (scrolling frame by frame, other screens slow).

Suspected cause: `PostVideo` initializes a `VideoPlayerController` as soon as the
card is built but shows only the thumbnail until play is tapped. In
`video_player_avfoundation` (2.8.4, unchanged in 2.12.0) registering the texture
starts a `CADisplayLink` that only stops after the engine pulls a frame from the
texture. A texture that is never shown is never pulled, so every vsync calls
`textureFrameAvailable` and the engine redraws the last frame forever.

Before `video_player_avfoundation` 2.9.4 the display link also kept running after
the controller was disposed, so the cost outlived the feed card.

Each app launch runs one card implementation in a 12-card feed that the app
scrolls by itself. Phases: `baseline` (no feed), `active` (after browsing 6
steps), `play` (tap play on the most visible card, measure time until playback
advances, pause), `paused`, `scrolledOn` (4 more steps) and `afterDispose` (feed
removed). Idle cost is measured in each phase except `play`.

| Scenario | Card implementation |
|---|---|
| eagerThumbnail | Current Realize `PostVideo`: initialize in `initState`, thumbnail only |
| coveredWarm | Initialize in `initState`, video painted under an opaque thumbnail (feed without cache extent) |
| proposed | Initialize as soon as any part is visible, video painted under an opaque backdrop and the thumbnail, released when fully off screen |
| lazy | Initialize only when play is tapped |

CI runs it with Realize `dev` versions (Flutter 3.47.5, avfoundation 2.8.4) and
with the latest `video_player`.

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
