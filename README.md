# HT07Menu

A macOS menu-bar app that controls QCY Arcbuds HT07 earbuds over Bluetooth LE,
without the QCY phone app or an account. It speaks QCY's own BLE protocol, which
I reverse-engineered and wrote up in the `qcy-ht07-protocol` repo.

## Build

```bash
./build.sh
```

That compiles `HT07Menu.swift` into `HT07Menu.app` with `swiftc` (no Xcode
project). You need the Xcode command-line tools. It targets macOS 14 and up.

## Run

```bash
open HT07Menu.app
```

The first launch asks for Bluetooth permission, so click Allow (or turn it on
under System Settings, Privacy & Security, Bluetooth). Each rebuild gives the app
a new ad-hoc identity, so macOS may ask again after `build.sh`.

A headphones icon shows up in the menu bar. Click it for the controls.

One catch worth knowing up front: the buds only hand out their BLE control link
when they aren't playing audio to another host. Disconnect them from your phone
(and from the Mac's own audio), keep them awake and out of the case, and the app
connects. Hit Disconnect in the app to give them back to the phone.

## What it does

Noise control, as Off, ANC, or Transparency. Under ANC you pick a scene (Indoor,
Commuting, Noisy, Anti-wind) and a level from 1 to 3. Under Transparency, a level
from 1 to 6. The current mode syncs back from the buds.

Battery for the left and right bud, with a charge indicator. The case battery
isn't reachable over BLE, so it isn't shown.

Equalizer presets: Default, Pop, Heavy Bass, Rock, Soft, Classic.

A game/low-latency toggle, an L/R balance slider, and touch-gesture editing
(reassign a tap to a function). An advanced section adds an EQ read, a raw-frame
console, the firmware string, and a live log.

## How it works

It scans for the BLE advertising name `QCY-APP` (or the `1C524D43` manufacturer
signature) and connects to control service `0xA001`. Commands go to
characteristic `0x1001` (write without response), notifications come from
`0x1002`, and it reads battery from `0x0008`, version from `0x0007`, and the key
map from `0x000D`.

`HT07Menu.swift` is the whole app. `ht07probe.swift` is a small command-line
probe I used to find the GATT layout during bring-up. The frames and command IDs
are in the protocol repo.

## Limits

One BLE control host at a time, Mac or phone, not both.

Find-my-earbud isn't here. On this Realtek-based model it runs over the Classic
SPP channel, not BLE, so a BLE app can't send it.

Ad-hoc signed. For a permanent install, sign with a Developer ID so you grant
Bluetooth once.

Not affiliated with or endorsed by QCY.
