#!/usr/bin/env python3
"""record_demo.py — real screen recording of the SUBSECOND dashboard (headless VPS).

Xvfb -> Chrome (CDP) -> ffmpeg x11grab -> CDP-driven scroll/hover/click -> reads back state.
Produces /tmp/subsecond-raw.mp4 (1600x900). Verify clicks by reading element state over CDP.
"""
import json, os, random, subprocess, sys, time, urllib.request

V, W, H = 99, 1600, 900
PORT = 8899
DASH = f"http://localhost:{PORT}/frontend/index.html"
PROFILE = "/tmp/ss-rec"
OUT = "/tmp/subsecond-raw.mp4"
CDP_PORT = 9222


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
                    if "localhost" in (t.get("url") or ""):
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

    def mouse(self, x, y, typ, button, buttons, clicks):
        self._send("Input.dispatchMouseEvent", {"type": typ, "x": int(x), "y": int(y),
                                                "button": button, "buttons": buttons, "clickCount": clicks})

    def click(self, x, y):
        self.mouse(x, y, "mouseMoved", "none", 0, 0); time.sleep(0.05)
        self.mouse(x, y, "mousePressed", "left", 1, 1); time.sleep(0.05)
        self.mouse(x, y, "mouseReleased", "left", 0, 1)

    def wheel(self, dy):
        self._send("Input.dispatchMouseEvent", {"type": "mouseWheel", "x": W // 2, "y": H // 2,
                                                "deltaX": 0, "deltaY": dy})


c = None


def ghost(x, y):
    sh(f"DISPLAY=:{V} xdotool mousemove {int(x)} {int(y)}")


def glide(x, y, steps=10):
    for i in range(steps):
        ghost(x + random.randint(-2, 2), y + random.randint(-2, 2))
        time.sleep(0.05)


def center(sel):
    s = json.dumps(sel)
    v = c.eval(f"(() => {{ const el=document.querySelector({s}); if(!el) return null;"
               f" const r=el.getBoundingClientRect(); if(r.width<2||r.height<2) return null;"
               f" return JSON.stringify({{x:Math.round(r.x+r.width/2), y:Math.round(r.y+r.height/2)}}); }})()")
    return json.loads(v) if v else None


def scroll_to(sel, label):
    pos = center(sel)
    if not pos:
        print(f"  !! {sel} not visible", flush=True); return None
    v = c.eval(f"(() => {{ const el=document.querySelector({json.dumps(sel)});"
               f" window.scrollTo({{top: window.scrollY + el.getBoundingClientRect().top - 90, behavior:'smooth'}}); return 1; }})()")
    time.sleep(1.6)
    p2 = center(sel)
    print(f"  scroll -> {label}: {p2}", flush=True)
    return p2


def main():
    global c
    sh(f"rm -f /tmp/.X{V}-lock /tmp/.X11-unix/X{V}")
    sh(f"pkill -9 -f 'Xvfb :{V}'")
    sh(f"rm -rf {PROFILE}")
    subprocess.Popen(["Xvfb", f":{V}", "-screen", "0", f"{W}x{H}x24"],
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(2)
    subprocess.Popen([
        "google-chrome", f"--user-data-dir={PROFILE}", "--no-first-run", "--disable-infobars",
        "--disable-gpu", "--no-sandbox", f"--window-size={W},{H}", "--window-position=0,0",
        f"--remote-debugging-port={CDP_PORT}", "--remote-allow-origins=*", f"--app={DASH}"
    ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env={**os.environ, "DISPLAY": f":{V}"})

    for _ in range(25):
        time.sleep(2)
        try:
            c = Cdp(CDP_PORT); break
        except Exception:
            pass
    else:
        sys.exit("CDP never came up")

    # wait for the dashboard data to render (KPI leaves the em-dash placeholder)
    for _ in range(40):
        try:
            v = c.eval("(() => { const e=document.querySelector('.kpi .val'); return e?e.textContent:''; })()")
            if v and v not in ("—", "", "…"):
                print("  rendered, first KPI:", v, flush=True); break
        except Exception:
            pass
        time.sleep(1)
    time.sleep(3)
    print("  status pill:", c.eval("document.querySelector('#status').textContent"), flush=True)

    ff = subprocess.Popen([
        "ffmpeg", "-y", "-f", "x11grab", "-framerate", "24", "-video_size", f"{W}x{H}",
        "-draw_mouse", "1", "-i", f":{V}", "-c:v", "libx264", "-pix_fmt", "yuv420p",
        "-preset", "medium", "-crf", "20", OUT
    ], stdout=open("/tmp/ss_ffmpeg.log", "w"), stderr=subprocess.STDOUT)
    time.sleep(2)

    try:
        # 1) Hold on the KPI strip
        glide(700, 260); time.sleep(5)
        # 2) Hover the latency-race bars
        bar = center(".bar-track")
        if bar:
            glide(bar["x"], bar["y"]); time.sleep(2)
            for y in range(bar["y"] - 40, bar["y"] + 120, 20):
                glide(bar["x"] + random.randint(-30, 30), y); time.sleep(0.6)
        time.sleep(3)
        # 3) Reflex arc
        arc = scroll_to(".arc", "reflex arc")
        if arc: glide(arc["x"], arc["y"]); time.sleep(5)
        # 4) Execution log — fan across the rows
        log = scroll_to("#log", "execution log")
        if log:
            glide(log["x"], log["y"]); time.sleep(2)
            for y in range(log["y"] - 40, log["y"] + 110, 22):
                glide(log["x"] - 200 + random.randint(-20, 20), y); time.sleep(0.7)
        time.sleep(4)
        # 5) Contracts
        cnt = scroll_to("#contracts", "contracts")
        if cnt: glide(cnt["x"] - 150, cnt["y"] - 30); time.sleep(6)
        # 6) Footer / end card
        glide(W // 2, H - 120); time.sleep(5)
    finally:
        try:
            print("  READBACK status:", c.eval("document.querySelector('#status').textContent"), flush=True)
            print("  READBACK kpi0:", c.eval("document.querySelector('.kpi .val').textContent"), flush=True)
            print("  READBACK rows:", c.eval("document.querySelectorAll('#log tr').length"), flush=True)
        except Exception as e:
            print("  READBACK failed:", e, flush=True)
        ff.terminate(); time.sleep(3)
        sh(f"pkill -9 -f 'Xvfb :{V}'")
        sh(f"rm -f /tmp/.X{V}-lock /tmp/.X11-unix/X{V}")

    print("DONE:", OUT, flush=True)
    print("duration:", sh(f"ffprobe -v error -show_entries format=duration -of csv=p=0 {OUT}").stdout.strip(), flush=True)


if __name__ == "__main__":
    main()
