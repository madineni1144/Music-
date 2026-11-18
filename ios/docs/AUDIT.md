# M&M Music iOS — Audit and Fix Report

Branch: `feature/ios-audit-fixes` (child of `feature/ios-development`). Base commit audited: `660041c`.
Line numbers below refer to the base commit unless stated.

## Verification status (read this first)

The code was written on a Linux workspace with no Swift toolchain, Xcode or device. Compilation and tests were then run on GitHub-hosted runners through the `iOS CI` workflow.

| Check | Result |
|---|---|
| App compiles | **Passed.** Unsigned Debug build for iOS Simulator on `macos-15` ([run 43990824554](https://github.com/madineni1144/Music-/actions/runs/43990824554)). Strict-concurrency warnings were not reviewed. |
| `MusicLibrary` tests (10, iOS Simulator via `xcodebuild test`) | **Passed** ([run 44387813958](https://github.com/madineni1144/Music-/actions/runs/44387813958)). |
| `swift test` (46 tests) | **Passed on Linux** (Swift 5.10, [run 43990622421](https://github.com/madineni1144/Music-/actions/runs/43990622421)) **and on macOS** (same run as the build). 0 failures. |
| On-device behavior (lock screen, Bluetooth, interruptions, performance) | **Not verified.** Needs a physical iPhone. |
| `Info.plist` parses as valid XML plist | Passed (Python `plistlib`) |
| `git diff --check` | Passed |
| Delimiter balance on all Swift files | Passed (crude script, not a compiler) |
| Backend contracts (songs, albums, playlists, lyrics) | Checked by reading `backend/*.js`; the live server was not contacted |

Each finding is labeled **Confirmed** (proven by reading code or contracts), **Suspected** (plausible, needs a device or profiler), or **Not implemented** (feature absent).

## Prioritized findings

### Fixed in this branch

| # | Sev | Status | Where | Finding | Fix |
|---|---|---|---|---|---|
| 1 | High | Confirmed | `MusicLibrary.loadLyrics` (74-98), `ContentView` LyricsPanel (1237) | The app requested `/api/lyrics?song_id=`, which the backend does not serve (it serves `GET /api/songs/:id/lyrics`, `backend/madineni-lyrics.cjs:226`; unknown paths hit the JSON 404 at `server.js:1128`). The parser also ignored `data.syncedLyrics`, the field the backend returns. Lyrics could not work against this backend. | Use the real route; `LyricsPayload.lrc(from:)` reads `syncedLyrics` and still accepts the legacy shapes. `null` synced lyrics now show "unavailable". Tests added. |
| 2 | High | Confirmed | `Info.plist:25-29` | `NSAllowsArbitraryLoads = true` turns off App Transport Security for every host. The default server and all external URLs are HTTPS. | Replaced with `NSAllowsLocalNetworking`. **Behavior change:** `http://` to a public hostname is now blocked; IP addresses and `.local` names still work. Revert if you serve over plain HTTP on a real domain. |
| 3 | Medium | Suspected | `MusicPlayer` interruption handler (70-83) | `resumeAfterInterruption = self.playing`. The system pauses the player before the handler hops to the main actor, so `playing` can already be false and playback would not resume after a call. | Capture `wantsPlayback` (the user's intent) instead. Needs a real call/Siri test on device. |
| 4 | Medium | Suspected | `ContentView:59` | `onChange(of: tab)` resets `navigationPath`, but the app pushes screens with destination-style `NavigationLink`, which the path does not track. A pushed album could stay on screen after switching tabs. | `.id(tab)` on the stack gives each tab a fresh stack. Needs a UI check. |
| 5 | Medium | Confirmed | `PlaybackQueue.shuffleUpcoming` (46-49) | Shuffle used the global RNG, so it could not be tested deterministically. | `shuffleUpcoming(using:)` takes a generator; the old call still works. Seeded tests added. |
| 6 | Low | Confirmed | `MusicPlayer:60` | Full Now Playing dictionary rebuilt and published every 0.5 s. | Periodic refresh now at most every 5 s; state changes and seeks still publish immediately. No measurement was taken, so no savings are claimed. |
| 7 | Low | Confirmed | `MusicLibrary.loadPlaylistSongs` (189) | Linear catalog scan per playlist row (O(n·m)). | Dictionary lookup. Same results; no measurement. |
| 8 | Low | Confirmed | `ContentView` AudioSpectrum (1203) | Decorative animation ignored Reduce Motion. | Paused when Reduce Motion is on. |

### Open — needs your decision or a device

| # | Sev | Status | Where | Finding and recommendation |
|---|---|---|---|---|
| 9 | **High** | Confirmed | `MusicLibrary.playlistRequest` (219-238); `backend/server.js:49,700,840,919,987` | The app sends **no Authorization header** on playlist writes, and on this branch the backend has no auth middleware (and open CORS). You have decided write routes must require auth that fails closed. Once the backend does that, create/add/remove/delete playlist in the app will return 401/403. **Release blocker for the pair.** Proposal for approval: an optional token field in Server settings, held in memory only, sent as the header the backend defines, on POST/DELETE only. I did not implement it because the header contract is the backend's to define. |
| 10 | High | Suspected | `MusicPlayer:51-62`; `ContentView` 149-153, 531-536, 604-605 | `elapsed` is `@Published` and updates twice a second, and nearly every view holds the player as `@EnvironmentObject`. `ExploreScreen.songs`, `LibraryScreen.songs` and `HomeScreen.artists` are computed properties that filter, sort or group the whole library on every body evaluation. During playback that could mean O(library) work on the main thread at 2 Hz, i.e. jank on large libraries. **Not measured.** Recommended: move `elapsed` to a small `PlaybackClock` object observed only by the mini player, Now Playing and lyrics; cache filtered/sorted lists in `@State` and update on change. Profile first with Instruments (SwiftUI + Time Profiler). Left alone because it is a cross-file refactor that I cannot compile here. |
| 11 | Medium | Confirmed | `server.js:809` vs `MusicLibrary:332` | The backend still orders playlist songs by `ps.id`; the app contains a message telling the user to edit `server.js` to `ps.song_id` if the column is missing. A server-source instruction should not appear in an app alert. Confirm the production schema; any backend change needs your approval. |
| 12 | Medium | Suspected | `MusicPlayer:141-147` | End-of-track guard fails playback if the catalog `duration_seconds` is more than 5 s longer than the played time. If durations in the database are inaccurate, the song ends with an error and the queue does not advance. Verify stored durations; consider comparing against `AVPlayerItem.duration`. |
| 13 | Medium | Suspected | `MusicPlayer` | No handling of `AVAudioSession.mediaServicesWereResetNotification` and no `scenePhase` handling. After a media-services reset, playback needs the session and player rebuilt. |
| 14 | Medium | Partly fixed | — | `MusicLibrary` networking now has 10 simulator tests (`ios/MadineniMusicTests`, stubbed `URLProtocol`, no real server): pagination, error handling, the lyrics route, playlist write routes and bodies, and favorites. Still uncovered: `MusicPlayer` (uses `AVPlayer` directly; needs a small protocol seam) and `ArtworkLoader`. |
| 15 | Low | Confirmed, **fixed** | `MusicModels:55`; `ContentView:1242-1248` | `LyricLine.id = "\(time)-\(text)"` could collide, giving duplicate `ForEach` IDs. The lyrics list now identifies rows by position. |
| 16 | Low | Confirmed | `ContentView:820` | Queue rows use `id: \.offset`; identity follows position, so reorder/remove animations can glitch. Reordering is context-menu only (no drag handles); the queue help text says "Hold". |
| 17 | Low | Confirmed | `MusicLibrary:38,69-71` | Favorites are stored by song ID only, so switching servers can mark unrelated songs. Favorites are device-local; the backend has no favorites route. |
| 18 | Low | Confirmed | `MusicLibrary.publish` (111-115) | Album artwork map is fetched only when the server changes, so a pull-to-refresh on the same server does not pick up new covers until relaunch. |
| 19 | Low | Confirmed | `ArtworkLoader:19-21` | The 10 MB cap is checked after the whole body downloads. |
| 20 | Low | Confirmed | `MusicPlayer:350-364` | Remote-command targets are never removed. Harmless today (one player instance) but would duplicate actions if a second instance were ever created. |
| 21 | Low | Suspected | `ContentView:93-98` | One alert shows player, library and playlist errors, while the same errors also appear inline in places (duplicate messages). |

### Not implemented (feature gaps, not bugs)

Queue persistence across launches; keeping playlist/"mood" context with the queue (the "Mood" chip is just the playlists list, and the backend has no mood endpoint); in-app volume slider (system volume is used); offline catalog cache (the app shows nothing without the server); persistent shuffle mode with un-shuffle; skip-forward/back remote commands; light appearance (forced dark with a hard-coded palette); iPad and landscape (iPhone, portrait only by project setting); duplicate prevention in the queue (duplicates are currently allowed — a product decision). `/api/trending` exists on the backend but the app uses Apple's chart feed instead.

## Areas reviewed with no defect found

Pagination and progressive loading in `MusicLibrary.loadCatalog` (matches the bare-array `/api/songs` response and the `{success,data}` envelopes); repeat/shuffle/previous rules in `PlaybackQueue`; stale-response protection in artwork, trending and seek code (generation IDs); `ServerAddress` same-origin and path-traversal checks; cache bounds in `ArtworkLoader` (NSCache with count and cost limits); external URLs are validated (`music.apple.com`, `*.mzstatic.com`, https-only update links). No credentials or tokens appear in the Swift sources, and the app does no logging at all (nothing leaks, but there is also no diagnostics).

## Release readiness

| Item | State |
|---|---|
| Deployment target | iOS 17.0, iPhone only (`TARGETED_DEVICE_FAMILY = 1`), Swift 5 mode |
| Background audio | `UIBackgroundModes = audio` and `.playback` session present; no entitlements file needed |
| Local network | `NSLocalNetworkUsageDescription` present |
| App icon | 1024×1024 `AppIcon.png` present |
| Signing | Automatic, no team set (select your team in Xcode) |
| Privacy manifest | Added `PrivacyInfo.xcprivacy` (no tracking, no collected data, `UserDefaults` reason CA92.1) and wired it into the project; CI verifies it is bundled in the built app. Re-check the declared reasons if you add APIs such as file timestamps or disk space |
| **Blocker for the pair** | Finding 9 (auth) |
| Not done | `SWIFT_STRICT_CONCURRENCY=targeted` build to see concurrency warnings; Instruments profiling; device test of lock screen, Bluetooth, interruptions and route changes |

## Tests added (56, all passing in CI)

`ios/CoreLogic` is a SwiftPM package that compiles `PlaybackQueue.swift`, `MusicModels.swift` and `ReleaseModels.swift` from the app target through symlinks (one copy of the code, no `.pbxproj` edits). 46 tests cover:

- **Queue:** start/jump bounds, next/previous rules, repeat one/all, insert next, append, remove and reorder limits, clear, seeded shuffle (keeps played and current in place, reproducible, no-op for ≤1 upcoming), default shuffle keeps the same songs.
- **Models:** loose server types, title fallback, invalid durations, display helpers, `SongPage` envelopes, catalog de-duplication and repeated-page detection, playlist decoding.
- **Addressing:** server URL parsing and normalization, same-origin rules, media-URL mapping and traversal rejection, cover fallback.
- **Lyrics:** LRC parsing (fractions, multiple tags, CRLF) and the backend payload shape (regression for finding 1).
- **Releases:** version validation and comparison.

Regression coverage exists for findings 1 and 5. Findings 2, 3, 4, 6 and 8 compile but need device or UI verification and cannot be unit-tested in this package. `MusicPlayer` and `ArtworkLoader` have no automated tests yet (finding 14).

## Commands to verify on a Mac

```sh
git fetch && git checkout feature/ios-audit-fixes

# 1. Logic tests (no Xcode project needed)
cd ios/CoreLogic && swift test

# 2. Compile the app for the simulator, unsigned
cd ../.. && xcodebuild -project ios/MadineniMusic.xcodeproj -target MadineniMusic \
  -sdk iphonesimulator -configuration Debug CODE_SIGNING_ALLOWED=NO build

# 3. Optional: surface concurrency warnings
xcodebuild -project ios/MadineniMusic.xcodeproj -target MadineniMusic \
  -sdk iphonesimulator -configuration Debug CODE_SIGNING_ALLOWED=NO \
  SWIFT_STRICT_CONCURRENCY=targeted build
```

Then on a device: play a song, lock the screen (Control Center/lock-screen metadata and controls), pull headphones out (should pause), take or simulate a call (should resume), switch tabs after opening an album (should show the new tab's root), and open Lyrics for a song the backend has synced lyrics for.

The same Linux test job runs automatically on pull requests into `feature/ios-development`; the macOS build is the manual **iOS CI** workflow in the Actions tab.

## Recommended order

1. Install this branch on a device and run the manual checks above (CI cannot cover them).
2. Decide the auth approach (finding 9) together with the backend change.
3. Profile playback on a large library, then do the `PlaybackClock` refactor (finding 10) if the profile confirms it.
4. Put `AVPlayer` behind a small protocol and add player tests to `MadineniMusicTests` (finding 14).
