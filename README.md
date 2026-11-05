# HueBar

A small macOS menu-bar app for controlling Philips Hue lights. It talks to your Hue Bridge
directly on your local network over **HTTPS**, using the Hue CLIP v2 API. There is no cloud
account, no telemetry and no third-party service involved.

## Why it exists

Recent Hue Bridge firmware (1978545030 and later, API 1.78) blocks plain HTTP on the local
network. Requests to port 80 are rejected with `403 unauthorized user - HTTP access is blocked`;
only HTTPS on port 443 works.

Some existing Mac menu-bar Hue apps still send their local requests over HTTP. After the bridge
updates they pair successfully but then show no rooms, lights or scenes, and re-pairing doesn't
help. HueBar was written as a replacement that only ever uses HTTPS, and validates the bridge's
certificate properly instead of ignoring it.

## Features

- **Rooms and zones** from every bridge, each with an on/off switch and a brightness slider.
- **Scenes and individual lights:** expand a row to recall a scene, or switch and dim single
  lights. The active scene is shown under the room name.
- **All Off** switches off every room on every bridge.
- **Global keyboard shortcuts** (Settings → Keyboard shortcuts). For any room or zone, a shortcut
  can recall a specific scene, cycle to the next scene, or toggle the room on and off. They work
  from any app and don't need Accessibility permission (they use Carbon `RegisterEventHotKey`).
  A zone is a handy way to give one shortcut a custom set of lights, such as "most of the house".
- **Several bridges at once.** Add them in Settings by discovery or IP address, then press the
  bridge's link button to pair.
- **Follows the bridge if its IP changes**, by looking it up again by bridge ID through Signify's
  discovery service (`discovery.meethue.com`).
- Menu-bar icon reflects whether any lights are on; optional launch at login.

## Requirements

- macOS 15 (Sequoia) or later
- Xcode or just the Command Line Tools (`xcode-select --install`) with Swift 6
- A Philips Hue Bridge (v2, square) on the same network

## Build and install

```bash
git clone https://github.com/martfo/HueBar.git
cd HueBar
./build.sh            # builds build/HueBar.app
./build.sh --install  # also copies it to /Applications and launches it
```

The app is ad-hoc signed for your own machine, so it isn't notarised. Build it from source as
above rather than downloading a prebuilt copy.

## First run

1. Click the lightbulb in the menu bar, then the gear icon to open Settings.
2. Click **Find bridges on my network** (or type the bridge's IP address) and click **Add**.
3. Press the round link button on top of the bridge when asked. HueBar waits about 40 seconds.
4. macOS will ask to allow HueBar to find devices on your local network: allow it.

## Security notes

- Hue bridges present certificates signed by Signify's private root CA and issued to the bridge ID
  rather than the IP address, so normal TLS validation can't be used. When a bridge is added,
  HueBar checks that the certificate names the bridge it expects, then pins that exact certificate
  (SHA-256). A different certificate later is refused. If a bridge is reset or replaced, remove it
  and add it again.
- Bridge settings, including the app keys the bridge issues, are stored only on your Mac in
  `~/Library/Application Support/HueBar/bridges.json` (file mode 600). Shortcuts are stored next to
  it in `shortcuts.json`.

## Terminal helpers

```bash
HueBar --selftest                     # load every bridge and print what the menu would show
HueBar --pair <ip>                    # add a bridge and wait for its link button
HueBar --add-bridge <ip> <app-key>    # add a bridge with an existing app key
HueBar --snapshot out.png [--expand]  # render the menu offscreen to a PNG
```

(`HueBar` = `/Applications/HueBar.app/Contents/MacOS/HueBar`)

## Licence

Copyright (C) 2026 martfo

HueBar is free software: you can redistribute it and/or modify it under the terms of the GNU
General Public License as published by the Free Software Foundation, either version 3 of the
License, or (at your option) any later version. It is distributed in the hope that it will be
useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
FOR A PARTICULAR PURPOSE. See [LICENSE](LICENSE) for the full text.

Philips Hue is a trademark of Signify. HueBar is an independent project and is not affiliated with
or endorsed by Signify.
