#!/usr/bin/env python3
"""YT to MP4 for a-Shell (free, App Store only).

  python3 ~/Documents/bin/ytmp4.py --setup             install / update everything, self-check
  python3 ~/Documents/bin/ytmp4.py "<link>" best|1080|720

Downloads with yt-dlp on the phone, merges to a faststart MP4 (H.264 + AAC where YouTube has it),
writes ytmp4/latest.mp4 + ytmp4/info.json next to the Shortcuts folder, then opens the
"YT Save" shortcut, which converts 4K AV1 to H.264 with Apple's Encode Media and saves it.
"""
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.parse
import urllib.request

REPO_RAW = "https://raw.githubusercontent.com/Amoguslittleahhh/Youtube-to-MP4-Converter-/main/ashell/ytmp4.py"
SAVE_SHORTCUT = "YT Save"
UPDATE_EVERY = 7 * 24 * 3600
HOME_DOCS = os.path.expanduser("~/Documents")
BIN = os.path.join(HOME_DOCS, "bin")
STATE = os.path.join(HOME_DOCS, "ytmp4")              # cookies.txt, update stamp
ID_RE = re.compile(r"(?:youtu\.be/|youtube(?:-nocookie)?\.com/(?:watch\?(?:.*&)?v=|shorts/|live/|embed/|v/))([A-Za-z0-9_-]{11})")


def out_dir():
    """Folder that a-Shell's Shortcuts actions (Get File) read from."""
    base = os.environ.get("SHORTCUTS") or os.getcwd()
    path = os.path.join(base, "ytmp4")
    os.makedirs(path, exist_ok=True)
    return path


def video_id(text):
    m = ID_RE.search(text or "")
    return m.group(1) if m else None


def run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True)


# ---------- format choice (same rules as the Swift app) ----------

def res(f):
    w, h = f.get("width") or 0, f.get("height") or 0
    return min(w, h) if w and h else (h or w)


def choose(formats, quality):
    """Returns (video_format, audio_format, convert_to_h264)."""
    audio = [f for f in formats
             if f.get("vcodec") == "none" and str(f.get("acodec", "")).startswith("mp4a")
             and f.get("ext") == "m4a" and "drc" not in str(f.get("format_id", ""))]
    audio.sort(key=lambda f: (f.get("language_preference") or 0, f.get("abr") or f.get("tbr") or 0))
    videos = [f for f in formats
              if f.get("acodec") == "none" and f.get("ext") == "mp4" and res(f) > 0
              and (f.get("dynamic_range") in (None, "SDR"))
              and str(f.get("protocol", "https")).startswith("http")]
    avc = [f for f in videos if str(f.get("vcodec", "")).startswith("avc1")]
    # Only true 16:9 landscape 4K is converted (Encode Media's 3840x2160 preset); other shapes use H.264.
    av1 = [f for f in videos if str(f.get("vcodec", "")).startswith("av01")
           and f.get("width") == 3840 and f.get("height") == 2160]
    key = lambda f: (res(f), f.get("fps") or 0, f.get("tbr") or 0)
    if not audio:
        return None, None, False
    if quality == "best" and av1:
        return max(av1, key=key), audio[-1], True          # only 4K exists as AV1 alone → convert
    limit = 1080 if quality == "best" else int(quality)
    pool = [f for f in avc if res(f) <= limit] or [f for f in videos if res(f) <= limit] or videos
    if not pool:
        return None, None, False
    v = max(pool, key=key)
    return v, audio[-1], not str(v.get("vcodec", "")).startswith("avc1")


# ---------- setup / update ----------

def pip_update():
    print("Updating yt-dlp…")
    r = run([sys.executable, "-m", "pip", "install", "-U", "--user", "yt-dlp[default]"])
    if r.returncode != 0:
        r = run([sys.executable, "-m", "pip", "install", "-U", "yt-dlp[default]"])
    print("  ok" if r.returncode == 0 else "  pip failed:\n" + r.stdout[-800:] + r.stderr[-800:])
    return r.returncode == 0


def self_update():
    try:
        with urllib.request.urlopen(REPO_RAW, timeout=15) as resp:
            code = resp.read()
        if b"def choose(" in code:          # sanity check before replacing ourselves
            os.makedirs(BIN, exist_ok=True)
            with open(os.path.join(BIN, "ytmp4.py"), "wb") as fh:
                fh.write(code)
    except Exception as e:
        print(f"  (couldn't refresh the script: {e})")


def weekly_update():
    os.makedirs(STATE, exist_ok=True)
    stamp = os.path.join(STATE, "last-update")
    try:
        last = os.path.getmtime(stamp)
    except OSError:
        last = 0
    if time.time() - last < UPDATE_EVERY:
        return
    if pip_update():
        self_update()
        with open(stamp, "w") as fh:
            fh.write(str(int(time.time())))


