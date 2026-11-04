# AWDL guard

Blue Bloom has a switch for "Pause AirDrop and AirPlay discovery while streaming". The app only creates and removes
`/Users/Shared/.aptx-awdl-suppress`; the part that acts on it is this helper, which did not exist anywhere until now,
so the switch stayed greyed out (see [#5](https://github.com/jonathanlu98/bluebloom/issues/5)).

AWDL (Apple Wireless Direct Link) is the peer-to-peer radio behind AirDrop, AirPlay discovery, Handoff and Continuity.
On Macs that share one radio for Wi-Fi and Bluetooth it keeps hopping channels and cutting Bluetooth slots, which shows
up as dropouts and as a link that cannot hold the higher LDAC tiers.

## Install

```sh
sudo tools/awdl-guard/install.sh
```

This adds two files and nothing else:

| Path | What |
|---|---|
| `/usr/local/libexec/aptx-awdl-guard` | the helper (a shell script, readable before you install it) |
| `/Library/LaunchDaemons/app.bluebloom.awdl-guard.plist` | runs it as root on load, when the flag file changes, and every 5 minutes as a safety net |

After that, **Settings › Audio › Playback** offers the switch. It comes back off, and AWDL is left alone, as soon as
streaming stops or Blue Bloom quits.

## How it works

The helper derives the wanted state from the flag file alone, so running it twice, or at boot, is harmless:

- flag present → `ifconfig awdl0 down` (only if it is currently up)
- flag absent → `ifconfig awdl0 up` (only if it is currently down)

It never touches anything else, and it never runs when the interfaces are already in the wanted state.

## Check it

```sh
/usr/local/libexec/aptx-awdl-guard --status     # flag file and awdl0 state
AWDL_GUARD_DRY_RUN=1 /usr/local/libexec/aptx-awdl-guard   # what it would do, changes nothing
```

## Uninstall

```sh
sudo tools/awdl-guard/uninstall.sh
```

Removes both files, the flag file, and brings `awdl0` back up.
