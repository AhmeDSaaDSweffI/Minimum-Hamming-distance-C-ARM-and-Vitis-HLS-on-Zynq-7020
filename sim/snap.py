"""Screenshot of a QuestaSim window region, called from run_waves.do.

usage: python snap.py <x> <y> <width> <height> <tk_screen_w> <tk_screen_h> <out.png>

x, y, width and height are Tk coordinates (winfo rootx/rooty/width/height).
If QuestaSim is not DPI aware, Tk works in scaled pixels (e.g. 1707 px wide on
a 2560 px screen at 150 %), so they are converted with the ratio of the real
screen size to Tk's screen size.
"""
import ctypes
import sys

from PIL import ImageGrab, ImageStat

x, y, w, h, tk_w, tk_h = (int(float(v)) for v in sys.argv[1:7])
out = sys.argv[7]

try:
    ctypes.windll.shcore.SetProcessDpiAwareness(2)  # real screen pixels
except (AttributeError, OSError):
    ctypes.windll.user32.SetProcessDPIAware()
screen_w = ctypes.windll.user32.GetSystemMetrics(0)
screen_h = ctypes.windll.user32.GetSystemMetrics(1)
sx, sy = screen_w / tk_w, screen_h / tk_h

box = (round(x * sx), round(y * sy), round((x + w) * sx), round((y + h) * sy))
img = ImageGrab.grab(bbox=box, all_screens=True)
img.save(out)

spread = max(ImageStat.Stat(img.convert("L")).stddev[0], 0.0)
note = "" if spread > 5 else "  WARNING: almost uniform image, check that the wave window was visible"
print(f"saved {out} ({img.width}x{img.height} px, scale {sx:.2f}){note}")
