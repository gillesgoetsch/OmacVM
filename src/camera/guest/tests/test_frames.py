#!/usr/bin/env python3
"""omacvm-camera's frames and their times (no VM, no camera needed).

    python3 src/camera/guest/tests/test_frames.py

A new reader gets v4l2loopback's last frame first. Its time must sit right
before the next frame, or ffmpeg fills the gap with copies of it (all black).
"""
import ctypes
import errno
import importlib.machinery
import importlib.util
import os
import pathlib
import tempfile
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[4]


def load(name, path):
    loader = importlib.machinery.SourceFileLoader(name, str(ROOT / path))
    spec = importlib.util.spec_from_loader(name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


camera = load("omacvm_camera", "src/camera/guest/omacvm-camera")


class FrameTimes(unittest.TestCase):
    def test_runs_with_the_monotonic_clock(self):
        clock = camera.FrameClock()
        self.assertEqual(clock.time(100.0), 100.0)
        self.assertEqual(clock.time(101.5), 101.5)

    def test_stopped_while_nobody_reads(self):
        clock = camera.FrameClock()
        clock.stop(100.0)
        self.assertEqual(clock.time(100.0), 100.0)
        self.assertEqual(clock.time(3700.0), 100.0)   # an hour later

    def test_next_frame_comes_right_after_the_old_one(self):
        clock = camera.FrameClock()
        clock.stop(100.0)            # last frame of the last use: 100.0
        clock.go(3700.0)             # an app reads an hour later
        self.assertAlmostEqual(clock.time(3700.0), 100.0 + camera.FRAME_TIME)
        self.assertAlmostEqual(clock.time(3701.0), 101.0 + camera.FRAME_TIME)   # runs at real speed

    def test_many_uses_never_go_back(self):
        clock = camera.FrameClock()
        last, now = clock.time(10.0), 10.0
        for gap in (0.01, 5.0, 600.0, 0.001):
            now += 2.0
            self.assertGreater(clock.time(now), last)
            last = clock.time(now)
            clock.stop(now)
            now += gap
            clock.go(now)
            self.assertGreater(clock.time(now), last)
            self.assertLess(clock.time(now) - last, 0.05)
            last = clock.time(now)

    def test_never_ahead_of_the_monotonic_clock(self):
        clock = camera.FrameClock()
        now = 50.0
        for _ in range(100):   # apps that stop and start within a frame
            clock.stop(now)
            now += 0.001
            clock.go(now)
            self.assertLessEqual(clock.time(now), now)
            now += 0.001
        last = clock.time(now)
        clock.stop(now)
        clock.go(now + 0.001)   # a frame after a short stop is still later
        self.assertGreater(clock.time(now + 0.001), last)

    def test_stop_and_go_twice_change_nothing(self):
        clock = camera.FrameClock()
        clock.stop(100.0)
        clock.stop(200.0)
        self.assertEqual(clock.time(300.0), 100.0)
        clock.go(300.0)
        before = clock.time(301.0)
        clock.go(301.0)
        self.assertEqual(clock.time(301.0), before)

    def test_timeval(self):
        t = camera.timeval(12.25)
        self.assertEqual((t.seconds, t.microseconds), (12, 250000))
        t = camera.timeval(1.9999999)
        self.assertEqual((t.seconds, t.microseconds), (2, 0))
        t = camera.timeval(0.0)   # 0.0 would be "the kernel's time"
        self.assertEqual((t.seconds, t.microseconds), (0, 1))


class SavedOffset(unittest.TestCase):
    """The clock's offset outlives a restart of the service (same boot)."""

    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        state = pathlib.Path(self.dir.name) / "omacvm-camera-clock"
        self.patches = [mock.patch.object(camera, "CLOCK_STATE", state),
                        mock.patch.object(camera, "boot_id", return_value="boot-1")]
        for p in self.patches:
            p.start()
        self.state = state

    def tearDown(self):
        for p in self.patches:
            p.stop()
        self.dir.cleanup()

    def test_round_trip(self):
        camera.save_offset(3599.25)
        self.assertEqual(camera.load_offset(5000.0), 3599.25)

    def test_nothing_saved(self):
        self.assertEqual(camera.load_offset(5000.0), 0.0)

    def test_other_boot(self):
        camera.save_offset(3599.25)
        with mock.patch.object(camera, "boot_id", return_value="boot-2"):
            self.assertEqual(camera.load_offset(5000.0), 0.0)

    def test_offset_bigger_than_the_clock(self):
        camera.save_offset(3599.25)
        self.assertEqual(camera.load_offset(100.0), 0.0)   # the frame time would be negative

    def test_garbage(self):
        self.state.write_text("boot-1 nan-ish\n")
        self.assertEqual(camera.load_offset(5000.0), 0.0)
        self.state.write_text("")
        self.assertEqual(camera.load_offset(5000.0), 0.0)

    def test_restart_while_an_app_reads_does_not_jump(self):
        clock = camera.FrameClock()
        clock.stop(100.0)
        clock.go(3700.0)                     # an app reads after an hour
        camera.save_offset(clock.offset)
        before = clock.time(3710.0)          # last frame of the old service
        restarted = camera.FrameClock(camera.load_offset(3712.0))
        self.assertAlmostEqual(restarted.time(3712.0) - before, 2.0, places=3)   # the restart's 2 s, not an hour


def message(kind, payload, sequence=0):
    return camera.HEADER.pack(camera.MAGIC, camera.VERSION, kind, 0, len(payload), sequence) + payload


class Parser(unittest.TestCase):
    """A restart while an app reads leaves the rest of a frame in the port."""

    def setUp(self):
        self.patch = mock.patch.object(camera, "log")
        self.log = self.patch.start()

    def tearDown(self):
        self.patch.stop()

    def test_rest_of_a_frame_is_skipped(self):
        frame = message(camera.KIND_FRAME, bytes([77]) * camera.FRAME_BYTES, 5)
        status = message(camera.KIND_STATUS, b'{"status":"idle"}')
        parser = camera.Parser()
        got = parser.feed(frame[700_000:] + status + frame)
        self.assertEqual([k for k, _ in got], [camera.KIND_STATUS, camera.KIND_FRAME])
        self.assertEqual(got[1][1][:1], bytes([77]))
        self.assertEqual(parser.skipped, len(frame) - 700_000)
        self.assertEqual(self.log.call_count, 1)

    def test_rest_split_over_reads(self):
        frame = message(camera.KIND_FRAME, bytes([90]) * camera.FRAME_BYTES)
        data = frame[123_457:] + frame
        parser = camera.Parser()
        got = []
        for at in range(0, len(data), 65_536):
            got += parser.feed(data[at:at + 65_536])
        self.assertEqual(len(got), 1)
        self.assertEqual(len(got[0][1]), camera.FRAME_BYTES)

    def test_after_the_first_message_a_bad_one_is_an_error(self):
        parser = camera.Parser()
        parser.feed(message(camera.KIND_STATUS, b"{}"))
        with self.assertRaises(ValueError):
            parser.feed(b"XXXX" + bytes(12))

    def test_a_partial_header_is_kept(self):
        status = message(camera.KIND_STATUS, b"{}")
        parser = camera.Parser()
        self.assertEqual(parser.feed(bytes(20) + status[:2]), [])
        self.assertEqual(parser.feed(status[2:]), [(camera.KIND_STATUS, b"{}")])


class Ioctls(unittest.TestCase):
    """The numbers are the kernel's (64-bit: the guest is aarch64)."""

    def test_numbers(self):
        if ctypes.sizeof(ctypes.c_long) != 8:
            self.skipTest("not a 64-bit Python")
        self.assertEqual(ctypes.sizeof(camera.V4L2Buffer), 88)
        self.assertEqual(ctypes.sizeof(camera.V4L2RequestBuffers), 20)
        self.assertEqual(camera.VIDIOC_REQBUFS, 0xC0145608)
        self.assertEqual(camera.VIDIOC_QUERYBUF, 0xC0585609)
        self.assertEqual(camera.VIDIOC_QBUF, 0xC058560F)
        self.assertEqual(camera.VIDIOC_DQBUF_BUFFER, 0xC0585611)
        self.assertEqual(camera.VIDIOC_STREAMON, 0x40045612)
        self.assertEqual(camera.V4L2Buffer.timestamp.offset, 24)
        self.assertEqual(camera.V4L2Buffer.m.offset, 64)


class Fallback(unittest.TestCase):
    def test_without_buffers_frames_are_written(self):
        with tempfile.TemporaryFile() as f:
            frames = camera.Frames(f.fileno(), buffers=False)
            frames.put(camera.BLACK)
            self.assertEqual(os.fstat(f.fileno()).st_size, camera.FRAME_BYTES)

    def test_no_v4l2_device_means_no_buffers(self):
        with tempfile.TemporaryFile() as f:
            with self.assertRaises(camera.NoBuffers):
                camera.Frames(f.fileno(), buffers=True)

    def test_setup_tries_again_with_write(self):
        fds = [os.open(os.devnull, os.O_RDONLY), os.open(os.devnull, os.O_RDONLY)]
        calls = []

        def configure(fd, buffers=True):
            calls.append((fd, buffers))
            if buffers:
                raise camera.NoBuffers("no QBUF")
            return "frames"

        with mock.patch.object(camera, "open_camera", side_effect=list(fds)), \
                mock.patch.object(camera, "configure_camera", side_effect=configure), \
                mock.patch.object(camera, "log"):
            fd, frames = camera.setup_camera()
        try:
            self.assertEqual((fd, frames), (fds[1], "frames"))
            self.assertEqual(calls, [(fds[0], True), (fds[1], False)])
            with self.assertRaises(OSError):
                os.fstat(fds[0])   # the first descriptor was closed
        finally:
            os.close(fds[1])

    def test_gone_device_is_not_a_fallback(self):
        def configure(fd, buffers=True):
            raise OSError(errno.ENODEV, "gone")

        fd = os.open(os.devnull, os.O_RDONLY)
        with mock.patch.object(camera, "open_camera", return_value=fd), \
                mock.patch.object(camera, "configure_camera", side_effect=configure):
            with self.assertRaises(OSError) as caught:
                camera.setup_camera()
        self.assertEqual(caught.exception.errno, errno.ENODEV)
        with self.assertRaises(OSError):
            os.fstat(fd)   # closed on the way out


if __name__ == "__main__":
    unittest.main()
