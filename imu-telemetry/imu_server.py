#!/usr/bin/env python3
"""
imu_server.py — AltIMU-10 v5 telemetry for the mangey-moose Jetson.

Reads the three chips on the Pololu AltIMU-10 v5 over I2C
    LSM6DS33  accel + gyro   (0x6B)
    LIS3MDL   magnetometer   (0x1E)
    LPS25H    barometer      (0x5D)
and serves a small dashboard on http://0.0.0.0:$PORT that shows a rolling
window of the last $WINDOW samples. No external JS/CSS — works with no
internet on the ground station.

Endpoints
    /            dashboard (HTML, inline JS, <canvas> sparklines)
    /data        JSON: {"window": N, "samples": [ {...}, ... ]}   (oldest -> newest)
    /latest      JSON: most recent sample only
    /healthz     200 once the sensors have been initialised

Drop-in seam: if you'd rather use your own reader, replace `read_sample()`;
it must return a dict of plain numbers. Everything else is agnostic.

Env
    I2C_BUS      default 7     (Orin Nano devkit header pins 3/5). Pins 27/28 = 1.
    PORT         default 8080
    WINDOW       default 10    rolling window length
    RATE_HZ      default 20    sensor sample rate
    SIM          "1" to run without hardware (synthetic data) for UI testing
"""

import json
import math
import os
import signal
import sys
import threading
import time
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

I2C_BUS = int(os.environ.get("I2C_BUS", "7"))
PORT    = int(os.environ.get("PORT", "8080"))
WINDOW  = int(os.environ.get("WINDOW", "10"))
RATE_HZ = float(os.environ.get("RATE_HZ", "20"))
SIM     = os.environ.get("SIM", "0") == "1"


def log(msg: str) -> None:
    print(f"[imu-telemetry] {msg}", flush=True)


# --------------------------------------------------------------------------
# AltIMU-10 v5 driver (register maps per ST datasheets / Pololu Arduino libs)
# --------------------------------------------------------------------------
LSM6_ADDR, LIS3_ADDR, LPS_ADDR = 0x6B, 0x1E, 0x5D

# LSM6DS33
LSM6_CTRL1_XL, LSM6_CTRL2_G, LSM6_CTRL3_C = 0x10, 0x11, 0x12
LSM6_OUTX_L_G, LSM6_OUTX_L_XL = 0x22, 0x28
ACCEL_MG_PER_LSB = 0.061          # ±2 g
GYRO_MDPS_PER_LSB = 8.75          # ±245 dps

# LIS3MDL
LIS3_CTRL1, LIS3_CTRL2, LIS3_CTRL3, LIS3_CTRL4 = 0x20, 0x21, 0x22, 0x23
LIS3_OUT_X_L = 0x28
MAG_LSB_PER_GAUSS = 6842.0        # ±4 gauss

# LPS25H
LPS_CTRL1 = 0x20
LPS_PRESS_OUT_XL, LPS_TEMP_OUT_L = 0x28, 0x2B


def _s16(lo: int, hi: int) -> int:
    v = (hi << 8) | lo
    return v - 65536 if v & 0x8000 else v


