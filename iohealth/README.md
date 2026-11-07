# ioHealth for iPhone

Copies your Apple Health data, all of it or just the types you pick, to your own
[ioHealth server](https://github.com/avandeputte/iohealth), which keeps it in MariaDB and gives you a fitness web app on
top of it. Nothing goes through a cloud service: the phone uploads straight to your server, over HTTPS behind your
reverse proxy or plain HTTP on your own network.

Health data only exists on the iPhone (on macOS, `HKHealthStore.isHealthDataAvailable()` is always `false`), which is
why the app is iPhone only.

- **Everything or a choice**: every HealthKit type the app can read, grouped and searchable under **Data types**,
  marked when the phone has no data for them.
- **Incremental**: later syncs send only what is new or changed (HealthKit anchors, advanced only for batches the
  server has acknowledged); **Send everything again** for a new or emptied database.
- **Automatic**: syncs when the app opens, when iOS reports new Health data (background delivery, about hourly while
  the phone is unlocked) and in background-refresh slots.
- **The suite's accounts**: signs in with the same user name and password as the web app and the other io apps
  (kept in the Keychain). Each person in the household uploads into their own account.

## Build and run

You need a Mac with Xcode 15 or later, an iPhone on iOS 17 or later, and an Apple developer team (a free Apple ID
works, but the app then has to be re-installed every 7 days).

```sh
brew install xcodegen        # once
git clone https://github.com/avandeputte/iohealth-apps && cd iohealth-apps
xcodegen generate
open ioHealth.xcodeproj
```

In Xcode select the **ioHealth** target › *Signing & Capabilities* › pick your Team (HealthKit and background
delivery are already enabled through the entitlements in `project.yml`), plug in your iPhone, choose it as the run
destination, and run.

### First run

1. Open **ioHealth**, tap **Allow access to Health data**, and on Apple's permission screen turn everything on. (What
   you actually sync is chosen separately in step 3, without asking again.)
2. Under **Server**, enter the server's URL (`https://health.example.com`, or `http://192.168.1.10:8650` at home)
   and your **user name and password**. **Test connection** checks the address; the account is checked at the first
   sync.
3. Optionally open **Data types** and switch off what you don't want.
4. Tap **Sync now**. A decade of Apple Watch data (a few million samples) takes a few minutes; keep the app open for
   the first sync.

The account must be an **editor** (or admin) in ioHealth; a viewer can look but not upload.

## TestFlight

1. In App Store Connect, create the app once (bundle id `net.iothing.iohealth`).
2. `ASC_KEY_ID=… ASC_ISSUER_ID=… tools/testflight.sh` builds, signs and uploads it, with the same API key as
   ionotes and iopix. The build number is the build's date and time.
3. In TestFlight, add yourself as an internal tester and install it from Apple's TestFlight app.

## Syncing

The app opens a session (`POST /v1/sessions`), sends gzip NDJSON batches (`POST /v1/sessions/{id}/items`, one line
per item as in `Shared/SyncProtocol.swift`) and closes it (`POST /v1/sessions/{id}/finish`). Each batch carries a
sequence number and every write is an upsert keyed on HealthKit's UUIDs, so a batch resent after a lost reply is
never applied twice. The server's README describes the API and the tables.

Not sent: ECGs (most of the data by volume), vision prescriptions (HealthKit reads them one at a time, with a prompt)
and clinical (FHIR) records (a separate entitlement Apple grants per app).

## Layout

| path | what |
|---|---|
| `iOS/` | the iPhone app (SwiftUI): Health reading, type selection, the sync engine and client, background sync |
| `Shared/` | the upload line format (`SyncProtocol.swift`), the same as the server's |
| `tools/` | `testflight.sh` (build, sign and upload to TestFlight) and its export options |
| `project.yml` | [XcodeGen](https://github.com/yonaskolb/XcodeGen) spec for the Xcode project |

The bundle ID is `net.iothing.iohealth`, as `net.iothing.ionotes` and `net.iothing.iopix`.

## License

GPL-3.0-or-later (the GNU General Public License, version 3 or later), see [LICENSE](LICENSE).
