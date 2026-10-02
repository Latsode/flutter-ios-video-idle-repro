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

Each app launch runs one scenario (`REPRO_SCENARIO`) through three 20-second
phases with no input: `baseline` (thumbnails only), `active` (scenario cards
built) and `afterDispose` (cards removed again).

| Scenario | Cards in `active` |
|---|---|
| eagerThumbnail | Controllers initialized, thumbnails only (Realize pattern) |
| eagerThumbnailUnderRoute | Same, with another screen pushed on top |
| eagerShown | Controllers initialized and video shown, paused |
| lazy | Controller created only on play tap (fix; never tapped) |

CI runs it twice: with Realize's versions (Flutter 3.27.4, avfoundation 2.8.4)
and with the latest `video_player`.

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