def setup():
    os.makedirs(BIN, exist_ok=True)
    os.makedirs(STATE, exist_ok=True)
    here = os.path.abspath(__file__)
    target = os.path.join(BIN, "ytmp4.py")
    if here != target:
        shutil.copyfile(here, target)
    ok = pip_update()
    with open(os.path.join(STATE, "last-update"), "w") as fh:
        fh.write(str(int(time.time())))
    print("\nSelf-check")
    v = run([sys.executable, "-m", "yt_dlp", "--version"])
    print("  yt-dlp:", v.stdout.strip() or "MISSING")
    f = run(["ffmpeg", "-hide_banner", "-version"])
    print("  ffmpeg:", (f.stdout.splitlines() or ["MISSING"])[0])
    print("  files go to:", out_dir())
    print("\nAll set! Now build the two shortcuts (see the README)." if ok and v.returncode == 0 and f.returncode == 0
          else "\nSomething is missing — copy this screen and send it to whoever set this up.")


# ---------- download ----------

FRIENDLY = [
    ("not a bot", "YouTube asked to confirm you're not a bot. Wait a few minutes, switch Wi-Fi/mobile data, and try again."),
    ("your age", "This video is age-restricted. Add your cookies.txt (see README) and try again."),
    ("age-restricted", "This video is age-restricted. Add your cookies.txt (see README) and try again."),
    ("member", "This is a members-only video. Add cookies.txt from an account that's a member (see README)."),
    ("private", "This video is private."),
    ("403", "YouTube refused the download (403). Run the setup line again to update, then retry."),
]


def friendly(err):
    s = str(err).lower()
    for needle, msg in FRIENDLY:
        if needle in s:
            return msg
    return str(err)


def finalize(src, dest):
    """Faststart remux (no re-encode) so WhatsApp & co preview instantly."""
    r = run(["ffmpeg", "-y", "-v", "error", "-i", src, "-c", "copy", "-movflags", "+faststart", dest])
    if r.returncode != 0:
        shutil.move(src, dest)
    elif os.path.exists(src):
        os.remove(src)


def download(link, quality):
    vid = video_id(link)
    if not vid:
        print("That isn't a YouTube video link.")
        return 1
    weekly_update()
    import yt_dlp

    out = out_dir()
    for name in ("latest.mp4", "info.json"):
        try:
            os.remove(os.path.join(out, name))
        except OSError:
            pass
    opts = {"noplaylist": True, "quiet": False}
    cookies = os.path.join(STATE, "cookies.txt")
    if os.path.exists(cookies):
        opts["cookiefile"] = cookies

    try:
        with yt_dlp.YoutubeDL(opts) as ydl:
            info = ydl.extract_info(f"https://www.youtube.com/watch?v={vid}", download=False)
    except Exception as e:
        print("\n" + friendly(e))
        return 1

    title = info.get("title") or "video"
    raw = os.path.join(out, "download.mp4")
    convert = False
    live = bool(info.get("is_live"))
    if live:
        print("Live stream: recording… tap Ctrl-C (on the a-Shell keyboard bar) to stop and save.")
        fmt = "best[protocol^=m3u8][vcodec^=avc1]/best[protocol^=m3u8]/best"
        dl_opts = dict(opts, format=fmt, outtmpl=os.path.join(out, "download.%(ext)s"), hls_use_mpegts=True)
    else:
        v, a, convert = choose(info.get("formats") or [], quality)
        if not v:
            print("YouTube didn't offer an MP4 version of this video.")
            return 1
        print(f"Downloading {res(v)}p{'' if (v.get('fps') or 30) <= 30 else v.get('fps')} "
              f"{'AV1 (will convert to H.264)' if convert else 'H.264'}")
        dl_opts = dict(opts, format=f"{v['format_id']}+{a['format_id']}", merge_output_format="mp4",
                       outtmpl=os.path.join(out, "download.%(ext)s"), http_chunk_size=10 << 20)

    try:
        with yt_dlp.YoutubeDL(dl_opts) as ydl:
            ydl.download([f"https://www.youtube.com/watch?v={vid}"])
    except KeyboardInterrupt:
        if not live:
            raise
    except Exception as e:
        if not live:
            print("\n" + friendly(e))
            return 1

    produced = [os.path.join(out, n) for n in os.listdir(out) if n.startswith("download.")]
    produced.sort(key=os.path.getsize, reverse=True)
    if not produced:
        print("Nothing was downloaded.")
        return 1
    finalize(produced[0], os.path.join(out, "latest.mp4"))
    for p in produced[1:]:
        try:
            os.remove(p)
        except OSError:
            pass

    safe = re.sub(r'[\\/:*?"<>|\n\r]+', " ", title).strip()[:80] or "video"
    with open(os.path.join(out, "info.json"), "w", encoding="utf-8") as fh:
        json.dump({"title": safe, "convert": "yes" if convert else "no"}, fh, ensure_ascii=False)
    print("\nDone — opening the YT Save shortcut…")
    run(["open", "shortcuts://run-shortcut?name=" + urllib.parse.quote(SAVE_SHORTCUT)])
    return 0


def main(argv):
    if argv[:1] == ["--setup"]:
        setup()
        return 0
    if not argv:
        print(__doc__)
        return 1
    rest = " ".join(argv[1:])     # menu label from Shortcuts, e.g. "1080p"
    quality = "1080" if "1080" in rest else "720" if "720" in rest else "best"
    return download(argv[0], quality)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
