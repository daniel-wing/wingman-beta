# Release notes

## 0.9.1 — sharing your screen no longer splits a call

- **Fix:** in 0.9.0, sharing your screen in Teams (and stopping) could start a new note
  in the middle of a call, so one meeting ended up in two or three notes. Teams moves its
  mute button into a small window while you share, and 0.9.0 took that for a new call.
  Now Wingman goes by Teams' own call timer, which keeps counting while you share, use
  the compact view or minimize the meeting: a new note starts only when the timer starts
  again for a new call.
- Zoom calls straight after one another stay in one note, as in 0.8; use **New Note**
  when a new call starts.

## 0.9.0 — name speakers after the meeting

- **Signed and notarized by Apple.** Wingman now carries an Apple Developer ID and is
  checked by Apple, so installing it no longer needs *Open Anyway*. Because the signature
  changed, macOS asks **once** more for the permissions you gave 0.8: Wingman opens
  **Allow Wingman Again** with each one. For Accessibility, System Settings may still show
  the old Wingman switched on: select it, click −, then click Allow in Wingman. Until
  Accessibility is allowed again, Wingman can't follow your Teams/Zoom mute or split
  back-to-back calls, and its menu says so.
- **Back-to-back calls get their own notes.** When Teams moves straight on to
  the next call, Wingman starts a new note at that moment, with no gap in the audio, and
  says so; **Join with Previous** undoes it for a minute. Before, both calls ended up in
  one note.
- **A window for each call.** Each call opens in its own window and keeps it, and the
  previous call finishes in the background while the next one records — no more waiting
  for "Saving audio…" before a new call can be recorded.
- **Delete Meeting…** after a call (in its window, or in Meetings): its note, audio and
  subtitles go to the Trash, and the voices learned from it are forgotten — for tests and
  calls you don't need.
- **Name speakers later.** The new **Meetings** window (menu bar → *Meetings…*) lists the
  last two weeks with how many speakers each has left to name, and works while the next
  call records. Naming changes only the speakers' names in the note and its subtitles;
  a copy of the note is kept for 30 days first. *Open…* reaches older notes.
- **Voices for later.** With *Recognize people* on, Wingman keeps each meeting's unnamed
  voices for 180 days so naming them later still teaches Wingman their voice. Delete them
  per meeting or all at once; turning *Recognize people* off deletes them all.
- **Meetings from before 0.9:** Wingman looks for the voices in the kept call audio and
  offers to learn the ones it's sure about — play a sample, then *Learn*. Nothing is
  learned without you.
- **Who's left to name:** "2 speakers to name · 1 to confirm" with **Name Them**, which
  walks you through them. The *Meeting saved* notification says it too, and opens the
  meeting.
- **Find** (⌘F, ⌘G): find a phrase ignoring capitals, accents and punctuation; if the
  phrase isn't there, the lines with all of its words, in any order.
- **Text size:** ⌘+ (or ⌘=) / ⌘− / ⌘0, or *Text Size* in the toolbar; remembered.
- **Open Wingman at login** (Settings), so calls are noticed without opening it first.
- **Meetings** from the Dock icon's menu too, and a note dropped onto the Meetings window
  opens there.
- **Clearer file names:** `2026-10-07_01_Weekly sync.md` — the day and the meeting's
  number that day. Older notes keep their names.
- **Two people with the same name** aren't mixed up: a voice that doesn't sound like the
  person Wingman knows by that name isn't learned, and can be learned as a different one.
- A reply that adds a "not" to what was said (*"We should not deploy"*) is no longer marked
  as a possible echo. The live transcript only follows new lines when you're at the
  bottom (*Jump to Latest* otherwise). If call detection can't tell whether a call is
  still going, Wingman keeps recording and says so instead of stopping. Only one copy of
  Wingman runs at a time. A meeting's *Duration* now ends when it stopped recording.
- **Going back to 0.8.2** keeps which meeting taught which voice, so *Delete Voices* still
  works exactly after you return to 0.9.

## 0.8.2 — a frozen window no longer costs a recording

A fix for a tester's call: the Wingman window froze while it was being resized, and the
recording stopped with it.

- **The recording keeps going even if the window freezes.** Each meeting's audio is now
  saved apart from the window and from transcription, so a busy or frozen window can
  only delay what you see, never what's recorded.
- **Meeting audio survives a crash or a force quit.** The audio files stay playable while
  they're being recorded. If Wingman is stopped mid-meeting anyway, it finishes that
  meeting's audio the next time it opens (including meetings 0.8.1 left unfinished) and
  says so.
- **Resizing the window during a call is lighter:** the transcript pauses while you drag
  the window's edge and catches up when you let go, and only finished lines are
  selectable.
- **If the window ever stops responding again**, Wingman's log says so with a few
  details (no meeting content), so the problem can be found.

## 0.8.1 — safer by default

