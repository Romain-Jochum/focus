# iPhone in use, from its Bluetooth advert

Date of research: 2026-10-12. Machine: Apple silicon MacBook, macOS 26.6. Phone: an iPhone 15 Pro. Throwaway spike code (not kept): a CoreBluetooth scanner built with `swiftc -O` and an embedded Info.plist carrying `NSBluetoothAlwaysUsageDescription`.

## Why

The built-in camera's field of view is narrow: a phone held low or to the side is out of frame, so the camera rule is easy to beat. The brief asked for something "extremely reliable, at least when I'm on the phone", ideally cheap, using the iPhone 15 Pro.

## The signal

Every iPhone, iPad and Mac broadcasts Apple manufacturer data (company id `4C 00`) as a list of type-length-value messages. Type `0x10`, "Nearby Info", carries an activity level in the low nibble of its first value byte. It is undocumented but has been stable for years and is described in public research (Celosia and Cunche, "Discontinued Privacy", PETS 2020; Martin et al., "Handoff All Your Privacy", PETS 2019; the furiousMAC continuity dissector). macOS exposes it to any app with Bluetooth permission through `CBAdvertisementDataManufacturerDataKey`; no pairing, no companion app, nothing on the phone.

## What the capture showed

A 10-minute capture while locking, unlocking, scrolling and watching a video on the iPhone (codes in decimal):

| Time | iPhone | Code | RSSI |
|---|---|---|---|
| 0 s | locked on the desk | 3 (idle, screen off) | -60 dBm |
| 28 s | unlocked | 11 (recent interaction) | -54 dBm |
| 43 s | scrolling | 15 | -46 dBm |
| 50 s | paused | 11 | -55 dBm |
| 54 s | video | 15 | -44 dBm |
| 56 s | locked | 3 | -35 dBm |
| 252 s on | carried away | 4 and 8 | -66 to -84 dBm |

Other devices nearby reported 9 constantly at -57 to -62 dBm, 1 (reporting off), and one other iPhone reported 15 at -72 to -79 dBm. The iPhone in hand or on the desk read -35 to -55 dBm. The Always-On display of the locked 15 Pro still reads 3.

## Recognising the owner's iPhone

A second 41-minute capture (minute 0 to minute 41, five separate scanner processes, 15,028 Apple adverts from 36 identifiers):

- The iPhone kept one CoreBluetooth identifier (`<id-A>`) the whole time and across processes (3,494 adverts, longest gap 32 s), while other devices rotated theirs (`<id-B>` vanished at 13 min 52 s and `<id-C>` appeared at 14 min 5 s at the same strength; `<id-D>` to `<id-E>` at 23 min 45 s and 23 min 47 s). macOS presumably resolves the private address of devices on the owner's Apple ID; the stability is observed, not documented.
- `retrievePeripherals(withIdentifiers:)` in a fresh process returns it, named after its owner, and a plain connect (no pairing) reads Device Information: "Apple Inc." and a model identifier. A second iPhone nearby and an iPad reported their own model identifiers, so the model string alone cannot single out the owner's phone.
- Its manufacturer data is 27 bytes (Nearby Info plus a constant tail), the others 10 to 11.

The low bit of the activity code is a separate flag: from minute 11 it was clear and the codes moved with it (15 to 14, 3 to 2, and 8, 4, 0, 12 while locked on the desk). At minute 37 the Mac went idle and from minute 38 the iPhone reported 14 at -42 dBm for over ten minutes, which reads as "in use" (the activity level looks like bits 1 to 3). Public research calls 14 a call; either way it is use.

Design: the setup checklist's "Your iPhone" (or Settings › iPhone › Find) listens for 30 s for a device reporting use at -50 dBm or stronger, i.e. unlocked in the owner's hand next to the Mac, and remembers its identifier and name. From then on only it counts. If it has not been heard for 10 minutes (left in another room, or the identifier changed after a Bluetooth reset), any nearby iPhone counts again, so detection never silently stops. Tested with the real sensor code: with the remembered identifier set, only `<id-A>`'s codes counted.

## Rule

In use = codes 11, 14 or 15 from the remembered iPhone (or, until it is found, any device) whose smoothed RSSI is at least -62 dBm, seen in the last 6 s. Code 7 (screen on) is left out because notifications and StandBy light the screen without use; 9 is left out because Macs and Apple TVs report it all day. The engine counts it as phone after 15 s of continuous use with no keyboard or mouse input for 10 s, so a glance at a notification or reading a 2FA code while typing does not trigger it. Before the iPhone is remembered, a nearby stranger's iPhone could pass the RSSI bar in a café; at home the next-strongest in-use iPhone was 10 dB below it.

## Cost

Raw scan with duplicates: 0.26 to 0.31% CPU of the scanning process (30 s windows, about 11 adverts a second nearby); restarting a coalesced scan every 4 s did not reduce the advert rate. In `Focus --probe` (same build, Mac idle, so the camera phone model also runs): 2.57% without the scan, 3.00% with a continuous scan. Final design: scan only while the Mac has had no input for 5 s (the phone rule needs 10 s), 2 s on and 2 s off: 2.78 to 2.80% in the same probe, and nothing while typing. Footprint unchanged (176 to 186 MB).
