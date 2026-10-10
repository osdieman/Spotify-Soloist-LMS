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
- Soloist kept up to date automatically: a new build is downloaded from
  Spotify, tested, and switched to when nothing is playing (builds expire
  after 90 days). The settings page shows the installed build and its expiry
- API key entered on the settings page and stored only in a private key file
  (`chmod 600`), never in the LMS preferences
- Stall watchdog: logs when the LMS main loop is blocked, with the code it was
  stuck in, and marks every capture overrun with whether a stall caused it
- Never sends commands while the Spotify session is on another device, so
  pausing in LMS doesn't pause your phone

## Requirements

- **piCorePlayer on a Raspberry Pi** running Lyrion Music Server 8.0 or later:
  64-bit (tested on a Pi 4) or 32-bit (Pi 3B reported by a user). Other
  systems are not supported for now.
- A **Spotify Premium** account and a free **Spotify for Developers** account
  (for the Soloist API key)
- **Spotify Soloist**, downloaded from Spotify (step 3 below). It is
  proprietary and not included here; it needs glibc 2.38 or newer, which
  current piCorePlayer has.
- The **Pulse shim** `libpulse.so.0` from
  [foonerd/alsa_soloist_connect](https://github.com/foonerd/alsa_soloist_connect)
  (MIT), downloaded in step 4. Soloist only speaks PulseAudio; the shim passes
  its audio straight to ALSA. **Without it Soloist starts but plays nothing.**
- The ALSA Loopback driver `snd-aloop`, loaded at boot (step 1)

## Installation on piCorePlayer

The commands below run in an SSH session on the Pi as the normal `tc` user
(LMS runs as `tc` too, so the files then have the right owner). They use the
plugin's default folder `/mnt/mmcblk0p2/tce/soloist-prototype`, so no paths
need changing on the settings page. They never ask questions, so each block
can be pasted in one go. Run steps 3 and 4 in the **same** SSH session: step 3
detects whether your piCorePlayer is 64-bit or 32-bit.

### 1. Load the Loopback driver at every boot

pCP web interface → **Tweaks** → **User Commands**, enter
`modprobe snd-aloop` in User command #1, **Save**, reboot. Check:

```
cat /proc/asound/cards
```

It should list a `Loopback` card. If your DAC's card number changes because
of it, give the Loopback a fixed free number instead, e.g.
`modprobe snd-aloop index=2`.

### 2. Get your Soloist API key

1. Log in at the [Spotify for Developers dashboard](https://developer.spotify.com/dashboard)
   with your Premium account.
2. Open [Spotify Soloist API Key](https://developer.spotify.com/dashboard/soloist),
   accept the terms if asked, and **generate an API key**.
3. Keep it private: it belongs to your account. You paste it on the plugin's
   settings page in step 6; the plugin stores it only in a `chmod 600` file.

### 3. Download Soloist

Spotify publishes the current build at a fixed address
([Downloads and updates](https://developer.spotify.com/documentation/soloist/reference/downloads-and-updates)):

```
case "$(uname -m)" in
  aarch64) SOLOIST=arm64; SHIM=arm64 ;;   # 64-bit piCorePlayer
  armv7l)  SOLOIST=arm32; SHIM=armhf ;;   # 32-bit piCorePlayer
  *) echo "Not supported: $(uname -m)" ;;
esac
echo "Soloist build: $SOLOIST, shim: $SHIM"
mkdir -p /mnt/mmcblk0p2/tce/soloist-prototype/bin
cd /tmp
curl -fL -o soloist.tar.gz https://soloist-builds.spotifycdn.com/soloist_release_$SOLOIST.tar.gz
tar -xzf soloist.tar.gz
cat soloist > /mnt/mmcblk0p2/tce/soloist-prototype/bin/soloist
chmod 755 /mnt/mmcblk0p2/tce/soloist-prototype/bin/soloist
rm -f soloist soloist.tar.gz
/mnt/mmcblk0p2/tce/soloist-prototype/bin/soloist --version
```

The last command should print something like
`soloist 1.3.9.7 build … (linux/aarch64)` (64-bit) or `(linux/arm)` (32-bit).
You only do this once: from then on the plugin keeps Soloist up to date itself
(see [Automatic Soloist updates](#automatic-soloist-updates)).

### 4. Download the Pulse shim

foonerd publishes the shim for both: `arm64` for 64-bit, `armhf` for 32-bit
(`$SHIM` from step 3 picks the right one):

```
mkdir -p /mnt/mmcblk0p2/tce/soloist-prototype/shim
curl -fL -o /mnt/mmcblk0p2/tce/soloist-prototype/shim/libpulse.so.0 \
  https://raw.githubusercontent.com/foonerd/alsa_soloist_connect/main/soloist_connect/alsa-lib/$SHIM/libpulse.so.0
ls -l /mnt/mmcblk0p2/tce/soloist-prototype/shim/
```

`libpulse.so.0` should be listed with about 80 KB (64-bit) or 44 KB (32-bit).
If it says 0 bytes or the download fails, `$SHIM` is empty: run step 3 again
in this session first.

### 5. Install the plugin

1. LMS → Settings → **Plugins** → *Additional Repositories*, add
   `https://raw.githubusercontent.com/osdieman/Spotify-Soloist-LMS/main/repo.xml`
   and save.
2. Install **Soloist Connect** from the plugin list and restart LMS.

(Manual install instead: copy the `Soloist` folder to
`/mnt/mmcblk0p2/tce/slimserver/Cache/Plugins/` and restart LMS.)

### 6. Set it up

On the **Soloist Connect** settings page (LMS → Settings → Plugins):

1. Check the paths (*Soloist executable*, *Pulse shim folder*); with the
   commands above the defaults are right.
2. Paste your API key into **API key**.
3. Choose your Spotify Connect **device name**.
4. Set **Start this player when Spotify plays** to your player, so LMS starts
   it by itself when you press play in Spotify (also after a reboot).
5. **Save**, then press **Start**. After a few seconds the page should show
   **Running** and the *Soloist build* line with its expiry date.

### 7. Play

In the Spotify app, open the device picker, choose your device name and
press play. The player starts within a few seconds, with title, artist and
cover in LMS. For lossless audio, set the device's quality to Lossless in the
Spotify app and keep the Spotify volume at 100 % (control the volume in LMS or
on your amplifier).

### After a reboot

Soloist starts by itself about 8 seconds after LMS (retrying for about 90 s
if the Loopback isn't ready yet). If the Spotify app no longer shows your
device as selected, choose it again and press play.

### Automatic Soloist updates

Soloist builds stop working 90 days after their build date. With **Update
Soloist automatically** on (default), the plugin checks Spotify's download
address once a day, installs a newer build in the background and switches to
it when nothing has played for 10 minutes (at once if the old one expired).
The previous build is kept as `soloist.prev` and restored if the new one
doesn't start. **Check for update** on the settings page checks immediately.

### Upgrading from a WaveInput version

The old `wavin:` favourite is no longer needed; use *My Apps → Soloist
Connect* or the new favourite instead.

## Bit-perfect playback

With the default settings the stream is **bit-perfect from Spotify to the
FLAC stream**: LMS shows `Spotify LOSSLESS 16-bit` or `Spotify LOSSLESS 24-bit`,
measured from the audio itself.

- **Loudness normalisation is off by default.** Soloist does Spotify's
  track-to-track levelling internally, and the "Audio normalisation" switch in
  the Spotify app on your phone does not reach it. Soloist has no official
  option for it either, but it reads the Spotify client's preferences file in
  its data folder at startup; the plugin writes `audio.normalize_v2=false`
  there before every start (thanks to foonerd for finding this key). With it
  on, tracks arrive scaled, typically 2-6 dB quieter, and LMS shows e.g.
  `Spotify 16-bit (gain -3.9 dB)`.
- Keep the Spotify volume at **100 %** and control the volume in LMS or on your
  amplifier.
- Set the device's streaming quality to **Lossless** in the Spotify app.

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

- Soloist builds expire 90 days after their build date. With "Update Soloist
  automatically" on (default), the plugin fetches each new build from
  Spotify's official download address, tests it and switches over when
  nothing is playing; the previous build is kept and restored if the new one
  doesn't start. LMS must be allowed to write to the folder of the Soloist
  executable.
- Spotify delivers decoded audio of unknown original bit depth; the 24-bit
  FLAC is the transport format, not a claim about the source.
- Volume can be controlled by LMS and your player as also Spotify app.


## Changes

See [`CHANGELOG.md`](CHANGELOG.md).

## Credits

- Pulse shim, research on the Soloist WebSocket and the preferences key that
  switches off loudness normalisation:
  [foonerd/alsa_soloist_connect](https://github.com/foonerd/alsa_soloist_connect) (MIT)
- SpotOn for LMS transport handling ideas

Spotify and Soloist are trademarks or products of Spotify AB. This project is
not affiliated with or endorsed by Spotify.

## Licence

MIT, see `LICENSE`. Never post your API key or unredacted logs in public issues.
