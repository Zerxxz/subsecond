#!/usr/bin/env python3
"""Record the SUBSECOND motion-graphics page (headless). Xvfb -> Chrome -> ffmpeg x11grab.
Loads motion.html, starts ffmpeg, calls window.begin() to sync the timeline, records ~72s.
Output: /tmp/subsecond-motion-raw.mp4 (1600x900).
"""
import json, os, subprocess, sys, time, urllib.request

V, W, H = 99, 1600, 900
PORT = 8899
URL = f"http://localhost:{PORT}/motion.html"
PROFILE = "/tmp/ss-motion"
OUT = "/tmp/subsecond-motion-raw.mp4"
CDP_PORT = 9222
DUR = 72.0


def sh(c):
    return subprocess.run(c, shell=True, capture_output=True, text=True)


class Cdp:
    def __init__(self, port):
        import websocket
        url = None
        for _ in range(6):
            try:
                lst = json.load(urllib.request.urlopen(f"http://127.0.0.1:{port}/json/list", timeout=5))
                for t in lst:
                    if "motion.html" in (t.get("url") or "") or "localhost" in (t.get("url") or ""):
                        url = t["webSocketDebuggerUrl"]; break
                if not url and lst:
                    url = lst[0]["webSocketDebuggerUrl"]
            except Exception:
                pass
            if url:
                break
            time.sleep(2)
        if not url:
            raise RuntimeError("no CDP target")
        self.ws = websocket.create_connection(url, timeout=60)
        self.n = 0

    def _send(self, method, params=None):
        self.n += 1
        self.ws.send(json.dumps({"id": self.n, "method": method, "params": params or {}}))
        while True:
            m = json.loads(self.ws.recv())
            if m.get("id") == self.n:
                if "error" in m:
                    raise RuntimeError(m["error"].get("message", "?"))
                return m.get("result", {})

    def eval(self, expr):
        res = self._send("Runtime.evaluate", {"expression": expr, "returnByValue": True, "awaitPromise": True})
        if "exceptionDetails" in res:
            raise RuntimeError("JS: " + str(res["exceptionDetails"].get("text", "")))
        return res.get("result", {}).get("value")


def main():
    sh(f"rm -f /tmp/.X{V}-lock /tmp/.X11-unix/X{V}")
    sh(f"pkill -9 -f 'Xvfb :{V}'")
    sh(f"rm -rf {PROFILE}")
    subprocess.Popen(["Xvfb", f":{V}", "-screen", "0", f"{W}x{H}x24"],
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(2)
    subprocess.Popen([
        "google-chrome", f"--user-data-dir={PROFILE}", "--no-first-run", "--disable-infobars",
        "--disable-gpu", "--no-sandbox", "--hide-scrollbars",
        "--disable-background-timer-throttling", "--disable-renderer-backgrounding",
        "--disable-backgrounding-occluded-windows",
        f"--window-size={W},{H}", "--window-position=0,0",
        f"--remote-debugging-port={CDP_PORT}", "--remote-allow-origins=*", f"--app={URL}"
    ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env={**os.environ, "DISPLAY": f":{V}"})

    c = None
    for _ in range(25):
        time.sleep(2)
        try:
            c = Cdp(CDP_PORT); break
        except Exception:
            pass
    if not c:
        sys.exit("CDP never came up")

    # wait for the motion page + fonts
    for _ in range(30):
        try:
            if c.eval("document.querySelector('#s0') ? 1 : 0") and c.eval("document.fonts ? document.fonts.status : 'loaded'"):
                if c.eval("document.fonts.status") == "loaded":
                    break
        except Exception:
            pass
        time.sleep(1)
    time.sleep(2)
    print("page ready:", c.eval("document.title"), flush=True)

    ff = subprocess.Popen([
        "ffmpeg", "-y", "-f", "x11grab", "-framerate", "30", "-video_size", f"{W}x{H}",
        "-draw_mouse", "0", "-i", f":{V}", "-c:v", "libx264", "-pix_fmt", "yuv420p",
        "-preset", "medium", "-crf", "19", OUT
    ], stdout=open("/tmp/ss_motion_ffmpeg.log", "w"), stderr=subprocess.STDOUT)
    time.sleep(2)
    print("begin:", c.eval("window.begin()"), flush=True)
    time.sleep(DUR)
    print("scene at end:", c.eval("document.querySelector('.scene.on') ? document.querySelector('.scene.on').id : 'none'"), flush=True)
    ff.terminate(); time.sleep(3)
    sh(f"pkill -9 -f 'Xvfb :{V}'")
    sh(f"rm -f /tmp/.X{V}-lock /tmp/.X11-unix/X{V}")
    print("DONE:", OUT, flush=True)
    print("duration:", sh(f"ffprobe -v error -show_entries format=duration -of csv=p=0 {OUT}").stdout.strip(), flush=True)


if __name__ == "__main__":
    main()