class AltIMU10v5:
    def __init__(self, bus_num: int):
        from smbus2 import SMBus  # imported here so SIM mode needs no smbus2
        self.bus = SMBus(bus_num)
        w = self.bus.write_byte_data
        # LSM6DS33: accel 104 Hz ±2g, gyro 104 Hz ±245 dps, register auto-increment
        w(LSM6_ADDR, LSM6_CTRL1_XL, 0x40)
        w(LSM6_ADDR, LSM6_CTRL2_G,  0x40)
        w(LSM6_ADDR, LSM6_CTRL3_C,  0x04)
        # LIS3MDL: ultra-high-perf XY, 10 Hz; ±4 gauss; continuous; UHP Z
        w(LIS3_ADDR, LIS3_CTRL1, 0x70)
        w(LIS3_ADDR, LIS3_CTRL2, 0x00)
        w(LIS3_ADDR, LIS3_CTRL3, 0x00)
        w(LIS3_ADDR, LIS3_CTRL4, 0x0C)
        # LPS25H: active, 12.5 Hz
        w(LPS_ADDR, LPS_CTRL1, 0xB0)
        time.sleep(0.05)

    def _block(self, addr: int, reg: int, n: int, autoinc_bit: bool) -> list:
        # LIS3MDL / LPS25H need bit7 set on the sub-address for multi-byte reads.
        return self.bus.read_i2c_block_data(addr, reg | (0x80 if autoinc_bit else 0), n)

    def read(self) -> dict:
        g = self._block(LSM6_ADDR, LSM6_OUTX_L_G, 6, False)
        a = self._block(LSM6_ADDR, LSM6_OUTX_L_XL, 6, False)
        m = self._block(LIS3_ADDR, LIS3_OUT_X_L, 6, True)
        p = self._block(LPS_ADDR, LPS_PRESS_OUT_XL, 3, True)
        t = self._block(LPS_ADDR, LPS_TEMP_OUT_L, 2, True)

        ax, ay, az = (_s16(a[0], a[1]), _s16(a[2], a[3]), _s16(a[4], a[5]))
        gx, gy, gz = (_s16(g[0], g[1]), _s16(g[2], g[3]), _s16(g[4], g[5]))
        mx, my, mz = (_s16(m[0], m[1]), _s16(m[2], m[3]), _s16(m[4], m[5]))
        praw = (p[2] << 16) | (p[1] << 8) | p[0]
        if praw & 0x800000:
            praw -= 1 << 24
        traw = _s16(t[0], t[1])

        ax_g, ay_g, az_g = (v * ACCEL_MG_PER_LSB / 1000.0 for v in (ax, ay, az))
        # Simple accel-only tilt; good enough for a live "is it level" readout.
        roll  = math.degrees(math.atan2(ay_g, az_g))
        pitch = math.degrees(math.atan2(-ax_g, math.hypot(ay_g, az_g)))

        return {
            "ax": round(ax_g, 3), "ay": round(ay_g, 3), "az": round(az_g, 3),                 # g
            "gx": round(gx * GYRO_MDPS_PER_LSB / 1000.0, 2),                                     # dps
            "gy": round(gy * GYRO_MDPS_PER_LSB / 1000.0, 2),
            "gz": round(gz * GYRO_MDPS_PER_LSB / 1000.0, 2),
            "mx": round(mx / MAG_LSB_PER_GAUSS, 4),                                               # gauss
            "my": round(my / MAG_LSB_PER_GAUSS, 4),
            "mz": round(mz / MAG_LSB_PER_GAUSS, 4),
            "pressure_hpa": round(praw / 4096.0, 2),
            "temp_c": round(42.5 + traw / 480.0, 2),
            "roll": round(roll, 1), "pitch": round(pitch, 1),
        }


class SimIMU:
    """Synthetic data so the dashboard can be exercised without the board."""
    def __init__(self):
        self.t0 = time.time()

    def read(self) -> dict:
        t = time.time() - self.t0
        roll = 15 * math.sin(t / 2.0)
        pitch = 8 * math.sin(t / 3.1)
        return {
            "ax": round(-math.sin(math.radians(pitch)), 3), "ay": round(math.sin(math.radians(roll)), 3), "az": round(math.cos(math.radians(roll)), 3),
            "gx": round(20 * math.cos(t / 2.0), 2), "gy": round(10 * math.cos(t / 3.1), 2), "gz": round(2 * math.sin(t), 2),
            "mx": 0.21, "my": -0.05, "mz": 0.43,
            "pressure_hpa": round(1013.25 + math.sin(t / 10), 2), "temp_c": 24.5,
            "roll": round(roll, 1), "pitch": round(pitch, 1),
        }


