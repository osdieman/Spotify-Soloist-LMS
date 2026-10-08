# Soloist Connect for LMS

Makes an LMS/Lyrion server appear as a Spotify Connect device, using Spotify
Soloist as a separate process. Audio path:

    Spotify app → Soloist → Pulse shim → ALSA Loopback (DEV=0)
               → soloist:connect (arecord plughw:CARD=Loopback,DEV=1, 24-bit → FLAC)
               → LMS → Squeezelite player(s)

LMS stays in charge of playback and sync, so the Spotify stream can be sent to
any player or sync group like any other source.

## Starting Spotify with one tap

Open **My Apps → Soloist Connect**. Opening the app switches the selected
player to the Spotify source straight away (setting "Opening the app starts
Spotify"); then pick the device in the Spotify app. A player that is busy
playing something else is not switched; the page then shows
"▶ Switch … to Spotify". If this device already holds the Spotify session and
Spotify is paused, it is resumed as well.

The app page also shows whether Soloist is running, where the Spotify session
is and what is playing, with Start/Restart. The last entry, "Spotify (Soloist
Connect)", is the one to add to Favourites; a favourite is also one tap.

## Requirements

- piCorePlayer on a Raspberry Pi with LMS 8.0 or later
- The WaveInput plugin is **not** needed any more; the plugin brings its own
  `soloist:connect` source. You can uninstall WaveInput if nothing else uses it.
- `snd-aloop` loaded (ALSA Loopback card), see below
- Soloist binary, Pulse shim (`libpulse.so.0`) and an API key (enter it on the
  settings page; it is stored in a private key file, `chmod 600`)

### Loading snd-aloop on piCorePlayer

piCorePlayer does not load the Loopback module by itself. Add it as a User
Command so it is loaded at every boot:

1. pCP web interface → **Tweaks** → **User Commands**
2. In an empty field enter `modprobe snd-aloop` and click **Save**
3. Reboot, then check over SSH: `cat /proc/asound/cards` should list
   `Loopback`.

If the Loopback card is missing at start, the plugin retries for about
90 seconds after boot and then reports it on the settings page.

## The source

The plugin brings its own `soloist:connect` source: a protocol handler plus
`custom-convert.conf`/`custom-types.conf` (content type `sol`). Start it from
**My Apps → Soloist Connect**, save it as a favourite, or let "Start this
player when Spotify plays" start it.

- FLAC-capable players get 24-bit capture (`S24_3LE`) encoded to FLAC; players
  without FLAC fall back to 16-bit PCM. LMS shows this as
  "Spotify → FLAC 24-bit": that is the transport format. Spotify itself
  delivers decoded float audio whose original bit depth is not known, so the
  plugin does not claim "24-bit" for the source.
- `arecord` runs with an explicit buffer ("Capture buffer", default 2000 ms,
  50 ms periods). This is headroom for short LMS pauses, not extra delay.
- With audio diagnostics on, arecord's `overrun!!!` lines go to `soloist.log`
  after a `--- capture start` marker.
- New settings apply the next time the source starts (stop/start the player).

## What the plugin does

- Starts, stops and supervises Soloist (optional autostart; retries while the
  Loopback card or data partition is not ready after boot). Start and stop never
  block the LMS server; the settings page shows Starting…/Stopping….
- Shows the Spotify title, artist, album, duration and cover in LMS while the
  player is on the Soloist source, and keeps the LMS progress bar in sync.
- LMS Play/Pause/Next/Previous on that player control Spotify. Next/Previous are
  intercepted before LMS acts on them, so the capture stream stays open.
  "Restart track" (`+0`) seeks to 0:00.
- Commands are only sent while this device holds the Spotify session, because
  Spotify commands are account-wide: pausing in LMS never pauses your phone after
  you moved playback there.
- When Spotify starts playing, an idle LMS player that is on the Soloist source
  is resumed automatically. With "Start this player when Spotify plays" set, an
  idle player is switched to the Soloist source. A player playing something
  else is never interrupted.

## Bit-perfect playback

The Pulse shim passes Soloist's output to the Loopback unchanged, and the
capture is lossless. Two Spotify settings decide whether anything changes the
samples before that:

