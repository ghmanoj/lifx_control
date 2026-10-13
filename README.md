# LIFX Mini W control

A Zig CLI for a LIFX Mini W bulb on your local Wi-Fi network. No cloud account or API token is needed. Uses the [LIFX LAN protocol](https://lan.developer.lifx.com/docs/communicating-with-device) over UDP port 56700.

Requires Zig 0.17.0 and macOS or Linux (libc sockets).

```sh
zig build -Doptimize=ReleaseSafe
./zig-out/bin/lifx-control 192.168.1.50 50
```

Replace the example IP with your bulb's IPv4 address and `50` with a brightness percentage from **0 to 100**. Decimal percentages such as `12.5` work. `0` turns the bulb off; a positive value sets brightness and turns it on, preserving its current white/color setting. The bulb must remain powered at the wall.

Help:

```sh
./zig-out/bin/lifx-control --help
```

Read the current brightness and power state without changing the bulb:

```sh
./zig-out/bin/lifx-control 192.168.1.50 get
# Brightness: 50.00%
# Power: on
```

Brightness is the bulb's stored dimming level, displayed to two decimal places. An off bulb can still report a nonzero brightness; check `Power` to see whether it is emitting light. The query uses [GetColor / LightState](https://lan.developer.lifx.com/docs/information-messages#lightstate---packet-107).

After building, run `python3 test_cli.py` to check argument validation and brightness/off commands against a local simulated bulb.

The program queries the bulb to obtain its device ID and current color, then requests acknowledgements for brightness and power changes. Each request is retried up to three times with about a one-second wait per attempt. An acknowledgement confirms receipt, rather than independently verifying the final physical brightness. If a later request fails, an earlier change may already have applied.

Exit codes: `0` success/help, `2` invalid CLI arguments, `1` network/protocol failure (including invalid IP). If requests time out, check the IP address, Wi-Fi client isolation/guest network settings, firewall access to UDP 56700, and whether the bulb is powered. Your computer needs network access to the bulb.
