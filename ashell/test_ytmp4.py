"""Tests for ytmp4.py with a fake yt-dlp (real YouTube is unreachable from CI). Run: python3 -m unittest ashell/test_ytmp4.py"""
import json
import os
import shutil
import sys
import tempfile
import time
import types
import unittest

sys.path.insert(0, os.path.dirname(__file__))
import ytmp4  # noqa: E402

FIXTURE = os.path.join(os.path.dirname(__file__), "..", "Core", "Tests", "CoreTests", "Fixtures", "v264_moof.mp4")


def fmt(fid, vcodec="none", acodec="none", w=None, h=None, fps=None, tbr=0, ext="mp4", dr="SDR", proto="https", lang=None, abr=None):
    return {"format_id": fid, "vcodec": vcodec, "acodec": acodec, "width": w, "height": h, "fps": fps, "tbr": tbr,
            "ext": ext, "dynamic_range": dr if vcodec != "none" else None, "protocol": proto,
            "language_preference": lang, "abr": abr}


FORMATS = [
    fmt("140", acodec="mp4a.40.2", ext="m4a", abr=129, lang=10),
    fmt("140-drc", acodec="mp4a.40.2", ext="m4a", abr=129, lang=10),
    fmt("139", acodec="mp4a.40.5", ext="m4a", abr=48, lang=10),
    fmt("140-dub", acodec="mp4a.40.2", ext="m4a", abr=200, lang=-1),
    fmt("251", acodec="opus", ext="webm", abr=160),
    fmt("701", vcodec="av01.0.13M.10", w=3840, h=2160, fps=60, tbr=40000, dr="HDR10"),
    fmt("401", vcodec="av01.0.12M.08", w=3840, h=2160, fps=60, tbr=25000),
    fmt("313", vcodec="vp9", w=3840, h=2160, fps=60, tbr=30000, ext="webm"),
    fmt("400", vcodec="av01.0.08M.08", w=2560, h=1440, fps=60, tbr=12000),
    fmt("299", vcodec="avc1.64002a", w=1920, h=1080, fps=60, tbr=6000),
    fmt("399", vcodec="av01.0.08M.08", w=1920, h=1080, fps=60, tbr=4000),
    fmt("136", vcodec="avc1.4d401f", w=1280, h=720, fps=30, tbr=2000),
    fmt("96", vcodec="avc1.640028", acodec="mp4a.40.2", w=1920, h=1080, proto="m3u8_native"),
]


class ChooseTests(unittest.TestCase):
    def test_best_is_4k_av1_converted(self):
        v, a, convert = ytmp4.choose(FORMATS, "best")
        self.assertEqual((v["format_id"], a["format_id"], convert), ("401", "140", True))  # SDR, not HDR/VP9; original audio, not DRC/dub

    def test_1080_and_720_are_h264(self):
        self.assertEqual(ytmp4.choose(FORMATS, "1080")[0]["format_id"], "299")
        self.assertEqual(ytmp4.choose(FORMATS, "1080")[2], False)
        self.assertEqual(ytmp4.choose(FORMATS, "720")[0]["format_id"], "136")

    def test_best_without_4k_uses_h264_1080(self):
        no4k = [f for f in FORMATS if f["format_id"] not in ("401", "701", "313")]
        self.assertEqual(ytmp4.choose(no4k, "best")[:1][0]["format_id"], "299")

    def test_vertical_shorts(self):
        fs = [FORMATS[0], fmt("137", vcodec="avc1.640028", w=1080, h=1920, fps=30, tbr=3000),
              fmt("402", vcodec="av01.0.12M.08", w=2160, h=3840, fps=30, tbr=9000)]
        v, _, convert = ytmp4.choose(fs, "best")
        self.assertEqual((v["format_id"], convert), ("137", False))   # vertical 4K isn't Encode-Media safe

    def test_no_audio(self):
        self.assertEqual(ytmp4.choose([FORMATS[6]], "best"), (None, None, False))


class IDTests(unittest.TestCase):
    def test_links(self):
        for s in ["https://youtu.be/dQw4w9WgXcQ?si=x", "https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=3",
                  "https://m.youtube.com/watch?feature=share&v=dQw4w9WgXcQ", "https://youtube.com/shorts/dQw4w9WgXcQ",
                  "Look https://www.youtube.com/live/dQw4w9WgXcQ?feature=shared"]:
            self.assertEqual(ytmp4.video_id(s), "dQw4w9WgXcQ", s)
        self.assertIsNone(ytmp4.video_id("https://example.com/watch?v=dQw4w9WgXcQ"))


class DownloadFlowTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.calls = []
        self.ydl_opts = []
        os.environ["SHORTCUTS"] = self.tmp
        ytmp4.STATE = os.path.join(self.tmp, "state")
        os.makedirs(ytmp4.STATE)
        with open(os.path.join(ytmp4.STATE, "last-update"), "w") as fh:
            fh.write("x")                                             # fresh: no pip update
        real_run = ytmp4.run

        def fake_run(cmd):
            self.calls.append(cmd)
            if cmd[0] == "ffmpeg" and shutil.which("ffmpeg"):
                return real_run(cmd)
            return types.SimpleNamespace(returncode=1 if cmd[0] == "ffmpeg" else 0, stdout="", stderr="")
        ytmp4.run = fake_run
        self.addCleanup(setattr, ytmp4, "run", real_run)

        test = self

        class FakeYDL:
            def __init__(self, opts):
                self.opts = opts
                test.ydl_opts.append(opts)

            def __enter__(self):
                return self

            def __exit__(self, *a):
                return False

            def extract_info(self, url, download=False):
                test.assertEqual(url, "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
                return {"title": 'My "Video": part 1/2', "formats": FORMATS, "is_live": False}

            def download(self, urls):
                out = self.opts["outtmpl"].replace("%(ext)s", "mp4")
                shutil.copyfile(FIXTURE, out)

        sys.modules["yt_dlp"] = types.SimpleNamespace(YoutubeDL=FakeYDL)
        self.addCleanup(sys.modules.pop, "yt_dlp", None)

    def test_best_flow(self):
        self.assertEqual(ytmp4.main(["https://youtu.be/dQw4w9WgXcQ", "Best (up to 4K)"]), 0)
        out = os.path.join(self.tmp, "ytmp4")
        self.assertEqual(sorted(os.listdir(out)), ["info.json", "latest.mp4"])
        with open(os.path.join(out, "info.json")) as fh:
            self.assertEqual(json.load(fh), {"title": "My  Video  part 1 2", "convert": "yes"})
        self.assertEqual(self.ydl_opts[1]["format"], "401+140")
        self.assertEqual(self.ydl_opts[1]["merge_output_format"], "mp4")
        self.assertNotIn("cookiefile", self.ydl_opts[0])
        self.assertIn(["open", "shortcuts://run-shortcut?name=YT%20to%20MP4&input=text&text=ytmp4-save"], self.calls)
        if shutil.which("ffmpeg"):
            with open(os.path.join(out, "latest.mp4"), "rb") as fh:
                head = fh.read(64)
            self.assertIn(b"moov", head[:64] + open(os.path.join(out, "latest.mp4"), "rb").read(4096))  # faststart

    def test_1080_with_cookies(self):
        with open(os.path.join(ytmp4.STATE, "cookies.txt"), "w") as fh:
            fh.write("# Netscape HTTP Cookie File\n")
        self.assertEqual(ytmp4.main(["https://youtu.be/dQw4w9WgXcQ", "1080p"]), 0)
        self.assertEqual(self.ydl_opts[1]["format"], "299+140")
        self.assertTrue(self.ydl_opts[0]["cookiefile"].endswith("cookies.txt"))
        with open(os.path.join(self.tmp, "ytmp4", "info.json")) as fh:
            self.assertEqual(json.load(fh)["convert"], "no")

    def test_bad_link(self):
        self.assertEqual(ytmp4.main(["https://example.com/x", "best"]), 1)
        self.assertEqual(self.ydl_opts, [])

    def test_weekly_update_runs_when_stale(self):
        stamp = os.path.join(ytmp4.STATE, "last-update")
        old = time.time() - 8 * 24 * 3600
        os.utime(stamp, (old, old))
        ytmp4.self_update = lambda: None
        ytmp4.main(["https://youtu.be/dQw4w9WgXcQ", "720"])
        self.assertTrue(any("pip" in c for c in self.calls))
        self.assertGreater(os.path.getmtime(stamp), old)

    def test_friendly_errors(self):
        self.assertIn("not a bot", ytmp4.friendly(Exception("ERROR: Sign in to confirm you're not a bot")))
        self.assertIn("cookies.txt", ytmp4.friendly(Exception("Sign in to confirm your age")))


if __name__ == "__main__":
    unittest.main()
