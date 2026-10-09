# Changelog

## 0.1.38

### Fixed
- Update messages showed `â€¦` instead of `…` on the settings page.
- After a plugin update, LMS could keep showing the old settings page and
  texts: the release zips since 0.1.35 gave every file the same fixed date, so
  LMS's page and string caches didn't notice the files had changed. Release
  zips now carry the release time. (If you are on 0.1.36/0.1.37 and the page
  looks unchanged after updating, `touch` the plugin's `basic.html` and
  `strings.txt` once and restart LMS.)

## 0.1.37

### New
- **Soloist updates itself.** Soloist builds stop working 90 days after their
  build date. Once a day the plugin checks Spotify's official download
  address (a HEAD request; nothing is downloaded unless the archive changed and
  is newer than the installed build). A new build is downloaded in the
  background, unpacked, tested with `soloist --version` (same architecture,
  newer build), and put in place with the previous one kept as `soloist.prev`.
  Soloist switches over when nothing has played through it for 10 minutes, or
  at once if the old build has expired. If the new build doesn't start, the
  previous one is restored automatically.
- Settings page: the installed build with its build date and expiry, the
  update status, a "Check for update" button and an "Update Soloist
  automatically" setting (on by default).

## 0.1.36

### Fixed
- **Soloist didn't start after a reboot on piCorePlayer** because the API key
  file was no longer private: pCP adds group-write under `tce` at boot, which
  turns 0600 into 0620, and the plugin refuses a key file others can access.
  The plugin now sets the key file back to 0600 itself whenever it checks or
  uses it, and logs once when it had to.

## 0.1.35

### Fixed
- **Next took ~18 s to be heard after playing for a while.** The backlog builds
  up in squeezelite's own buffers (clock drift between the Loopback and the
  DAC, plus every LMS stall) until they are full, ~18 s with FLAC 24-bit. The
  delay was only measured from the elapsed time, which didn't show it, so
  "Keep the delay low" never restarted the stream. The plugin now also reads
  how full squeezelite reports its stream and output buffers are, and uses the
  larger of the two measurements.

### New
- The settings page shows both measurements ("in player buffers", "by elapsed
  time"). Every delay check is logged at Info level, and every stream restart
  gets a `--- stream restart` line in `soloist.log`.

## 0.1.34

### Fixed
- **Metadata stopped updating (since 0.1.32).** The per-track measurement line
  includes the title; a title with a non-ASCII character ("é", "–") made the
  log write die ("Wide character in syswrite") inside the metadata handler,
  before the new track was stored, so the title, cover and time stayed on the
  old track. The log writer now writes UTF-8, and the measurement line is
  written after the metadata is applied and can no longer break it.
- **Measurement history no longer resets on a stream restart** (skip, resume,
  "keep the delay low"): the filter carries on with the previous blocks, so a
  track's measurement line covers the whole track.

## 0.1.33

### Fixed
- **24-bit tracks with a gain were labelled `NOT BIT-PERFECT`.** 0.1.32 could
  only recognise a scaled 16-bit grid. The filter now checks the gaps between
  neighbouring quiet values for a 16-bit or a 24-bit grid, so a lossless
  24-bit track with Soloist's loudness normalisation shows
  `Spotify 24-bit (gain -5.2 dB)`. Also more robust for 16-bit (tested on
  synthetic 16/24-bit, scaled, normalised, lossy and dithered signals: no
  false grids in 300 blocks).

### Found
- The gain measured since 0.1.32 is **Soloist's built-in loudness
  normalisation**: a different gain per track (-2.6 to -5.6 dB here), even
  with "Audio normalisation" off in the phone app. Soloist has no documented
  option to switch it off. README updated.

## 0.1.32

### Fixed
- **The measurement no longer says `NOT BIT-PERFECT` when it can't know.**
  0.1.31 only checked whether the lowest bits were empty, so any tiny scaling
  (a decoder dividing by 32767 instead of 32768) counted as "changed", even
  though every sample was still the original value. The filter now also
  looks at the quiet samples of each 0.5 s block, finds the step between
  neighbouring levels and checks whether the audio sits on a 16-bit grid,
  and at what gain:
  - on the standard grid, or scaled by at most 0.01 % → `Spotify LOSSLESS 16-bit`
  - on a clean grid with a real gain → `Spotify 16-bit (gain -2.0 dB)`
  - no integer grid at all (lossy, dither) → `Spotify NOT BIT-PERFECT`
  - not sure yet → plain `Spotify`; a verdict needs 2 s of agreeing audio

### New
- One `--- measure` line per track in `soloist.log` with the block counts,
  the measured gain and the verdict, so every label can be checked.

## 0.1.31

### New
- **The Spotify stream is measured.** Soloist outputs float, so its format
  says nothing about the source. The capture now runs at 32-bit through a
  small filter that checks which bits the audio uses, and LMS shows
  `Spotify LOSSLESS 16-bit`, `Spotify LOSSLESS 24-bit` or
  `Spotify NOT BIT-PERFECT` (lossy stream, or volume/normalisation changed the
  samples). Setting: "Measure the Spotify stream" (on by default).

### Changed
- Format label: the DAC is named by its product name
  (`… → FLAC → FiiO K11 R2R 24-bit/44.1 kHz`); the transport is just "FLAC".

## 0.1.30

### New
- **Keep the delay low.** The live source never plays faster than real time,
  so every LMS hiccup or pause added permanent delay (Next took 12 s). The
  plugin now measures the delay Spotify → player and restarts the stream to
  drop the backlog: on a skip (over 2 s), when resuming after a pause, and at
  a track change when it is over 10 s. The delay is shown on the settings page
  and in the app.
- **What reaches the DAC:** for a squeezelite on the same machine, the LMS
  format field shows the live ALSA format at the DAC, e.g.
  `Spotify → FLAC 24-bit/44.1 kHz → R2R 32-bit/44.1 kHz`.
- **Expired builds are recognised:** Soloist exit code 10 gives a clear
  message on the settings page and in the app.

### Changed
- The playback state is only polled while Soloist is logged in to Spotify;
  before that the plugin only checks the login state, which stops the
  "command requires authentication" errors.
- Covers are passed to LMS at about 300 px instead of 640 px, so LMS's image
  cache grows less.
- New installs keep Soloist's cache in `/tmp/soloist-cache` (RAM).

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
