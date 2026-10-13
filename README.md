# LIFX Mini W control

A Zig CLI for a LIFX Mini W bulb on your local Wi-Fi network. No cloud account or API token is needed. Uses the [LIFX LAN protocol](https://lan.developer.lifx.com/docs/communicating-with-device) over UDP port 56700.

Requires Zig 0.17.0 and macOS or Linux (libc sockets).

On macOS, building also requires Apple's Command Line Tools (`xcode-select --install`) to compile the Swift microphone helper.

```sh
zig build -Doptimize=ReleaseSafe
./zig-out/bin/lifx-control 192.168.1.50 50
```

Replace the example IP with your bulb's IPv4 address and `50` with a brightness percentage from **0 to 100**. Decimal percentages such as `12.5` work. `0` turns the bulb off; a positive value sets brightness and turns it on, preserving its current white/color setting. The bulb must remain powered at the wall.

Help:

```sh
./zig-out/bin/lifx-control --help
```

Turn off the bulb while keeping its stored brightness:

```sh
./zig-out/bin/lifx-control 192.168.1.50 poweroff
```

Use a positive brightness value to turn it back on at the desired level.

Read the current brightness and power state without changing the bulb:

```sh
./zig-out/bin/lifx-control 192.168.1.50 get
# Brightness: 50.00%
# Power: on
```

Brightness is the bulb's stored dimming level, displayed to two decimal places. An off bulb can still report a nonzero brightness; check `Power` to see whether it is emitting light. The query uses [GetColor / LightState](https://lan.developer.lifx.com/docs/information-messages#lightstate---packet-107).

After building, run `python3 test_cli.py` to check argument validation and brightness/off commands against a local simulated bulb.

## Music mode (macOS)

```sh
./zig-out/bin/lifx-control 192.168.1.50 music
```

Allow microphone access when macOS asks. Choose **MacBook Microphone** in System Settings > Sound > Input; the helper uses the default input device. If permission is denied, enable access for your terminal/launching app or LIFX Music in System Settings > Privacy & Security > Microphone, then restart the command.

Keep music paused during the first two seconds while the helper calibrates room noise. Start playback when it prints **Ready**. Restart music mode to recalibrate if the room noise changes substantially.

Music mode follows microphone volume rather than detecting musical beats or directly capturing system audio. Play music through speakers so the microphone can hear it. A noise gate ignores sound below the calibrated noise floor plus 18 dB (with a minimum threshold of -42 dBFS). Sound must stay above the threshold for four updates (about 0.4 seconds) to activate; hysteresis and smoothing prevent flickering. Silence settles at a steady 2% brightness. Active sound maps to 2–100% over a 20 dB range with a squared response curve, keeping softer passages dim and making louder passages much brighter, with at most about ten updates per second. Brightness rises by at most about 6 percentage points per update and falls by at most about 4, using 150 ms bulb fades; changes smaller than 0.5% are skipped. Loud speech and other sustained sounds can still trigger the light. Audio stays in memory; it is never saved or sent to the bulb. Only brightness commands are sent. The current white/color setting is preserved.

Run `./zig-out/bin/lifx-microphone --self-test` to check the noise gate with synthetic levels, without accessing the microphone.

Press **Ctrl+C** to stop. The helper is stopped and the bulb's initial brightness and power state are restored. Restoration is also attempted after an audio/network error; an unreachable bulb may prevent it. Keep `lifx-microphone` beside `lifx-control` when moving the executables. The Swift helper uses Apple's [AVAudioEngine input node](https://developer.apple.com/documentation/AVFAudio/AVAudioEngine/inputNode).

For testing or external audio adapters, `music --levels-stdin` reads a stream of two-byte little-endian brightness values (0–65535) from stdin, without accessing the microphone. It uses the newest complete sample in each read and restores the bulb when stdin closes. Feed samples at about 10 Hz.

The program queries the bulb to obtain its device ID and current color, then requests acknowledgements for brightness and power changes. Each request is retried up to three times with about a one-second wait per attempt. An acknowledgement confirms receipt, rather than independently verifying the final physical brightness. If a later request fails, an earlier change may already have applied.

Exit codes: `0` success/help, `2` invalid CLI arguments, `1` network/protocol failure (including invalid IP). If requests time out, check the IP address, Wi-Fi client isolation/guest network settings, firewall access to UDP 56700, and whether the bulb is powered. Your computer needs network access to the bulb.
