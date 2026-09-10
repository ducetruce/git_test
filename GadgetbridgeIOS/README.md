# Gadgetbridge for iOS

An independent, from-scratch iOS implementation inspired by
[Gadgetbridge](https://codeberg.org/Freeyourgadget/Gadgetbridge) (Android):
a companion app for BLE wearables that doesn't require the vendor's cloud
service. No Gadgetbridge source code was copied — this is a new codebase
that follows a similar architecture (per-device coordinators behind a
common interface, local-only storage) adapted to iOS's frameworks and
platform restrictions.

## Scope of this codebase

Gadgetbridge on Android supports 200+ device models, most through
protocols the project reverse-engineered over years (Mi Band, Amazfit,
Pebble, Fossil, etc.). Reproducing that catalog is a multi-year effort on
its own and out of scope here. What this repository provides instead is a
**working architectural foundation**:

- A `DeviceCoordinator` / `DeviceSession` pattern (`Sources/GadgetbridgeCore/Coordinators`)
  so a new device family is added by writing one coordinator, not by
  touching the scanning, storage, or UI code.
- A `DeviceTransport` abstraction (`Sources/GadgetbridgeCore/BLE`) that
  keeps all protocol logic free of `CoreBluetooth`, so coordinators are
  unit-testable with a mock transport and the same code could, in
  principle, run against a different BLE stack.
- **One fully working coordinator**, `GenericBLECoordinator`, which talks to
  any peripheral exposing standard Bluetooth SIG GATT profiles: Heart Rate
  (`0x180D`), Battery (`0x180F`), Device Information (`0x180A`), Current
  Time (`0x1805`), and outgoing alerts via the Alert Notification Profile
  (`0x1811`). These are public, documented profiles — no reverse
  engineering involved — so this already works with real hardware such as
  Bluetooth heart-rate straps and many entry-level fitness bands.
- Local, dependency-free persistence (`Sources/GadgetbridgeCore/Persistence`)
  for paired devices and time-series samples (JSON-lines files under the
  app's Application Support directory).
- A SwiftUI app (`Sources/GadgetbridgeApp`) built around a dark
  instrument-panel design system (`Design/InstrumentTheme.swift`): a
  data-first home screen with a Swift Charts trace, device management,
  pairing, and the protocol log as a first-class screen.
- **Health metrics** (`Sources/GadgetbridgeCore/Health`) — see below.

## Health tracking

Everything here is derived from data the hardware actually sends. Nothing
is synthesised to fill out a dashboard:

- **Full `0x2A37` parsing.** The standard Heart Rate Measurement
  characteristic optionally carries beat-to-beat (RR) intervals, sensor
  contact state, and cumulative energy alongside the pulse rate. Most
  implementations read byte 1 and discard the rest; this parses the whole
  payload, which is what makes the rest of this list possible.
- **Heart rate variability.** RMSSD and SDNN computed from those RR
  intervals (`HeartRateVariability`). Intervals outside 0.3–2.0s are
  discarded as artefacts first — a single missed beat otherwise dominates
  RMSSD completely. Because HRV is only meaningful over a window of
  consecutive beats rather than the one or two a single notification
  carries, `HRVAccumulator` buffers a minute's worth and emits one reading
  per window, or none if too few usable beats arrived.
- **Resting heart rate**, estimated as the low decile of the window rather
  than the minimum, so one dropout doesn't define it.
- **Heart rate zones**, the standard five-zone model as fractions of
  maximum heart rate, with the usual age-based estimate available as a
  starting point.
- **Sensor contact**, surfaced rather than ignored: a strap that has
  slipped reports plausible-looking but meaningless numbers.
- **Apple Health export** (`HealthKitExporter`), one-directional and only
  on explicit authorization — the app never reads from HealthKit. HRV is
  exported as SDNN because that is specifically what HealthKit's HRV type
  stores; RMSSD stays local rather than being filed under a label that
  would misrepresent it.

### Storage and connection behaviour

Two things a tracker has to get right, which are easy to leave broken:

- **Storage is bounded.** A sensor notifying at 1 Hz produces ~86,000
  readings per device per day. Every reading is published live to the UI,
  but writes are downsampled (default: one per 15 seconds), files are
  bucketed by UTC day so a one-hour query reads one day's file rather than
  all history, and buckets past the retention window are deleted on
  connect. The live view appends incoming readings to its series instead
  of re-reading the window, so a new sample costs nothing to display.
- **Dropped links come back on their own.** Wearables leave range
  constantly. An unexpected disconnect re-issues the CoreBluetooth connect
  request — which never times out — so iOS restores the link whenever the
  device reappears, including from the background; a restoration
  identifier lets it happen after a relaunch. Tapping Disconnect is
  distinguished from a drop: it cancels the link for real (which the app
  previously never did, leaving the radio connected with nothing
  listening) and stops the retry.

Step counting and sleep staging are deliberately **absent**: there is no
standard GATT characteristic for either, so on a standard-profile device
they can't be read at all, and on Zepp OS they live behind the proprietary
sync protocol that isn't implemented. The `ActivitySample` and
`SleepSession` models exist for whoever implements that; nothing currently
produces them.
- **A second coordinator**, `AmazfitHelioCoordinator`
  (`Sources/GadgetbridgeCore/Coordinators/AmazfitHelio`), targeting the
  Zepp OS / Huami protocol family used by the Amazfit Helio Strap. This one
  *is* a genuine reverse-engineered vendor protocol — see the dedicated
  section below, because unlike everything above, it comes with real,
  specific caveats about what's verified versus best-effort.

`DeviceFamily` (`Sources/GadgetbridgeCore/Models/DeviceFamily.swift`) lists
`miBand`, `pebble`, and `fitPro` as placeholders — no coordinator is
registered for them yet. Peripherals matching those families show up in
the pairing screen as "Unsupported" until someone implements and registers
a coordinator for that protocol.

## Amazfit Helio Strap: start with broadcast mode

**Try this before anything else.** The Helio Strap has a heart-rate
broadcast mode which, per Amazfit's own documentation, "uses the standard
Bluetooth protocol and supports connection with all third-party devices
that also use the standard Bluetooth protocol." That means plain GATT
`0x180D` — no vendor handshake, no pairing key, and none of the
reconstructed protocol constants below.

So: enable heart-rate broadcast on the strap, then pair it here. The app
detects the standard Heart Rate service and takes that path automatically,
skipping the vendor authentication entirely (`AmazfitHelioSession.start`).
The pairing screen labels such a device `broadcast · no key` and won't ask
for a pairing key it doesn't need.

What you get: live heart rate, and — if the strap includes beat-to-beat
intervals in its broadcast — HRV, which the Zepp app itself historically
does not export to Apple Health. What you don't get: history, steps, or
sleep. Those are recorded passively and only leave the strap through the
proprietary sync protocol.

Whether the broadcast carries RR intervals is device-specific and not
documented, so the app answers it empirically: the first heart-rate
notification of every connection is logged with its raw bytes and a plain
verdict — `N RR interval(s) — HRV available`, or `no RR intervals — HRV
unavailable from this sensor`. Check the Protocol log after connecting.

## Amazfit Helio Strap: the proprietary protocol

Zepp OS devices (the Helio Strap included) authenticate with an
ECDH-over-**NIST-B163** handshake — a *binary-field* elliptic curve, not
one of the prime-field curves (P-256, P-384, Curve25519) that
`CryptoKit`/`Security.framework` support. That's not a small detail: it's
why Gadgetbridge's own developers had to port a small C library
(`kokke/tiny-ECDH-c`, public domain) rather than use a system crypto API,
and it's why this integration required writing a small elliptic-curve
library from scratch
(`Sources/GadgetbridgeCore/Coordinators/AmazfitHelio/Crypto`) rather than
just translating business logic.

This was built without a real Helio Strap to test against, and this
sandbox's network egress blocked direct access to Codeberg (where
Gadgetbridge's source lives), GitHub, and the primary cryptographic
standards (secg.org, NIST, neuromancer.sk's curve database) while building
it — what's here was reconstructed from search-result excerpts and a
summarizing fetch tool, which paraphrases rather than guaranteeing
verbatim extraction. Confidence varies a lot by piece, so treat it
accordingly:

- **High confidence — self-tested, not just asserted.** The GF(2^163)
  field arithmetic (`GF2m163`), curve point arithmetic (`ECPointB163`),
  and AES-128 (`AES128`) are from-scratch implementations with unit tests
  in `Tests/GadgetbridgeCoreTests/AmazfitHelio` that verify them
  independently of any external source: AES matches the canonical
  FIPS-197 known-answer test vector; the published sect163r2 generator
  point is checked against the curve equation
  (`testGeneratorSatisfiesCurveEquation`) — a failure there would mean a
  transcribed constant is wrong; and a simulated two-party ECDH exchange
  is checked for agreement (`testBothSidesOfECDHAgreeOnSharedSecret`).
  Bugs are still possible, but this is the trustworthy core.
- **Medium confidence.** The curve choice (NIST B-163) and the overall
  handshake shape (exchange ephemeral EC public keys, derive a shared
  secret, mix in a per-device static key, prove key possession by
  echoing back an encrypted nonce) are corroborated by multiple
  independent sources.
- **Low confidence / explicitly unverified.** The exact command opcode
  bytes, the response-echo convention, the failure status code, and the
  precise byte range used to derive the session key
  (`AmazfitHelioSession.deriveSessionKey`) are a best-effort
  reconstruction from a summarized (not verbatim) read of Gadgetbridge's
  `InitOperation2021`. The proprietary activity/sleep/workout sync
  protocol (Huami's "chunked" data transfer) isn't implemented at all —
  only the auth handshake plus a best-effort fallback to standard
  Heart Rate/Battery GATT services once authenticated.
- **Deliberately left unverified rather than guessed:** the exact
  163-bit order of the base point. It's not needed for correctness here
  (private scalars are used raw rather than reduced mod the group order —
  see the doc comment on `CurveB163.cofactor`), and a 41-hex-digit
  constant is exactly the kind of value that's easy to mistranscribe and
  hard to notice, so it was left out rather than included with false
  confidence.

**Getting a pairing key:** like Gadgetbridge, this app can't generate or
derive the per-device secret Zepp OS devices need — it's generated and
signed by Huami's servers the first time you pair through the official
Zepp app (see Gadgetbridge's "Huami/Xiaomi server pairing" docs for how
that key gets extracted from your own paired account). The pairing screen
prompts for it as 32 hex characters — but only when the device isn't
broadcasting, since broadcast mode needs no key.

**Bottom line:** treat this as a serious, tested attempt at the hardest
part (the crypto primitives) plus an honest placeholder for the part that
can only be nailed down with a BLE capture from a real device — exactly
how Gadgetbridge's own contributors originally reverse-engineered this
protocol in the first place.

### Capturing what the device actually sends

Because the low-confidence pieces above are guesses, the handshake is
fully instrumented. Every byte written and every notification received is
logged — **including notifications the code decides to ignore**, which is
the important part: if the echo-byte convention is wrong, the device's
real answer gets discarded, and that discarded response is precisely what's
needed to fix the constants. Ignored responses are tagged `IGNORED` with
the mismatch spelled out, and each handshake phase times out after 15s
rather than hanging, so a wrong assumption surfaces as a clear failure.

To collect a transcript:

1. Pair the Helio Strap and let the connection attempt run.
2. Read the log either from Xcode's console (it's echoed to stdout) or,
   if running untethered, from **Protocol log** at the bottom of the
   device list screen — it has a Copy button.

A failing run looks roughly like:

```
[14:02:11.204] === Amazfit Helio handshake starting (device: Helio Strap) ===
[14:02:11.210] -> phase 1/2 key exchange: writing 52 bytes: 04 02 00 02 1F 3C …
[14:02:11.210]    waiting for a notification whose byte[1] == 0x04 (assumption, unverified)
[14:02:11.318] <- auth notify (68 bytes): 10 82 01 A3 9C …
[14:02:11.318]    ...IGNORED: byte[1] is 0x82 but this code expected 0x04. This is a prime
                  suspect — the echo convention is a guess.
[14:02:26.211] !! phase 1/2 key exchange timed out after 15.0s. If notifications appear
                  above marked 'ignored', this code's byte[1] echo assumption is wrong —
                  those bytes are the device's real answer.
```

That `<- auth notify` line is the useful part; with it the opcode
constants in `AmazfitHelioSession` can be corrected against reality.

**On sharing the log:** it contains ephemeral public keys, device nonces,
and AES ciphertexts — all of which cross the air unencrypted anyway. It
deliberately never contains your pairing key, the ephemeral private key,
or the derived session key, so a transcript is safe to paste into an issue
or a chat.

## Why this isn't a 1:1 port of Gadgetbridge

Two of Gadgetbridge's core Android features have no direct iOS equivalent,
and pretending otherwise would just produce a broken app:

- **Reading other apps' notifications.** Android's
  `NotificationListenerService` lets Gadgetbridge read every notification
  posted on the phone and forward it to the watch. iOS has no equivalent
  API for third-party apps — there is no way for an app to observe
  another app's notifications. On iPhone, notification mirroring to a
  wearable happens over **ANCS** (Apple Notification Center Service),
  which the accessory's own firmware speaks directly to iOS at the
  Bluetooth level; the companion app is not in that path at all, and ANCS
  central-role access requires Apple's MFi program, not just an app
  entitlement. What this app *can* do — implemented in
  `GenericBLESession.sendAlert` — is push an outgoing alert to a device
  that implements the Alert Notification Profile as a peripheral, which is
  a legitimate, standard, one-directional phone-to-accessory channel some
  fitness bands support as an ANCS alternative.
- **Raw HCI/vendor GATT access.** Gadgetbridge's Android reverse-engineered
  protocols often rely on details CoreBluetooth doesn't expose (raw MAC
  addresses, certain low-level pairing flows). `Device.peripheralIdentifier`
  stores `CBPeripheral.identifier` (a per-app-install UUID), not a MAC
  address, for this reason.

## Building

There's no Swift toolchain in this environment, so none of this has been
compiled — treat it as a reviewed-by-hand starting point, not
compiler-verified code. To build it for real:

1. Install [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).
2. From `GadgetbridgeIOS/`, run:
   ```
   xcodegen generate
   open Gadgetbridge.xcodeproj
   ```
3. Set your Development Team in the Signing settings and run on a
   physical device (CoreBluetooth's central role is unavailable in the
   iOS Simulator, so a real iPhone is required to test scanning/pairing).

`GadgetbridgeCore` has no dependency on `CoreBluetooth`, `SwiftUI`, or
`UIKit`, so it can also be built and tested independently of Xcode:
```
cd GadgetbridgeIOS
swift test
```

## Layout

```
GadgetbridgeIOS/
  Package.swift                  # SwiftPM manifest for GadgetbridgeCore (platform-agnostic)
  project.yml                    # XcodeGen manifest for the iOS app target
  Sources/
    GadgetbridgeCore/            # Models, BLE protocol abstractions, coordinators, persistence, sync
    GadgetbridgeApp/             # SwiftUI app, CoreBluetooth-backed transport, views, view models
  Tests/
    GadgetbridgeCoreTests/       # Unit tests for the platform-agnostic core
```

## Adding support for a new device family

1. Add a case to `DeviceFamily` if it's genuinely a new protocol family.
2. Implement `DeviceCoordinator` (recognize the peripheral) and
   `DeviceSession` (speak its protocol over `DeviceTransport`) — see
   `Sources/GadgetbridgeCore/Coordinators/GenericBLE` for a full example.
3. Register an instance with `DeviceCoordinatorRegistry.shared` (see
   `GadgetbridgeApp.swift`'s `init`).
4. Nothing in `DeviceManager` or the UI needs to change.

## License

Intended to be licensed under GPL-3.0-or-later, matching the spirit of the
Gadgetbridge project this draws architectural inspiration from. Add a
`LICENSE` file with the full GPLv3 text (https://www.gnu.org/licenses/gpl-3.0.txt)
before distributing.
