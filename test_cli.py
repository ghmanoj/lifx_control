"""Integration checks against a loopback LIFX emulator; no real bulb needed."""
import socket
import struct
import subprocess
import threading
import unittest

BIN = "./zig-out/bin/lifx-control"


class CliTests(unittest.TestCase):
    def test_invalid_arguments(self):
        for brightness in ("-1", "101", "nan", "inf", "abc"):
            result = subprocess.run([BIN, "127.0.0.1", brightness], capture_output=True)
            self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(subprocess.run([BIN, "--help"], capture_output=True).returncode, 0)

    def emulate(self, percent, power=65535):
        failures = []
        target = bytes.fromhex("d073d50013370000")
        color = struct.pack("<HHHH", 100, 0, 12345, 2700)
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as server:
            server.bind(("127.0.0.1", 56700))
            server.settimeout(5)

            def serve():
                try:
                    expected = [101] if percent == "get" else ([101, 117] if percent == 0 else [101, 102, 117])
                    for kind in expected:
                        packet, peer = server.recvfrom(512)
                        self.assertEqual(struct.unpack_from("<H", packet)[0], len(packet))
                        self.assertEqual(struct.unpack_from("<H", packet, 32)[0], kind)
                        response = bytearray(packet[:36])
                        response[8:16] = target
                        response[22] = 0
                        if kind == 101:
                            self.assertEqual(packet[8:16], bytes(8))
                            struct.pack_into("<H", response, 32, 107)
                            response += color + bytes(2) + struct.pack("<H", power) + bytes(40)
                        else:
                            self.assertEqual(packet[8:16], target)
                            self.assertEqual(packet[22], 2)
                            struct.pack_into("<H", response, 32, 45)
                            if kind == 102:
                                self.assertEqual(packet[37:41], color[:4])
                                self.assertEqual(packet[43:45], color[6:8])
                                self.assertEqual(struct.unpack_from("<H", packet, 41)[0], int(percent * 65535 / 100 + 0.5))
                            else:
                                self.assertEqual(struct.unpack_from("<H", packet, 36)[0], 0 if percent == 0 else 65535)
                        struct.pack_into("<H", response, 0, len(response))
                        server.sendto(response, peer)
                    if percent == "get":
                        server.settimeout(0.1)
                        with self.assertRaises(socket.timeout):
                            server.recvfrom(512)  # Reading must not send mutation packets.
                except Exception as error:
                    failures.append(error)

            worker = threading.Thread(target=serve)
            worker.start()
            result = subprocess.run([BIN, "127.0.0.1", str(percent)], capture_output=True, timeout=12)
            worker.join()
            if failures:
                raise failures[0]
            self.assertEqual(result.returncode, 0, result.stderr)
            if percent == "get":
                self.assertEqual(result.stdout.decode(), f"Brightness: 18.84%\nPower: {'on' if power else 'off'}\n")

    def test_brightness(self):
        self.emulate(12.5)

    def test_off(self):
        self.emulate(0)

    def test_get_brightness(self):
        self.emulate("get")

    def test_get_when_off(self):
        self.emulate("get", power=0)


if __name__ == "__main__":
    unittest.main()
