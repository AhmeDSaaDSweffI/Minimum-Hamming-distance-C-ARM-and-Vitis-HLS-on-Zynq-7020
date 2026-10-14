"""Draw the waveform figure of the report from the Icarus Verilog VCD files.

usage: python plot_waves.py [vcd_dir] [out_dir]
  vcd_dir  folder with waves_v1.vcd and waves_v2.vcd (default: this folder)
  out_dir  folder for wave_v1.png and wave_v2.png (default: ../report/figures)

The VCD files come from run_icarus.bat. Needs Python 3 and Pillow.
"""
import math
import os
import sys
from bisect import bisect_right

from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
TB = "tb_min_hamming"

# colours (dark background, like a waveform viewer)
BG = (0, 0, 0)
NAME_BG = (28, 28, 28)
GRID = (52, 52, 52)
TRACE = (0, 225, 0)
XZ = (230, 50, 50)
TEXT = (235, 235, 235)
VALUE = (255, 255, 255)
DIVIDER = (120, 185, 255)
CURSOR = (255, 214, 0)
AXIS = (190, 190, 190)

UNIT_PS = {"ns": 1e3, "us": 1e6, "ms": 1e9}

# monospaced fonts: Windows, Linux, macOS
REGULAR = ("consola.ttf", "DejaVuSansMono.ttf", "LiberationMono-Regular.ttf", "Menlo.ttc")
BOLD = ("consolab.ttf", "DejaVuSansMono-Bold.ttf", "LiberationMono-Bold.ttf", "Menlo.ttc")


def load_font(names, size):
    """The first of the TrueType fonts that is installed, else Pillow's own."""
    for name in names:
        try:
            return ImageFont.truetype(name, size)
        except OSError:
            pass
    try:
        return ImageFont.load_default(size=size)   # Pillow 10.1 and later
    except TypeError:
        return ImageFont.load_default()


# ---------------------------------------------------------------- VCD reader
def read_vcd(path):
    """Return {full signal name: (times in ps, values)}; a value is None for x/z."""
    header = []
    with open(path) as f:
        for line in f:
            header.extend(line.split())
            if "$enddefinitions" in line:
                break
        scale_ps, ids, scope = 1, {}, []
        i = 0
        while i < len(header):
            word = header[i]
            if word == "$timescale":
                spec = ""
                i += 1
                while header[i] != "$end":
                    spec += header[i]
                    i += 1
                scale_ps = parse_timescale(spec)
            elif word == "$scope":
                scope.append(header[i + 2])
            elif word == "$upscope":
                scope.pop()
            elif word == "$var":
                ident, name = header[i + 3], header[i + 4]
                ids.setdefault(ident, []).append(".".join(scope + [name]))
            i += 1

        changes = {ident: ([], []) for ident in ids}
        t = 0
        for line in f:
            c = line[:1]
            if c == "#":
                t = int(line[1:]) * scale_ps
                continue
            if c in ("0", "1"):
                ident, value = line[1:].strip(), int(c)
            elif c in ("x", "z", "X", "Z"):
                ident, value = line[1:].strip(), None
            elif c in ("b", "B"):
                bits, ident = line[1:].split()
                value = int(bits, 2) if set(bits) <= {"0", "1"} else None
            else:
                continue
            times, values = changes[ident]
            if times and times[-1] == t:
                times.pop()
                values.pop()
            if values and values[-1] == value:
                continue
            times.append(t)
            values.append(value)

    signals = {}
    for ident, names in ids.items():
        for name in names:
            signals[name] = changes[ident]
    return signals


def parse_timescale(spec):
    units = {"s": 10**12, "ms": 10**9, "us": 10**6, "ns": 10**3, "ps": 1}
    number = spec.rstrip("munpsf")
    return int(number) * units[spec[len(number):]]


def value_at(signal, t):
    times, values = signal
    k = bisect_right(times, t) - 1
    return values[k] if k >= 0 else None


