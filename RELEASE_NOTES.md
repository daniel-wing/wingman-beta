# Release notes

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
