# Changelog

## 0.1.29

### Fixed
- **LMS stalls of 1.5–2.6 s during playback**, found by the 0.1.28 watchdog:
  the plugin wrote the cover URL into LMS's cache database (an SQLite file on
  the SD card) on every status poll, about once a second. When the card was
  busy that write blocked LMS longer than the capture buffer. The cover is now
  cached once per track.
- **No sound with "arecord: audio open error: Device or resource busy"**: an
  `arecord` left over from an earlier stream kept the Loopback capture open.
  A stale capture on the same device is now ended before a new one starts.

### Changed
- Soloist `error` events are logged with their content (`--- soloist error`
  in `soloist.log` and in the LMS log), each distinct message at most once a
  minute.
- Plugin lines in `soloist.log` (capture start, watchdog reports) are written
  through a small helper process, so logging can never block LMS.

## 0.1.28

### New
- **Stall watchdog.** Detects when the LMS main loop is blocked for more than
  0.5 s and logs to `soloist.log` the duration, LMS CPU use, system iowait and
  load, the plugin's last activity and (default) the Perl call stack of the code
  LMS was stuck in. Each arecord `overrun!!!` line gets a timestamped note
  saying whether an LMS stall preceded it. Setting: Off / On / On with call stack.
- **One-tap start.** Opening *My Apps → Soloist Connect* switches the selected
  player to Spotify (unless it is busy with another source). The app page now
  shows Soloist and Spotify session status, the current track, Play,
  Start/Restart and a favourite-ready item. Setting: "Opening the app starts
  Spotify".
- **API key field** on the settings page. Always shown empty; the key goes
  straight to the key file (`chmod 600`, folder created if needed), never into
  LMS preferences. Status line: key set, last changed, last four characters.
- **Expiry hints.** A red notice when Soloist stops with an expired or rejected
  key/licence in its log; if the key carries an expiry date, it is shown with a
  warning from 14 days before.

### Changed
- Stop and Restart also end Soloist's helper process (the one left with PPid 1)
  and other leftovers; Start clears stale ones first. They are listed on the
  settings page.
- Status detection prefers the real Soloist (session leader) over its helper.
- The Soloist WebSocket client is fully non-blocking (connect, handshake,
  reads, writes). The blocking one-shot fallback for commands is removed.
- Bitrate label: "Spotify → FLAC 24-bit" / "Spotify → PCM 16-bit" instead of
  "24-bit FLAC", since the source's own bit depth is unknown.

### Fixed
- Garbled characters on the settings page (`â`, `startingâ€¦`).

### Docs
- snd-aloop via pCP User Commands, WaveInput no longer needed, bit-perfect
  tips, watchdog, API key, renewal procedure.

## 0.1.27
- Own `soloist:connect` source replaces the WaveInput dependency (24-bit
  capture → FLAC, explicit arecord buffer).
