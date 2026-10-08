# Contributing to Wingman

Thanks for helping! Wingman is a macOS menu-bar app that records and transcribes
meetings entirely on the Mac. It's open source under the [MIT license](LICENSE).
Bug reports, ideas and pull requests are all welcome — in English or Spanish.

## Ground rules

These are promises to the people who use Wingman; changes need to keep them:

- **Nothing leaves the Mac** except the speech-model downloads (Hugging Face) and the
  daily update check (this repo's releases). No accounts, analytics or telemetry.
  Problem reports are copied or opened by the user, never sent by Wingman.
- **The log (`~/Library/Logs/Wingman/wingman.log`) holds categories only:** what the
  app did, never audio, what was said, meeting titles, Meet codes, tab titles or
  addresses. Home-folder paths and note names are redacted (`Log.redacted`).
- **No private or undocumented APIs** — the Mac App Store may come later. Features
  the App Store wouldn't allow (reading other apps through Accessibility) are left out
  of the `APP_STORE` build with `#if !APP_STORE`.
- **Accessibility is read-only:** Wingman reads Teams'/Zoom's mute button and
  Chrome's tab strip; it never clicks, types or switches anything on in another app.
- **When unsure, keep the user's words:** a line that might be an echo is kept, marked,
  not deleted; a line the speech engine failed on is kept, marked.
- **Never claim what didn't happen:** "saved", "forgotten", "discarded" only after the
  disk operation worked; errors are shown, and logged as domain and code only.
- The app's text is in English, short and plain.

## Build and run

Requirements: a Mac with Apple silicon, macOS 26, and Swift 6.2 or later (Xcode, or
just the Command Line Tools).

```bash
./install.sh                     # builds, signs and installs to /Applications
DEST=~/Applications ./install.sh # somewhere else
open /Applications/Wingman.app
```

- Builds always pass `--disable-keychain`, so SwiftPM never asks for the keychain.
- Your build is signed ad hoc with a bundle-ID requirement, so macOS keeps its
  permissions across rebuilds. To macOS it's a different app from the official
  release, so you'll grant the permissions again the first time.
- **Builds from source don't update themselves** (`install.sh` clears the update
  key), so the next official release never replaces your changes.
- `RELEASE=1` leaves out the diagnostic tools; `APP_STORE=1` builds the App Store
  variant (no Accessibility features, no Sparkle, no tools).

## Tests

```bash
swift test --disable-keychain
```

The tests cover pure logic (Swift Testing). With only the Command Line Tools
installed, SwiftPM can't find the Testing framework on its own; add:

```bash
F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
swift test --disable-keychain -Xswiftc -F -Xswiftc $F -Xlinker -F -Xlinker $F \
  -Xlinker -rpath -Xlinker $F -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib
```

## How it's put together (`Sources/Wingman`)

| Area | Files | Role |
|---|---|---|
| Entry | `main.swift` | Without arguments: the app. With a tool name: a diagnostic tool (below); left out with `NO_DIAGNOSTICS`. |
| App and UI | `UI/WingmanApp.swift` | Scenes (menu bar, window, welcome guide, settings) and `AppDelegate`, which owns the recorder, call watcher, permissions, shortcuts, mute follower, updater and problem reporter. |
| | `UI/TranscriptView.swift`, `UI/SettingsView.swift`, `UI/WelcomeView.swift`, `UI/Permissions.swift`, `UI/Feedback.swift`, … | Main window, Settings, first-run guide, permission states, feedback and "Report a Problem with a Call". |
| Core | `Recorder.swift` | Idle → preparing → recording → finishing. Mic and system-audio streams, mute, device changes, the after-meeting pipeline (language review → speaker separation → recognition → combined audio), notes and file names. |
| Audio | `Audio/` | Plain AVAudioEngine mic (no voice processing: it silenced Teams), Core Audio process tap for the call, device-change handling with time alignment, resampling, reading audio/video files. |
| Transcription | `Transcription/` | Parakeet Ultra via FluidAudio (live), Silero voice detection, Whisper large-v3 turbo language review after the meeting, speaker separation and voiceprints. |
| Calls | `Detection/CallDetector.swift`, `CallTracker.swift`, `CallWatcher.swift` | Which apps hold the mic (Core Audio process objects) → call sessions (3 s to start, 6 s to end) → record, ask or ignore per app, per session. `CallReport.swift` keeps each call's steps for problem reports. |
| Google Meet | `Detection/MeetDetection.swift`, `MeetInspector.swift` | Pure recognition rules and evidence levels; the read-only Accessibility reader of Chrome's tab strip, address bars and the Meet app's capture indicator (`#if !APP_STORE`). |
| Calendar | `Detection/CalendarLookup.swift` | EventKit: the current meeting, matched by Meet code when there is one. |
| Mute | `Detection/CallMuteMonitor.swift` | Follows the Teams/Zoom mute button via Accessibility (`#if !APP_STORE`). |
| Export | `Export/` | VTT/SRT subtitles, the combined `.m4a`. |
| Support | `Support/` | The log, audio clean-up, process tree, automatic updates (Sparkle, `#if !APP_STORE`). |