# --------------------------------------------------------------------------
# Sampler thread + rolling window
# --------------------------------------------------------------------------
_samples: deque = deque(maxlen=WINDOW)
_lock = threading.Lock()
_ready = threading.Event()
_stop = threading.Event()


def read_sample(imu) -> dict:
    """The seam. Return a flat dict of numbers; 't' is added for you."""
    return imu.read()


def sampler():
    imu = SimIMU() if SIM else AltIMU10v5(I2C_BUS)
    log("simulated IMU" if SIM else f"AltIMU-10 v5 on /dev/i2c-{I2C_BUS}")
    _ready.set()
    period = 1.0 / RATE_HZ
    errors = 0
    while not _stop.is_set():
        t0 = time.time()
        try:
            s = read_sample(imu)
            s["t"] = round(t0, 3)
            with _lock:
                _samples.append(s)
            errors = 0
        except Exception as e:  # noqa: BLE001 — bus glitch; keep serving, don't die
            errors += 1
            if errors in (1, 10, 100):
                log(f"read error x{errors}: {e}")
            if errors >= 200:
                log("too many consecutive I2C errors; exiting for restart")
                os._exit(1)
        time.sleep(max(0.0, period - (time.time() - t0)))


# --------------------------------------------------------------------------
# HTTP
# --------------------------------------------------------------------------
PAGE = """<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>mangey-moose IMU</title>
<style>
 :root{--bg:#0e1116;--fg:#e6edf3;--mut:#8b949e;--ax:#ff7b72;--ay:#7ee787;--az:#79c0ff;--grid:#21262d}
 body{margin:0;background:var(--bg);color:var(--fg);font:14px/1.4 ui-monospace,Menlo,Consolas,monospace}
 header{padding:12px 16px;border-bottom:1px solid var(--grid);display:flex;gap:24px;align-items:baseline}
 header h1{margin:0;font-size:16px} header span{color:var(--mut)}
 main{display:grid;grid-template-columns:repeat(auto-fit,minmax(320px,1fr));gap:12px;padding:12px}
 .card{background:#161b22;border:1px solid var(--grid);border-radius:8px;padding:10px}
 .card h2{margin:0 0 6px;font-size:13px;color:var(--mut);font-weight:normal}
 .vals{display:flex;gap:14px;margin-bottom:6px} .vals b{font-weight:600}
 .x{color:var(--ax)} .y{color:var(--ay)} .z{color:var(--az)}
 canvas{width:100%;height:110px;display:block}
 .big{font-size:28px;font-weight:600}
 .stale{color:#f85149}
</style></head><body>
<header><h1>mangey-moose · AltIMU-10 v5</h1><span id="meta">connecting…</span></header>
<main>
 <div class="card"><h2>accel (g)</h2><div class="vals" id="a"></div><canvas id="ca"></canvas></div>
 <div class="card"><h2>gyro (°/s)</h2><div class="vals" id="g"></div><canvas id="cg"></canvas></div>
 <div class="card"><h2>mag (gauss)</h2><div class="vals" id="m"></div><canvas id="cm"></canvas></div>
 <div class="card"><h2>attitude (accel-only)</h2><div class="vals">
   <div>roll <span class="big" id="roll">–</span>°</div><div>pitch <span class="big" id="pitch">–</span>°</div></div>
   <div class="vals" style="margin-top:8px"><span id="baro"></span></div></div>
</main>
<script>
const W = __WINDOW__, PERIOD = __PERIOD__;
const sets = {a:['ax','ay','az'], g:['gx','gy','gz'], m:['mx','my','mz']};
const cls  = ['x','y','z'], colors = ['#ff7b72','#7ee787','#79c0ff'];
function draw(id, rows, keys){
  const c = document.getElementById(id), r = c.getBoundingClientRect();
  c.width = r.width*devicePixelRatio; c.height = r.height*devicePixelRatio;
  const ctx = c.getContext('2d'); ctx.scale(devicePixelRatio, devicePixelRatio);
  const w = r.width, h = r.height, pad = 6;
  let lo = Infinity, hi = -Infinity;
  for (const row of rows) for (const k of keys) { lo = Math.min(lo,row[k]); hi = Math.max(hi,row[k]); }
  if (!isFinite(lo)) return; if (hi-lo < 1e-6) { hi += 0.5; lo -= 0.5; }
  ctx.strokeStyle = '#21262d'; ctx.beginPath(); ctx.moveTo(0,h/2); ctx.lineTo(w,h/2); ctx.stroke();
  keys.forEach((k,i) => {
    ctx.strokeStyle = colors[i]; ctx.lineWidth = 2; ctx.beginPath();
    rows.forEach((row,j) => {
      const x = pad + (w-2*pad) * (W>1 ? j/(W-1) : 0);          // fixed slots: window scrolls left
      const y = h - pad - (h-2*pad) * ((row[k]-lo)/(hi-lo));
      j ? ctx.lineTo(x,y) : ctx.moveTo(x,y);
    });
    ctx.stroke();
  });
}
async function tick(){
  try {
    const d = await (await fetch('/data',{cache:'no-store'})).json();
    const rows = d.samples; if (!rows.length) return;
    const last = rows[rows.length-1];
    for (const [id,keys] of Object.entries(sets)) {
      document.getElementById(id).innerHTML = keys.map((k,i)=>`<span class="${cls[i]}">${k} <b>${last[k].toFixed(k[0]=='m'?3:2)}</b></span>`).join('');
      draw('c'+id, rows, keys);
    }
    document.getElementById('roll').textContent = last.roll.toFixed(1);
    document.getElementById('pitch').textContent = last.pitch.toFixed(1);
    document.getElementById('baro').textContent = `${last.pressure_hpa.toFixed(1)} hPa · ${last.temp_c.toFixed(1)} °C`;
    const age = Date.now()/1000 - last.t;
    const meta = document.getElementById('meta');
    meta.textContent = `window ${rows.length}/${W} · ${age.toFixed(1)}s ago`;
    meta.className = age > 2 ? 'stale' : '';
  } catch(e) { document.getElementById('meta').textContent = 'no data: '+e; }
}
setInterval(tick, PERIOD); tick();
</script></body></html>
"""