- **Spotify volume at 100 %.** Below 100 % Spotify scales the samples. Control
  the volume in LMS or on your amplifier instead.
- **Audio normalisation off** (Spotify app → Settings → Playback). With it on,
  Spotify changes track levels.

## Stall watchdog (finding drop-outs)

LMS is single-threaded. If anything blocks its main loop for longer than the
capture buffer (default 2 s), arecord overruns and audio drops out. The
watchdog (setting "Stall watchdog", default "On, with call stack") notices
when the main loop is more than 0.5 s late and writes to `soloist.log`:

    --- stall 2026-10-09 21:14:03.412: LMS main loop blocked 5.23 s (LMS CPU 0.02 s (mostly waiting), system busy 4%, iowait 81%, load 1.90)
        last Soloist plugin activity: Soloist event playback_state, 0.31 s before the stall
        call stack at +0.8 s:
          at Slim/Some/Module.pm:123
          in Slim::Some::Module::slowThing (called at Slim/Other.pm:45)
          ...

- **LMS CPU** close to the duration: LMS was busy computing; the call stack
  names the code. Close to 0: LMS was waiting (disk, network, or the whole Pi
  was stalled; high **iowait** points at the SD card).
- **call stack** shows where LMS was. A stack that only shows the LMS idle
  loop means LMS was not running Perl code at all: look outside LMS.
- Each arecord `overrun!!!` line is followed by a timestamped
  `--- overrun seen …` line saying whether an LMS stall preceded it. "No LMS
  main-loop stall" means LMS was not blocked, so the cause is elsewhere (for
  example the player's buffer or clock drift between the Loopback and the DAC).

Keep "Write audio diagnostics" on, otherwise arecord's overrun lines are not
logged. To collect everything:

    grep -A8 -E -- "--- stall|--- overrun" /mnt/mmcblk0p2/tce/soloist-prototype/soloist.log

The call stack is taken with a one-shot SIGALRM that is only armed for the
moment a stall is already happening, with SA_RESTART so it does not cut
blocking reads and writes short. If you prefer, choose "On" (duration only)
or "Off".

## Files

`soloist.pid` and `soloist.log` are written next to the Soloist install
(the folder above `bin/`). The log is rotated to `soloist.log.1` above 1 MB.
"Write audio shim diagnostics" adds the shim's ALSA cork/flush/xrun lines
and arecord's capture overruns.

## Stop and helper processes

Soloist starts a helper process that can outlive it (it then shows PPid 1).
Stop and Restart end Soloist and then every other process of its session,
anything running the Soloist binary or from the Soloist folder, and other
processes named `soloist` (TERM, then KILL after 2 s). Start also clears such
leftovers first. Remaining ones are listed on the settings page as "Other
Soloist processes".

## API key

Paste the key into **API key** on the settings page and click Save. The field
is always shown empty; the key is written straight to the key file (folder
created if needed, file `chmod 600`) and never stored in the LMS preferences.
The page then shows "Key set, last changed …, ends in …". Click **Restart** to
use a new key.

## Renewal

Soloist needs renewing after about 90 days. What exactly expires (the binary,
the key or the login) is still being established; until then:

- If Soloist stops and its log mentions an expired, invalid or revoked key or
  licence, the settings page says so in red.
- If the key carries a readable expiry date (a JWT with an `exp` claim), the
  settings page shows it and warns from 14 days before.

Procedure:

1. Get the new key (and, if a new Soloist version is required, the new binary).
2. New binary: copy it over `…/soloist-prototype/bin/soloist` and
   `chmod 755` it.
3. New key: paste it on the settings page and click Save.
4. Click **Restart** and check that the status shows Running and the log has
   no errors.

## Install (piCorePlayer)

    tar -xzf Soloist-LMS-<version>.tar.gz -C /mnt/mmcblk0p2/tce/slimserver/Cache/Plugins/

then restart LMS. Remove by deleting that `Soloist` folder.

## Security

The API key is read from a file and never stored in LMS preferences. Soloist
only accepts it on its command line; the shim overwrites it shortly after start.
The WebSocket is restricted to 127.0.0.1/localhost.
