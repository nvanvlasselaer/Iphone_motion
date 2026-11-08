# Iphone_motion: IMU recorder for iPhone and Apple Watch

Records inertial sensor data on the **iPhone**, the **Apple Watch**, or **both at once with clock synchronization**, for offline kinematic analysis. A typical use is 3D knee kinematics while running, with the iPhone on the thigh and the Watch on the shank.

The app records data only; joint angles are computed offline. Every session folder documents itself: CSV files, `session.json` with all metadata, and [DATA_FORMAT.md](Packages/RecorderCore/Sources/RecorderCore/Resources/DATA_FORMAT.md). That file describes every column, the coordinate frames, how to align the two devices, and suggested methods for joint angles.

## What is recorded

| Mode | Sensors | Rate |
|---|---|---|
| iPhone | iPhone device motion (attitude quaternion, Euler angles, gyroscope, user acceleration, gravity, magnetometer) | 50 or 100 Hz |
| Watch | Watch device motion, optional raw accelerometer | 200 Hz device motion, 800 Hz accelerometer (Series 8 / Ultra and later); otherwise ≤ 100 Hz |
| Both | Both of the above, plus clock-synchronization pings | as above |

The iPhone is always the controller: it starts and stops the Watch and speaks the cues of the guided calibration protocol. The Watch vibrates at each step.

Sessions are stored under **Files ▸ On My iPhone ▸ Iphone_motion ▸ Sessions** and can be shared as a .zip from the Sessions tab.

## Requirements

- iPhone with iOS 17 or later.
- Apple Watch with watchOS 10 or later. The 200 Hz and 800 Hz streams need a Series 8, Ultra or newer.
- An Apple Developer team with the **HealthKit** capability. The Watch records inside a workout session; no workout is saved to Health.
- **Xcode:**
  - To deploy to devices running iOS or watchOS 26, use **Xcode 26** or later. It runs on macOS 15.6+.
  - Install the **watchOS platform** in Xcode ▸ Settings ▸ Components. Without it, Xcode cannot build the iOS app, because the iOS app embeds the Watch app.

## First-time setup

1. Open `Iphone_motion.xcodeproj`.
2. In **Signing & Capabilities**, check both the `Iphone_motion` and `Iphone_motion Watch App` targets: the team, *HealthKit*, and for the Watch target *Background Modes ▸ Workout processing*.
3. Run the `Iphone_motion` scheme on the iPhone. If the Watch app does not install automatically, use the Watch app on the iPhone ▸ Available Apps, or run the `Iphone_motion Watch App` scheme on the Watch.
4. **Open the app once on the Watch and tap Allow** to grant Health and Motion & Fitness access. It cannot ask when the iPhone launches it in the background.

## Recording a session

1. **Record tab:**
   - Choose *iPhone*, *Watch* or *Both*.
   - Enter a subject code (pseudonymised, never a name) and a trial label.
   - Set where each device is worn.
2. For Watch modes, tap **Connect**. This launches the Watch app, which starts its workout session and reports *Ready*.
3. Resolve any errors listed under **Checks**, then tap **Start recording**.
4. With **Guided calibration** on, the iPhone speaks each step. The default *knee* preset:
   1. stand still, 5 s;
   2. three jumps (time synchronization);
   3. bend and straighten the instrumented knee five times while standing on the other leg (functional calibration);
   4. the trial: fixed duration, or until you press **End trial**;
   5. three jumps;
   6. stand still.

   The session stops by itself at the end. Each step's window is logged in the events file.
5. **Pocket mode:** the iPhone screen stays on but dark and ignores touches. Hold the lock for 2 s to unlock.
6. After **Stop**, the Watch sends its files to the iPhone. The session shows *waiting for Watch* until they arrive, then *complete*.

## Lab checklist

- **Do Not Disturb / Focus** on both devices. A phone call interrupts the recording.
- **Guided Access** (Settings ▸ Accessibility) on the iPhone, with the side and volume buttons disabled. Otherwise a strap pressing the side button locks the iPhone and pauses its recording. The app logs this.
- **Wrist Detection off** on the Watch (Settings ▸ Passcode) when it is strapped to a leg or worn over clothing.
- Keep the straps clear of the Watch Ultra's Action button and the iPhone's Action button.
- **Low Power Mode off**, battery above 20 %.
- **Placement:**
  - iPhone: tight on the lateral distal thigh.
  - Watch: flat on the anteromedial tibia (little soft tissue).
  - Keep each device's mounting the same within a session; the calibration steps make the analysis independent of the exact orientation.
- **Watch settings:** keep the Watch's wrist and crown settings the same across sessions. They are recorded in `session.json`.

## Synchronizing the two devices

Each device timestamps samples with its own clock (`t_uptime_s`). Two inputs put the Watch on the iPhone time base:

- **The clock model** in `session.json → clock_sync`, fitted from the ping exchange. It is accurate to about half the best round trip, typically 5–30 ms.
- **The jumps**, for sample-level alignment by cross-correlation.

[DATA_FORMAT.md](Packages/RecorderCore/Sources/RecorderCore/Resources/DATA_FORMAT.md) gives the formulas.

## Project structure

```
Packages/RecorderCore/        Shared, platform-independent logic (Swift package, unit-tested on the Mac):
                              binary journals, CSV conversion, clock-sync estimation, message protocol,
                              session metadata, guided-protocol and Watch state machines, DATA_FORMAT.md
Iphone_motion/                iOS app
  App/                        entry point, settings, service container
  Recording/                  iPhone sensor recorder, pocket mode, app life-cycle events
  Session/                    session orchestration, storage, Watch file ingestion, zip export
  Link/                       WatchConnectivity, clock-sync pings, launching the Watch app
  Guidance/                   guided protocol runner, voice cues
  UI/                         SwiftUI views (Record, Sessions, Settings)
Iphone_motion Watch App/      watchOS app: workout session, sensors, link, local session store
Iphone_motionTests/           iOS unit tests (session store, crash recovery)
```

New files in `Packages/RecorderCore` are picked up automatically. New app files must be added to their target in Xcode.

## Tests

```sh
swift test --package-path Packages/RecorderCore      # core logic, runs on the Mac
xcodebuild test -project Iphone_motion.xcodeproj -scheme Iphone_motion \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' -only-testing:Iphone_motionTests
```

## Known limitations

- **iPhone lock:** iOS stops sending motion data to an app a few seconds after the iPhone locks. Pocket mode keeps the app in front, but only Guided Access prevents a lock caused by pressing the side button.
- **Watch heading:** the Watch's 200 Hz device motion has an arbitrary heading. Align it with the iPhone through the calibration steps.
- **Watch vibrations** are visible in the 800 Hz accelerometer. They only happen at step cues, never inside quiet windows.
- **Not yet supported:**
  - sessions started from the Watch itself;
  - continuing a recording after the app crashed (the data up to the crash is kept).