class Handler(BaseHTTPRequestHandler):
    def _send(self, code: int, body: bytes, ctype: str = "application/json") -> None:
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802
        if self.path in ("/", "/index.html"):
            page = PAGE.replace("__WINDOW__", str(WINDOW)).replace("__PERIOD__", str(int(1000 / RATE_HZ)))
            self._send(200, page.encode(), "text/html; charset=utf-8")
        elif self.path == "/data":
            with _lock:
                body = json.dumps({"window": WINDOW, "samples": list(_samples)})
            self._send(200, body.encode())
        elif self.path == "/latest":
            with _lock:
                body = json.dumps(_samples[-1] if _samples else {})
            self._send(200, body.encode())
        elif self.path == "/healthz":
            self._send(200 if _ready.is_set() else 503, b'{"ok":true}' if _ready.is_set() else b'{"ok":false}')
        else:
            self._send(404, b'{"error":"not found"}')

    def log_message(self, *_):  # silence per-request access logs
        return


def main() -> int:
    def _stop_all(*_):
        _stop.set()
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, _stop_all)
    signal.signal(signal.SIGINT, _stop_all)

    th = threading.Thread(target=sampler, daemon=True, name="sampler")
    th.start()
    if not _ready.wait(timeout=10):
        log("sensor init did not complete in 10s (check I2C_BUS / wiring / --device /dev/i2c-N)")
        return 1

    srv = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    log(f"dashboard on http://0.0.0.0:{PORT}/  (window={WINDOW}, {RATE_HZ} Hz)")
    try:
        srv.serve_forever()
    except SystemExit:
        pass
    finally:
        srv.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
