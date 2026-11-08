# IMU session data format

Schema version **1** (`schema_version` in `session.json`). Every session folder contains a copy of this file.

A session records one or two inertial sensors: the iPhone, the Apple Watch, or both. Each device samples with its own clock. This document describes each file, its units and conventions, and how to put both devices on one time base.

## Files

| File | Present when | Content |
|---|---|---|
| `session.json` | always | Metadata: devices, placements, streams, rates, reference frames, clock synchronization, protocol timeline, warnings |
| `iphone_motion.csv` | iPhone recorded | Device motion of the iPhone (100 Hz by default) |
| `iphone_events.csv` | always | Events logged on the iPhone, in iPhone clocks |
| `watch_motion.csv` | Watch recorded | Device motion of the Watch (200 Hz with the high-rate sensor API, else up to 100 Hz) |
| `watch_accel.csv` | Watch, 800 Hz option on | Raw accelerometer of the Watch (800 Hz) |
| `watch_events.csv` | Watch recorded | Events logged on the Watch, in Watch clocks |
| `clock_sync.csv` | Watch recorded with the iPhone as controller | Every clock-synchronization ping between iPhone and Watch |
| `DATA_FORMAT.md` | always | This document |

All CSV files use a comma separator, a `.` decimal point (independent of the phone's language settings), a header row, and UTF-8. An empty field means *not available*.

## Clocks and timestamps

Every sample and event carries `t_uptime_s`: seconds since that device booted, not counting sleep. This is the timestamp CoreMotion attaches to each sample (`CMLogItem.timestamp`). The iPhone and Watch uptimes are unrelated numbers, so the Watch time must be mapped before you compare the devices (see *Aligning iPhone and Watch*).

Event rows also carry:

- `t_continuous_s`: seconds since boot *including* sleep. If `t_continuous_s − t_uptime_s` changes during a session, the device slept.
- `t_unix_s`: wall-clock time (Unix seconds, UTC). Use it for human-readable times only; it can jump when the clock is adjusted.

## Motion files (`iphone_motion.csv`, `watch_motion.csv`)

Processed device motion (`CMDeviceMotion`): sensor fusion of the accelerometer and gyroscope, plus the magnetometer when the reference frame uses it.

| Column | Unit | Description |
|---|---|---|
| `t_uptime_s` | s | Sensor timestamp (device uptime) |
| `qw`, `qx`, `qy`, `qz` | – | Attitude quaternion: device orientation relative to the reference frame (scalar first) |
| `roll_deg`, `pitch_deg`, `yaw_deg` | deg | CoreMotion Euler angles derived from the same attitude. Convenience only: they suffer gimbal lock near ±90° pitch, so use the quaternion for analysis |
| `gyro_x_rad_s`, `gyro_y_rad_s`, `gyro_z_rad_s` | rad/s | Rotation rate in the device frame, bias-corrected, right-hand rule |
| `uacc_x_g`, `uacc_y_g`, `uacc_z_g` | g | User acceleration (gravity removed) in the device frame |
| `grav_x_g`, `grav_y_g`, `grav_z_g` | g | Gravity vector in the device frame (lying flat, screen up: `grav_z_g ≈ −1`) |
| `mag_x_uT`, `mag_y_uT`, `mag_z_uT` | µT | Calibrated magnetic field in the device frame. Empty unless the reference frame uses the magnetometer |
| `mag_accuracy` | – | Magnetometer calibration: −1 uncalibrated / not used, 0 low, 1 medium, 2 high |
| `heading_deg` | deg | Heading relative to the reference frame's X axis. Empty for arbitrary-heading frames |

Raw accelerometer = `uacc + grav`, apart from filtering.

Quaternion component precision is 7 decimals, angles 4, rates and accelerations 6, magnetic field 3 and heading 2. Values are stored internally as 32-bit floats, so the last printed digit is close to the resolution.

## Watch accelerometer (`watch_accel.csv`)

| Column | Unit | Description |
|---|---|---|
| `t_uptime_s` | s | Sensor timestamp (Watch uptime) |
| `acc_x_g`, `acc_y_g`, `acc_z_g` | g | Raw acceleration including gravity, device frame (Apple sign convention: at rest, screen up, `acc_z_g ≈ −1`) |

The 800 Hz stream is suited to impact analysis (e.g. tibial shock). Watch haptics (vibrations at protocol cues) are visible in it; see *Artifacts*.

## Event files (`iphone_events.csv`, `watch_events.csv`)

| Column | Description |
|---|---|
| `t_uptime_s` | Device uptime when the event was logged |
| `t_continuous_s` | Device uptime including sleep |
| `t_unix_s` | Wall clock |
| `event` | Event name (below) |
| `step` | Protocol step, when applicable |
| `detail` | Free text (reason, value, label) |

Main events:

- **iPhone session:**
  - `session_created`, `recording_start` (detail = reference frame and rate);
  - `stop_requested`, `recording_stop` (detail = reason: `user`, `protocol_complete`);
  - `marker` (detail = label: `M1`, `M2`, … from the iPhone; `watch: W1`, … from the Watch);
  - `end_trial_pressed` (detail = `phone` or `watch`);
  - `clock_anchor` (every 10 s).
- **Guided protocol (iPhone):**
  - `protocol_start` (detail = preset);
  - `step_begin`, `cue_start`, `cue_end`, `cue_timeout`;
  - `window_start` (detail = planned duration, s), `window_end`;
  - `reminder`;
  - `trial_end_requested` (detail = timer / phone / watch), `advance_ignored`;
  - `protocol_complete`, `protocol_aborted`, `protocol_interrupted`.
- **iPhone state:**
  - `app_active`, `app_inactive`, `app_background`, `app_foreground`, `protected_data_unavailable`;
  - `proximity_covered`, `proximity_uncovered`, `pocket_lock`, `pocket_unlock`;
  - `guided_access`, `audio_interruption`, `thermal_state`, `low_power`;
  - `motion_restart` (device motion restarted, so the heading reference changed).
- **Watch link (iPhone):** `watch_command` (detail = command and result), `watch_link` (reachable / unreachable / no reply), `watch_status`.
- **Watch:**
  - `command_received`, `start_command`, `start_rejected`, `stop_ignored`, `duplicate_launch`;
  - `arming`, `armed`, `disarmed`, `workout_started`, `workout_failed`;
  - `sensors_started` (detail = API and rate), `sensor_error`, `recording_start`, `recording_stop`, `recording_end` (detail = reason);
  - `step_received`, `haptic_played`, `marker`, `end_trial_pressed`;
  - `water_lock`, `low_battery`.

## Protocol windows

`session.json → guided_protocol.timeline` lists, for every protocol step, when its measurement window opened and closed, in **iPhone uptime** (`window_start_uptime_s`, `window_end_uptime_s`). The window opens after the spoken cue has finished. The same times appear in `iphone_events.csv` as `window_start` / `window_end`. To find a window in the Watch data, map the times with the clock model below.

Default "knee" preset:

| Step | Kind | Window | Use |
|---|---|---|---|
| `static_start` | static | 5 s, quiet | Standing posture: gravity direction of each segment |
| `jumps_start` | sync | 6 s | Three jumps: impacts for time alignment |
| `rest_1` | rest | 3 s, quiet | Settle |
| `functional` | functional | 15 s | Knee flexion/extension on one leg: joint axis |
| `rest_2` | rest | 3 s, quiet | Settle |
| `static_seated`, `stand_up` | static, rest | 5 s, 3 s | Optional second static pose |
| `trial` | trial | fixed or open-ended | The activity |
| `settle` | rest | 10 s | Come to a stop |
| `jumps_end` | sync | 6 s | Three jumps: end-of-session alignment |
| `static_end` | static | 5 s, quiet | Standing posture again |

## Clock synchronization (`clock_sync.csv`)

While the Watch records under iPhone control, the iPhone pings the Watch over WatchConnectivity: a burst of 20 pings after the start, one ping every 5 s, and a burst of 20 when the trial ends.

| Column | Description |
|---|---|
| `seq` | Ping number |
| `burst` | `start`, `periodic` or `end` |
| `t1_iphone_s` | iPhone uptime when the ping was sent |
| `t2_watch_s` | Watch uptime when the ping arrived |
| `t3_watch_s` | Watch uptime when the reply was sent |
| `t4_iphone_s` | iPhone uptime when the reply arrived |
| `rtt_s` | Network round trip δ = (t4 − t1) − (t3 − t2) |
| `offset_watch_minus_iphone_s` | θ = ((t2 − t1) + (t3 − t4)) / 2; the true offset lies within ±δ/2 |
| `status` | `ok`, `timeout` or `error` |
| `used_in_fit` | 1 if the ping entered the fit in `session.json` |

`session.json → clock_sync` holds the fitted model, computed as follows:

1. Pings are grouped in windows (each burst, and periodic pings per 60 s).
2. The lowest-delay quarter of each window is kept, and the median offset taken.
3. A weighted line θ(t) = θ0 + r·(t − m_ref) is fitted, with weights 1/δmin².

The summary contains:

- `offset_s` = θ0 (Watch − iPhone, at iPhone uptime `ref_iphone_uptime_s` = m_ref);
- `drift_ppm` = r·10⁶. It is 0 with `drift_estimated` false when the pings span less than 60 s;
- `residual_rms_s`, `min_rtt_s`, and the per-window values.

## Aligning iPhone and Watch

1. **Coarse (from the pings).** Convert Watch time to iPhone time:

   t_iphone = (t_watch − θ0 + r·m_ref) / (1 + r), with r = `drift_ppm` × 10⁻⁶.

   The accuracy is about half the minimum round trip (`min_rtt_s` / 2), typically 5–30 ms. The uptime clocks drift by tens of ppm, about 36 ms per 30 min at 20 ppm, which the drift term corrects.
2. **Fine (from the data).**
   - Cross-correlate the acceleration norm of both devices around the jumps. Use the `jumps_start` and `jumps_end` windows, `|uacc|` from the motion files or `|acc| − 1` from `watch_accel.csv`.
   - Search lags within ± (`min_rtt_s` + 50 ms) of the coarse alignment.
   - The start and end jumps give the offset and the drift to about one sample.
   - When running, every foot strike is another impact. Use the coarse alignment to avoid locking onto the wrong stride (a stride lasts about 0.7 s).
3. **Resample.** Resample both streams on a common time base, using SLERP for quaternions and linear interpolation for vectors.

Without the iPhone in control (no pings), map with `t_unix_s` of `clock_anchor` events. The Watch takes its wall clock from the iPhone; accuracy is unknown, so rely on the jumps.

## Coordinate frames

**Device frame** (gyro, accelerations, gravity, magnetic field):

- **iPhone:** +X to the right of the screen, +Y toward the top of the screen, +Z out of the screen (portrait, screen facing you).
- **Apple Watch:** with the screen up and the Digital Crown on the right, +X points toward the crown, +Y toward the top edge (12 o'clock) and +Z out of the display. `session.json → devices.watch.info` records `wrist_location` and `crown_orientation`. Apple does not document whether these settings remap the axes, so keep them constant between sessions or check with a known rotation.

**Reference frame** (attitude): Z points up (opposite gravity). X depends on the frame named in `reference_frame` of the stream:

| `reference_frame` | X axis |
|---|---|
| `xArbitraryZVertical` | Arbitrary horizontal direction fixed when device motion started (`dm_start_uptime_s`); gyro + accelerometer only, so heading drifts slowly |
| `xArbitraryCorrectedZVertical` | Arbitrary, magnetometer-corrected heading |
| `xMagneticNorthZVertical` | Magnetic north |
| `xTrueNorthZVertical` | Geographic north |
| `arbitrary (not selectable)` | Watch high-rate API: Z up, arbitrary heading |

The Watch's high-rate API (`CMBatchedSensorManager`) does not let the app choose the frame; treat its heading as arbitrary. The headings of the two devices are therefore not related, and only the vertical axis is shared. Joint angles need a heading alignment, which the calibration below provides.

Magnetometer-based frames are disturbed indoors and near treadmills, steel and electronics.

## From raw data to joint angles (not done by the app)

The app records data; it does not compute joint angles. A typical pipeline for a two-segment joint (e.g. iPhone on the thigh, Watch on the shank) is:

1. **Time alignment.** As above.
2. **Sensor-to-segment calibration** from the protocol windows:
   - in `static_start` / `static_end`, gravity in each sensor gives the segment's longitudinal axis;
   - in `functional`, the dominant rotation axis gives the knee flexion axis (Favre et al. 2009).
   This makes the result independent of how the devices were strapped.
3. **Heading alignment** between the two sensors. Assume the static pose is the neutral joint angle, then correct the slow heading drift with the hinge-joint constraint (Laidig et al. 2017).
4. **Joint angles** with a joint coordinate system: flexion/extension, ab/adduction (varus/valgus), and internal/external rotation (Grood & Suntay 1983; ISB, Wu et al. 2002). For IMU-based knee angles in gait, see Seel et al. 2014.

References:

- Favre J, Aissaoui R, Jolles BM, de Guise JA, Aminian K. Functional calibration procedure for 3D knee joint angle description using inertial sensors. *J Biomech.* 2009;42(14):2330-2335. PMID 19665712.
- Seel T, Raisch J, Schauer T. IMU-based joint angle measurement for gait analysis. *Sensors.* 2014;14(4):6891-6909. PMID 24743160.
- Laidig D, Schauer T, Seel T. Exploiting kinematic constraints to compensate magnetic disturbances when calculating joint angles of approximate hinge joints from orientation estimates of inertial sensors. *IEEE Int Conf Rehabil Robot.* 2017:971-976. PMID 28813947.
- Grood ES, Suntay WJ. A joint coordinate system for the clinical description of three-dimensional motions: application to the knee. *J Biomech Eng.* 1983;105(2):136-144. PMID 6865355.
- Wu G, et al. ISB recommendation on definitions of joint coordinate system of various joints for the reporting of human joint motion, part I: ankle, hip, and spine. *J Biomech.* 2002;35(4):543-548. PMID 11934426.

## Data quality

`session.json → devices.<device>.streams[].stats` gives, per stream:

- `count`;
- `first_t` and `last_t`;
- `achieved_hz`;
- `gap_count` (intervals longer than 1.5 sample periods) and `max_interval_s`;
- `non_monotonic_count`.

`truncated_tail_bytes` > 0 means the recording was cut off mid-write; all complete samples are kept. `status` is:

- `complete`;
- `awaiting_watch_data` (the Watch files have not arrived yet);
- `interrupted` (the app or Watch stopped unexpectedly; the data up to that point is valid).

Check `warnings` and the events `app_background`, `motion_restart`, `audio_interruption` and `workout_failed` before analysing a session.

## Raw journal files (only after a failed conversion)

Both apps first record into binary journals and convert them to CSV at the end. If a conversion fails, for example because the disk is full, the journal is kept in the session folder instead of being deleted (`iphone_motion.journal.bin`), and a warning says so.

The format, all little-endian:

- **Header, 16 bytes:** ASCII `IMUJ`, then `version` (u16 = 1), `kind` (u16), `record_size` (u32) and 4 reserved bytes.
- **Records:** `record_size` bytes each, until the end of the file. A partial last record (cut off by a crash) is ignored.

| Kind | Record size | Content |
|---|---|---|
| 1 (motion) | 92 B | `t` (float64, s), then float32: qw, qx, qy, qz, roll, pitch, yaw (rad), gyro x y z (rad/s), user acceleration x y z (g), gravity x y z (g), magnetic field x y z (µT, NaN if unavailable); then int32 magnetometer accuracy, float32 heading (deg, NaN if unavailable) |
| 2 (accel) | 20 B | `t` (float64, s), then float32 acceleration x y z (g) |

In Python, these files can be read with NumPy, using the record layout above as a structured dtype. Skip the 16-byte header and drop any incomplete last record.

## Artifacts

- **Watch haptics.** The Watch vibrates when a protocol step begins (during the spoken cue, never inside a quiet window). Vibrations appear in `watch_accel.csv` and slightly in `watch_motion.csv`. `haptic_played` events give their times.
- **Water Lock.** When it is released (Digital Crown), the speaker ejects water with a loud tone that shows in the accelerometer.
- **Heading resets.** Device motion restarts at the start of a recording. Any later restart is logged as `motion_restart`.