def first_rise(signal):
    for t, v in zip(*signal):
        if v == 1:
            return t
    raise ValueError("signal never rises")


def segments(signal, t0, t1):
    """(start, end, value) pieces of the signal inside [t0, t1]."""
    times, values = signal
    k = max(bisect_right(times, t0) - 1, 0)
    out = []
    while k < len(times) and times[k] < t1:
        end = times[k + 1] if k + 1 < len(times) else t1
        out.append((max(times[k], t0), min(end, t1), values[k]))
        k += 1
    return out


# ---------------------------------------------------------------- formatting
def fmt(value, kind):
    if value is None:
        return "x"
    if kind == "ascii":
        return value.to_bytes(5, "big").decode("ascii", "replace").strip()
    return str(value)


def fmt_time(t_ps, unit):
    text = ("%.3f" % (t_ps / UNIT_PS[unit])).rstrip("0").rstrip(".")
    return "%s %s" % (text, unit.replace("us", "µs"))


def nice_step(span, ticks=8):
    """Tick spacing of 1, 2 or 5 times a power of ten, about span/ticks."""
    raw = span / ticks
    power = 10 ** math.floor(math.log10(raw))
    for m in (1, 2, 5, 10):
        if raw <= m * power:
            return m * power
    return 10 * power


# ---------------------------------------------------------------- drawing
def draw_view(signals, view, out_png):
    width, font_px = view["width"], view["font"]
    row_h, trace_h = int(font_px * 1.6), font_px
    font = load_font(REGULAR, font_px)
    small = load_font(REGULAR, int(font_px * 0.7))
    bold = load_font(BOLD, font_px)
    name_w, value_w = view["name_w"], view["value_w"]
    x0, x1 = name_w + value_w + 14, width - 26
    t0, t1 = view["window"]
    unit, rows = view["unit"], view["rows"]

    top = 10
    y_axis = top + row_h * len(rows) + 6
    axis_h = int(font_px * 2.2)
    height = y_axis + axis_h
    img = Image.new("RGB", (width, height), BG)
    d = ImageDraw.Draw(img)
    d.rectangle([0, 0, name_w + value_w, height], fill=NAME_BG)
    d.line([(name_w, top), (name_w, y_axis - 6)], fill=GRID, width=1)

    def X(t):
        return x0 + (t - t0) * (x1 - x0) / (t1 - t0)

    # grid and time axis
    step = nice_step((t1 - t0) / UNIT_PS[unit]) * UNIT_PS[unit]
    tick = math.ceil(t0 / step) * step
    while tick <= t1:
        x = X(tick)
        for y in range(top, y_axis, 6):
            d.point((x, y), fill=GRID)
        d.line([(x, y_axis), (x, y_axis + 8)], fill=AXIS, width=2)
        label = fmt_time(tick, unit)
        lw = font.getlength(label)
        d.text((min(max(x - lw / 2, x0 - 10), width - lw - 4), y_axis + 12), label,
               font=font, fill=AXIS)
        tick += step
    d.line([(x0, y_axis), (x1, y_axis)], fill=AXIS, width=2)

    # cursor lines go behind the traces, so that a one-cycle pulse stays visible
    for t, _, _ in view["cursors"]:
        d.line([(X(t), top), (X(t), y_axis)], fill=CURSOR, width=2)

    for r, row in enumerate(rows):
        y = top + r * row_h
        y_hi = y + (row_h - trace_h) // 2
        y_lo = y_hi + trace_h
        y_mid = (y_hi + y_lo) // 2
        text_y = y + (row_h - font_px) // 2 - 2
        if row[0] == "div":
            d.text((10, text_y), row[1], font=bold, fill=DIVIDER)
            x_line = max(x0, 10 + bold.getlength(row[1]) + 14)
            d.line([(x_line, y + row_h // 2), (x1, y + row_h // 2)], fill=GRID, width=1)
            continue
        label, name, kind = row
        sig = signals[name]
        d.text((14, text_y), label, font=font, fill=TEXT)
        d.text((name_w + 10, text_y), fmt(value_at(sig, t1), kind), font=font, fill=VALUE)

        prev = None
        for a, b, v in segments(sig, t0, t1):
            xa, xb = X(a), X(b)
            colour = XZ if v is None else TRACE
            if kind == "bit":
                level = y_mid if v is None else (y_hi if v else y_lo)
                d.line([(xa, level), (xb, level)], fill=colour, width=2)
                if prev is not None and prev != v:
                    d.line([(xa, y_hi), (xa, y_lo)], fill=colour, width=2)
            else:
                s = 6
                if xb - xa > 2 * s + 2:
                    d.line([(xa, y_mid), (xa + s, y_hi), (xb - s, y_hi), (xb, y_mid),
                            (xb - s, y_lo), (xa + s, y_lo), (xa, y_mid)], fill=colour, width=2)
                    text = fmt(v, kind)
                    for f in (font, small):
                        if f.getlength(text) + 2 * s + 4 <= xb - xa:
                            dy = (font_px - getattr(f, "size", font_px)) // 2
                            d.text((xa + s + 4, text_y + dy), text, font=f, fill=VALUE)
                            break
                else:   # changes closer than a few pixels: draw a filled band
                    d.line([(xa, y_hi), (xa, y_lo)], fill=colour, width=2)
                    d.line([(xa, y_hi), (xb, y_hi)], fill=colour, width=2)
                    d.line([(xa, y_lo), (xb, y_lo)], fill=colour, width=2)
            prev = v

    # cursor labels in the title row, just left of the cursor
    for t, label, label_unit in view["cursors"]:
        x = X(t)
        text = "%s  %s" % (label, fmt_time(t, label_unit))
        tw = font.getlength(text)
        ly = top + (row_h - font_px) // 2 - 2
        lx = max(x - tw - 16, x0)
        d.rectangle([lx - 6, ly - 2, lx + tw + 6, ly + font_px + 4], fill=BG, outline=CURSOR, width=2)
        d.text((lx, ly), text, font=font, fill=CURSOR)

    img.save(out_png)
    print("%s: %dx%d" % (out_png, width, height))


# ---------------------------------------------------------------- the two views
def whole_call(signals, title, unit, extra_rows):
    """View of one core from reset to the end of the run."""
    done = first_rise(signals[TB + ".dut.ap_done"])
    last = max(times[-1] for times, _ in signals.values() if times)
    rows = [("div", title),
            ("phase", TB + ".phase", "ascii"),
            ("rows", TB + ".rows", "dec"),
            ("RVALID", TB + ".m_axi_gmem_RVALID", "bit"),
            ("ap_done", TB + ".dut.ap_done", "bit"),
            ("result", TB + ".result", "dec")] + extra_rows + \
           [("latency", TB + ".latency", "dec")]
    return dict(width=2400, font=30, name_w=210, value_w=170,
                window=(0, last * 1.05), unit=unit, rows=rows,
                cursors=[(done, "ap_done", "us")])


def main():
    vcd_dir = sys.argv[1] if len(sys.argv) > 1 else HERE
    out_dir = sys.argv[2] if len(sys.argv) > 2 else os.path.join(HERE, "..", "report", "figures")
    os.makedirs(out_dir, exist_ok=True)
    jobs = [("waves_v1.vcd", "wave_v1.png", "version 1 core (brute force)", "ms", []),
            ("waves_v2.vcd", "wave_v2.png", "version 2 core (sort and search)", "us",
             [("stage", TB + ".stage", "dec")])]
    for vcd, png, title, unit, extra in jobs:
        path = os.path.join(vcd_dir, vcd)
        if not os.path.exists(path):
            print("%s: missing, skipped" % path)
            continue
        signals = read_vcd(path)
        draw_view(signals, whole_call(signals, title, unit, extra), os.path.join(out_dir, png))


if __name__ == "__main__":
    main()
