# Soloist Connect for Lyrion Music Server

Turns your Lyrion Music Server (LMS) into a **Spotify Connect** device using
[Spotify Soloist](https://developer.spotify.com/documentation/soloist).
Pick it in the Spotify app and the music plays through LMS, so it can go to
any Squeezelite player or synced group like any other source.

```
Spotify app ─► Soloist ─► Pulse shim ─► ALSA Loopback ─► soloist:connect (24-bit → FLAC) ─► LMS ─► your players
```

## Features

- Spotify Connect device name of your choice
- **One tap:** opening *My Apps → Soloist Connect* switches the player to
  Spotify (never interrupts a player that is busy with another source)
- Own capture source: 24-bit capture encoded to FLAC, shown in LMS as
  "Spotify → FLAC 24-bit" (16-bit PCM for players without FLAC).
  WaveInput is no longer needed
- Title, artist, album, cover art and progress shown in LMS
- Play, pause, next and previous from any LMS interface control Spotify
- LMS starts or resumes the player automatically when Spotify starts playing
  (optional)
- Start, stop and restart Soloist from the plugin settings page, with autostart
  and a live log view; Stop also ends Soloist's helper process
- API key entered on the settings page and stored only in a private key file
  (`chmod 600`), never in the LMS preferences
- Stall watchdog: logs when the LMS main loop is blocked, with the code it was
  stuck in, and marks every capture overrun with whether a stall caused it
- Never sends commands while the Spotify session is on another device, so
  pausing in LMS doesn't pause your phone

## Requirements

- Lyrion Music Server 8.0 or later on **piCorePlayer** (tested on a
  Raspberry Pi 4, 64-bit). Other systems are not supported for now.
- The ALSA Loopback driver `snd-aloop`, loaded at boot (see Setup)
- **Spotify Soloist** and a Soloist API key from Spotify. Soloist is
  proprietary and is *not* included here; see Spotify's Soloist documentation.
  It needs glibc 2.38 or newer.
- The Pulse-to-ALSA shim (`libpulse.so.0`) from
  [foonerd/alsa_soloist_connect](https://github.com/foonerd/alsa_soloist_connect)
- A Spotify Premium account

## Installation

### From inside LMS (recommended)

1. LMS → Settings → Plugins → *Additional Repositories*, add:
   `https://raw.githubusercontent.com/osdieman/Spotify-Soloist-LMS/main/repo.xml`
2. Install **Soloist Connect** from the plugin list and restart LMS.

### Manually

Copy the `Soloist` folder to your LMS plugin folder (on piCorePlayer:
`/mnt/mmcblk0p2/tce/slimserver/Cache/Plugins/`) and restart LMS.

## Setup

1. Load the Loopback driver at every boot: pCP web interface → **Tweaks** →
   **User Commands**, enter `modprobe snd-aloop`, Save, reboot. Check with
   `cat /proc/asound/cards` (it should list `Loopback`).
2. Put the Soloist binary in a folder such as
   `/mnt/mmcblk0p2/tce/soloist/bin/`, and the shim in
   `/mnt/mmcblk0p2/tce/soloist/shim/`.
3. Open the Soloist Connect settings page, check the paths, paste your API key
   into **API key**, Save, and press Start.
4. Open *My Apps → Soloist Connect* on your player (or save the
   "Spotify (Soloist Connect)" item as a favourite), select the device in the
   Spotify app and press play.

If you upgrade from a version that used WaveInput, the old `wavin:` favourite
is no longer needed; use the app or the new favourite instead.

## Bit-perfect playback

Set the Spotify volume to 100 % and control the volume in LMS or on your
amplifier.

Soloist has Spotify's loudness normalisation built in, and it stays on even
when "Audio normalisation" is off in the Spotify app on your phone: that
setting only applies to playback on the phone itself. Spotify's Soloist
documentation lists no option to switch it off. Every track then arrives
lossless but with its level lowered by a few dB (measured: -2.6 to -5.6 dB on
loud pop/electronic tracks), and LMS shows e.g. `Spotify 16-bit (gain -3.9 dB)`.
The samples are scaled, so the stream is not bit-perfect, but nothing is
lost to compression.

## Troubleshooting drop-outs

Keep "Write audio diagnostics" and the stall watchdog on, and after a drop-out
run:

```
grep -A8 -E -- "--- stall|--- overrun" <your Soloist folder>/soloist.log
```

Each overrun is marked with whether an LMS stall preceded it; stall entries
include the duration, CPU and iowait and the code LMS was busy in. See
[`Soloist/README.md`](Soloist/README.md) for details.

## Known limitations

- Soloist builds expire 90 days after their build date. Download a new build
  when Soloist stops starting, copy it over the old binary and press Restart.
- Spotify delivers decoded audio of unknown original bit depth; the 24-bit
  FLAC is the transport format, not a claim about the source.
- Volume can be controlled by LMS and your player as also Spotify app.


## Changes

See [`CHANGELOG.md`](CHANGELOG.md).

## Credits

- Pulse shim and research on the Soloist WebSocket:
  [foonerd/alsa_soloist_connect](https://github.com/foonerd/alsa_soloist_connect) (MIT)
- SpotOn for LMS transport handling ideas

Spotify and Soloist are trademarks or products of Spotify AB. This project is
not affiliated with or endorsed by Spotify.

## Licence

MIT, see `LICENSE`. Never post your API key or unredacted logs in public issues.