Build files: `Package.swift`, `install.sh`, `Info.plist`, `Resources/AppIcon.icns`,
`scripts/make-icon.swift`, `scripts/make-notices.py` (run it after changing
dependencies: it rewrites `THIRD_PARTY_NOTICES.md`).

## Diagnostic tools

Development builds include command-line tools. Those that need Wingman's permissions
(microphone, calendar, Accessibility) run through the installed app with
`scripts/tool.sh`, which shows their output live:

```bash
# Which apps are using the mic right now (what call detection sees; --watch to follow)
scripts/tool.sh whosmic

# What Google Meet detection sees in Chrome: complete/partial reads, evidence (local only)
scripts/tool.sh axdump chrome --inspector --seconds 30

# Teams'/Zoom's accessibility tree (find the mute control), or watch mute changes
scripts/tool.sh axdump teams --match mute
scripts/tool.sh axdump teams --watch

# Today's events as Wingman sees them, and the list the calendar button offers
scripts/tool.sh calendarcheck

# Check that the mic and call audio are both being captured
scripts/tool.sh audiocheck

# Record for N seconds through the real recorder and print the transcript
scripts/tool.sh recordtest 30

# Preview the "Report a problem with this call" dialog with a made-up call
scripts/tool.sh reportdialog
```

Tools that only read files run straight from the build:

```bash
# Compare speech engines on a recording (writes <file>.bakeoff.md next to it):
# parakeet-ultra (live engine), parakeet-v3, whisper (language review), apple
.build/release/Wingman bakeoff some-meeting-them.m4a --lang es-MX

# Stream a file through the live pipeline; --speakers adds speaker separation
.build/release/Wingman simulate some-audio.wav --speakers --languages en,es --vtt out.vtt

# Re-transcribe one stretch of a recording (with and without the Latin-alphabet filter)
.build/release/Wingman clip some-audio.wav 233 236

# Per utterance, side by side: Parakeet v3/Ultra, Whisper, Apple, and Whisper's language guess
.build/debug/Wingman langtest some-meeting-them.m4a --from 0 --to 600

# Transcribe a recording or video file (saves a note like a meeting)
.build/release/Wingman transcribe ~/Downloads/meeting.mp4

# Voice similarity between two recordings, and who would be recognized
.build/release/Wingman voicecompare a.wav b.wav "Ana,Carlos" --invited "Ana"

# Default audio device changes as they happen; the combined .m4a for old meetings
.build/release/Wingman devicewatch 20
.build/release/Wingman mix ~/Meeting\ Notes
```

## Sending a change

1. Open an issue first for anything bigger than a fix, so we can agree on the approach.
2. Keep pull requests small and focused; match the style of the code around them.
3. Run the tests, and say in the pull request how you checked the change in the app
   (a real call, a recording, which permissions were on).
4. Keep the ground rules above; if a change affects what users see or what leaves the
   Mac, update the README too.

## Releases

Official builds are made by the maintainer with `scripts/make-release.sh`. It runs the
tests, builds from a clean copy of the last commit with the exact pinned dependency
versions, signs with the project's certificate (so macOS keeps users' permissions across
updates) and the update key that installed copies trust, and checks the release, the
public tree and its history for identifying details (`scripts/check-public.sh`).

## Ideas on the list

- Renaming speakers live during the meeting.
- Summaries through a command-line AI tool the user already pays for.
- More languages for recognizing Google Meet and following mute (they're measured in
  English only so far — reports from other languages help).