Fixes from an outside review of 0.8.0, mostly about privacy and not losing a meeting:

- **Following your Teams mute works when Teams is minimized.** Teams then keeps a floating
  mini window with its own mute button, and the button in the minimized window stops
  updating; Wingman could read that stale one and miss that you'd muted. It now follows the
  live button.
- **No more silent saving failures.** If the note can't be saved (a full disk, a missing
  folder), Wingman says so and offers *Save Note As…*; "Meeting saved" only appears when it
  is. Very long meeting names in Chinese, Japanese or emoji no longer break saving.
- **Real replies aren't mistaken for echo.** On laptop speakers only clear repeats are
  removed; similar lines are kept and marked *(possible echo)* — "We should not deploy
  today" no longer disappears.
- **A line the speech engine fails on is kept**, marked *(incomplete)*, instead of vanishing.
- **Notifications act only on the call they're about**, and clicking a banner opens
  Wingman instead of starting a recording — only the *Record* button records.
- **Forgetting a voice says so only when it's done**, and discarding a recording says if a
  file couldn't go to the Trash.
- Meeting names can't leak into the log through punctuation; temporary audio lives in a
  private folder that's cleaned up after a crash; the call-audio rate check no longer
  misreads a pause; short microphone blips in a browser no longer start a call early; the
  in-app notices now say MIT; VoiceOver labels for the record and mute state.
- This is the first update installed by Wingman itself (from 0.8.0).

## 0.8.0 — Google Meet, open source, automatic updates

- **Wingman is open source** (MIT license): the code is now in the
  [repository](https://github.com/daniel-wing/wingman-beta), with a guide for
  contributors.
- **Wingman updates itself from now on**: it downloads new versions in the background
  and installs them when it quits (or with *Restart to Install* in its menu), never
  during a recording. Settings → About can switch it off.
- **Google Meet is a call app**, like Teams and Zoom: its own setting in Settings → Calls
  (*Ask me first* to start; if you had changed *Browser calls*, Meet starts with that
  choice), recording stops when you leave, and the note is named from the calendar event
  with that Meet link. Works in Chrome tabs and the Google Meet app; Edge, Brave, Arc and
  Opera work the same way with less testing. Needs Accessibility, which Wingman uses
  only to read the browser's tab titles and address bar ([how](https://github.com/daniel-wing/wingman-beta#google-meet));
  if you haven't allowed it, Settings → Calls shows an *Allow…* button.
- When Wingman isn't sure it's Meet (the tab is behind other tabs, or Chrome isn't in
  English), it asks *Google Meet call?* instead of recording on its own.
- Two meetings at once are two calls: leaving one no longer ends the recording of the other.
- **Report a Problem with a Call** (menu bar, or next to *Show Note*): pick the call, say in
  one sentence what went wrong, and Wingman adds what it saw and did during that call —
  no meeting titles, links or what was said. Copy it into a message, or open the GitHub
  form with it filled in.
- The call prompt now reads *Browser call detected* (it said *Browser calls call detected*).
- Following your mute still works in the Teams and Zoom apps only; in Google Meet, mute
  Wingman with ⌃⌥M. Calls in a browser no longer warn that mute can't be followed.

**Download Wingman-0.8.0.zip under Assets** (not *Source code*). Quit Wingman from its
menu-bar icon, replace the Wingman in your Applications folder with the new one, open it
and click *Open Anyway* once ([install steps](https://github.com/daniel-wing/wingman-beta#install)).
Your settings, notes and permissions are kept.

## 0.7.0 — first public beta

The first build for beta testers. Highlights:

- Records Teams, Zoom and browser calls automatically or after asking, and stops when
  the call ends.
- Live transcript that handles English and Spanish mixed in one meeting.
- Language review after each meeting: unsure or wrong-language lines are transcribed
  again, on your Mac.
- Speakers told apart (Them 1, Them 2…), with optional voice recognition across meetings.
- Calendar with no Microsoft sign-in: Wingman reads the Mac's Calendar app, so an Outlook /
  Microsoft 365 work calendar works once it's added to your Mac, even if your company
  doesn't let other apps connect to your Microsoft account. Meeting names, invitees and
  links; pick another of today's meetings anytime.
- Follows your mute in the Teams and Zoom apps (optional), with "Transcribe me anyway".
- Text notes (.md), compact audio (both sides mixed, plus separate tracks), and .vtt / .srt
  subtitles. Old audio can go to the Trash automatically, by age or by space used.
- Speech models download right after setup, so your first call doesn't wait.
- **Send Feedback…** in the menu bar and in Settings → About.

**Download Wingman-0.7.0.zip under Assets** (not *Source code*), then follow the
[install steps](https://github.com/daniel-wing/wingman-beta#install). Known limitations:
see the [README](https://github.com/daniel-wing/wingman-beta#known-limitations).
