# LIFX Mini W control

A C CLI for a LIFX Mini W bulb on your local Wi-Fi network. No cloud account or API token is needed. Uses the [LIFX LAN protocol](https://lan.developer.lifx.com/docs/communicating-with-device) over UDP port 56700.

Build with a C11 compiler and GNU Make on macOS or Linux.

The default build includes bulb control and `music --levels-stdin`. Native microphone capture is opt-in.

```sh
make
./build/lifx-control 192.168.1.50 50
```

Replace the example IP with your bulb's IPv4 address and `50` with a brightness percentage from **0 to 100**. Decimal percentages such as `12.5` work. `0` turns the bulb off; a positive value sets brightness and turns it on, preserving its current white/color setting. The bulb must remain powered at the wall.

Help:

```sh
./build/lifx-control --help
```

Turn off the bulb while keeping its stored brightness:

```sh
./build/lifx-control 192.168.1.50 poweroff
```

Use a positive brightness value to turn it back on at the desired level.

Read the current brightness and power state without changing the bulb:

```sh
./build/lifx-control 192.168.1.50 get
# Brightness: 50.00%
# Power: on
```

Brightness is the bulb's stored dimming level, displayed to two decimal places. An off bulb can still report a nonzero brightness; check `Power` to see whether it is emitting light. The query uses [GetColor / LightState](https://lan.developer.lifx.com/docs/information-messages#lightstate---packet-107).

Run `make test` with Python 3 to check the CLI against a local simulated bulb, including music-mode restoration. Use `make WITH_MICROPHONE=1 test` to include the microphone noise-gate self-test.

## Microphone music mode

Build with `WITH_MICROPHONE=1` on macOS or Linux. On macOS, install Apple’s Command Line Tools. On Linux, install the ALSA development package (`libasound2-dev` on Debian/Ubuntu or `alsa-lib-devel` on Fedora) and configure the ALSA `default` capture device. The helper reads from that device.

```sh
make WITH_MICROPHONE=1
./build/lifx-control 192.168.1.50 music
```

On macOS, allow microphone access when prompted. Choose **MacBook Microphone** in System Settings > Sound > Input; the helper uses the default input device. If permission is denied, enable access for your terminal/launching app or LIFX Music in System Settings > Privacy & Security > Microphone, then restart the command.

Keep music paused during the first two seconds while the helper calibrates room noise. Start playback when it prints **Ready**. Restart music mode to recalibrate if the room noise changes substantially.

Music mode follows microphone volume rather than detecting musical beats or directly capturing system audio. Play music through speakers so the microphone can hear it. A noise gate ignores sound below the calibrated noise floor plus 18 dB (with a minimum threshold of -42 dBFS). Sound must stay above the threshold for four updates (about 0.4 seconds) to activate; hysteresis and smoothing prevent flickering. Silence settles at a steady 2% brightness. Active sound maps to 2–100% over a 20 dB range with a squared response curve, keeping softer passages dim and making louder passages much brighter, with at most about ten updates per second. Brightness rises by at most about 6 percentage points per update and falls by at most about 4, using 150 ms bulb fades; changes smaller than 0.5% are skipped. Loud speech and other sustained sounds can still trigger the light. Audio stays in memory; it is never saved or sent to the bulb. Only brightness commands are sent. The current white/color setting is preserved.

Run `./build/lifx-microphone --self-test` to check the noise gate with synthetic levels, without accessing the microphone.

Press **Ctrl+C** to stop. The helper is stopped and the bulb's initial brightness and power state are restored. Restoration is also attempted after an audio/network error; an unreachable bulb may prevent it. Keep `lifx-microphone` beside `lifx-control` when moving the executables.

## Music from stdin

In either build, `music --levels-stdin` reads a stream of two-byte little-endian brightness values (0–65535) from stdin, without accessing the microphone. It uses the newest complete sample in each read and restores the bulb when stdin closes. Feed samples at about 10 Hz.

The program queries the bulb to obtain its device ID and current color, then requests acknowledgements for brightness and power changes. Each request is retried up to three times with about a one-second wait per attempt. An acknowledgement confirms receipt, rather than independently verifying the final physical brightness. If a later request fails, an earlier change may already have applied.

Exit codes: `0` success/help, `2` invalid CLI arguments, `1` network/protocol failure (including invalid IP). If requests time out, check the IP address, Wi-Fi client isolation/guest network settings, firewall access to UDP 56700, and whether the bulb is powered. Your computer needs network access to the bulb.
