# Soloist Connect for LMS

Makes an LMS/Lyrion server appear as a Spotify Connect device, using Spotify
Soloist as a separate process. Audio path:

    Spotify app → Soloist → Pulse shim → ALSA Loopback (DEV=0)
               → WaveInput wavin:plughw:CARD=Loopback,DEV=1 → LMS → Squeezelite player(s)

LMS stays in charge of playback and sync, so the Spotify stream can be sent to
any player or sync group like any other source.

## Requirements

- LMS 8.0 or later with the **WaveInput** plugin
- `snd-aloop` loaded (ALSA Loopback card)
- Soloist binary, Pulse shim (`libpulse.so.0`) and a private API key file
  (`chmod 600`)

## What the plugin does

- Starts, stops and supervises Soloist (optional autostart; retries while the
  Loopback card or data partition is not ready after boot). Start and stop never
  block the LMS server; the settings page shows Starting…/Stopping….
- Shows the Spotify title, artist, album, duration and cover in LMS while the
  player is on the WaveInput source, and keeps the LMS progress bar in sync.
- LMS Play/Pause/Next/Previous on that player control Spotify. Next/Previous are
  intercepted before LMS acts on them, so the WaveInput stream stays open.
  "Restart track" (`+0`) seeks to 0:00.
- Commands are only sent while this device holds the Spotify session, because
  Spotify commands are account-wide: pausing in LMS never pauses your phone after
  you moved playback there.
- When Spotify starts playing, an idle LMS player that is on the WaveInput source
  is resumed automatically. With "Start this player when Spotify plays" set, an
  idle player is switched to the WaveInput source. A player playing something
  else is never interrupted.

## Files

`soloist.pid` and `soloist.log` are written next to the Soloist install
(the folder above `bin/`). The log is rotated to `soloist.log.1` above 1 MB.
"Write audio shim diagnostics" adds the shim's ALSA cork/flush/xrun lines.

## Install (piCorePlayer)

    tar -xzf Soloist-LMS-<version>.tar.gz -C /mnt/mmcblk0p2/tce/slimserver/Cache/Plugins/

then restart LMS. Remove by deleting that `Soloist` folder.

## Security

The API key is read from a file and never stored in LMS preferences. Soloist
only accepts it on its command line; the shim overwrites it shortly after start.
The WebSocket is restricted to 127.0.0.1/localhost.
