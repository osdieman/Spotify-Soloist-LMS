# Soloist Connect for Lyrion Music Server

Turns your Lyrion Music Server (LMS) into a **Spotify Connect** device using
[Spotify Soloist](https://developer.spotify.com/documentation/soloist).
Pick it in the Spotify app and the music plays through LMS, so it can go to
any Squeezelite player or synced group like any other source.

```
Spotify app ─► Soloist ─► Pulse shim ─► ALSA Loopback ─► WaveInput ─► LMS ─► your players
```

## Features

- Spotify Connect device name of your choice
- Title, artist, album, cover art and progress shown in LMS
- Play, pause, next and previous from any LMS interface control Spotify
- LMS starts or resumes the player automatically when Spotify starts playing
  (optional, never interrupts a player that is busy with another source)
- Start, stop and restart Soloist from the plugin settings page, with autostart
  and a live log view
- Never sends commands while the Spotify session is on another device, so
  pausing in LMS doesn't pause your phone

## Requirements

- Lyrion Music Server 8.0 or later on Linux (tested on piCorePlayer, Raspberry Pi 4)
- The **WaveInput** plugin
- The ALSA Loopback driver: `snd-aloop`
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

1. Put the Soloist binary in a folder such as `/mnt/mmcblk0p2/tce/soloist/bin/`,
   and the shim in `/mnt/mmcblk0p2/tce/soloist/shim/`.
2. Save your API key in a file and protect it: `chmod 600 api-key`.
3. In LMS, add a favourite with the URL
   `wavin:plughw:CARD=Loopback,DEV=1,SUBDEV=0`.
4. Open the Soloist Connect settings page, check the paths, save, and press
   **Start**.
5. Select the device in the Spotify app and press play.

## Known limitations

- **Soloist builds expire 90 days after their build date.** Download a new
  build when Soloist stops starting.
- WaveInput captures at 16-bit/44.1 kHz, so this is CD quality, not 24-bit.
- Volume is controlled by LMS and your player, not by the Spotify app.
- A short gap can occur when skipping tracks in the Spotify app.

## Credits

- Pulse shim and research on the Soloist WebSocket:
  [foonerd/alsa_soloist_connect](https://github.com/foonerd/alsa_soloist_connect) (MIT)
- [SpotOn](https://github.com/stiefenm/spoton) for LMS transport handling ideas

Spotify and Soloist are trademarks or products of Spotify AB. This project is
not affiliated with or endorsed by Spotify.

## Licence

MIT, see [LICENSE](LICENSE). **Never post your API key or unredacted logs in
public issues.**
