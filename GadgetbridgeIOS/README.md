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
- A SwiftUI app (`Sources/GadgetbridgeApp`) with device list, pairing,
  device detail, and a heart-rate dashboard screen.

`DeviceFamily` (`Sources/GadgetbridgeCore/Models/DeviceFamily.swift`) lists
`miBand`, `amazfit`, `pebble`, and `fitPro` as placeholders — no
coordinator is registered for them yet. Peripherals matching those
families show up in the pairing screen as "Unsupported" until someone
implements and registers a coordinator for that protocol.

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
