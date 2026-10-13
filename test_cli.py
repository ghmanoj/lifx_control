"""Integration checks against a loopback LIFX emulator; no real bulb needed."""
import socket
import struct
import subprocess
import threading
import unittest
import signal

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
                    expected = [101] if percent == "get" else ([101, 117] if percent in (0, "poweroff") else [101, 102, 117])
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
                                self.assertEqual(struct.unpack_from("<H", packet, 36)[0], 0 if percent in (0, "poweroff") else 65535)
                        struct.pack_into("<H", response, 0, len(response))
                        server.sendto(response, peer)
                    if percent in ("get", "poweroff"):
                        server.settimeout(0.1)
                        with self.assertRaises(socket.timeout):
                            server.recvfrom(512)  # No extra packets after the expected commands.
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
            if percent == "poweroff":
                self.assertIn(b"acknowledged power off", result.stderr)

    def test_brightness(self):
        self.emulate(12.5)

    def test_off(self):
        self.emulate(0)

    def test_poweroff(self):
        self.emulate("poweroff")

    def test_get_brightness(self):
        self.emulate("get")

    def test_get_when_off(self):
        self.emulate("get", power=0)

    def music(self, interrupt=False, initial_power=0, jitter=False):
        failures = []
        target = bytes.fromhex("d073d50013370000")
        original = struct.pack("<HHHH", 100, 0, 12345, 2700)
        applied = threading.Event()
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as server:
            server.bind(("127.0.0.1", 56700))
            server.settimeout(5)

            def serve():
                try:
                    for kind, sequence in ((101, 1), (102, 2), (117, 3), (102, 254), (117, 255)):
                        packet, peer = server.recvfrom(512)
                        self.assertEqual(struct.unpack_from("<H", packet, 32)[0], kind)
                        self.assertEqual(packet[23], sequence)
                        response = bytearray(packet[:36])
                        response[8:16] = target
                        response[22] = 0
                        if kind == 101:
                            struct.pack_into("<H", response, 32, 107)
                            response += original + bytes(2) + struct.pack("<H", initial_power) + bytes(40)
                        else:
                            struct.pack_into("<H", response, 32, 45)
                            if kind == 102:
                                expected = original if sequence == 254 else struct.pack("<HHHH", 100, 0, 50000, 2700)
                                self.assertEqual(packet[37:45], expected)
                                self.assertEqual(struct.unpack_from("<I", packet, 45)[0], 150)
                            else:
                                self.assertEqual(struct.unpack_from("<H", packet, 36)[0], initial_power if sequence == 255 else 65535)
                        struct.pack_into("<H", response, 0, len(response))
                        server.sendto(response, peer)
                        if sequence == 3:
                            applied.set()
                except Exception as error:
                    failures.append(error)

            worker = threading.Thread(target=serve)
            worker.start()
            process = subprocess.Popen([BIN, "127.0.0.1", "music", "--levels-stdin"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                if interrupt or jitter:
                    process.stdin.write(struct.pack("<H", 50000))
                    process.stdin.flush()
                    self.assertTrue(applied.wait(5))
                    if interrupt:
                        process.send_signal(signal.SIGINT)
                        _, stderr = process.communicate(timeout=12)
                    else:
                        _, stderr = process.communicate(struct.pack("<H", 50010), timeout=12)
                else:
                    # A backlog should apply the latest level, not every old sample.
                    _, stderr = process.communicate(struct.pack("<HHH", 10000, 30000, 50000), timeout=12)
                self.assertEqual(process.returncode, 0, stderr)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.communicate()
                worker.join()
            if failures:
                raise failures[0]

    def test_music_restores_off_bulb(self):
        self.music()

    def test_music_ctrl_c_restores_on_bulb(self):
        self.music(interrupt=True, initial_power=65535)

    def test_music_ignores_small_brightness_jitter(self):
        self.music(jitter=True)


if __name__ == "__main__":
    unittest.main()
