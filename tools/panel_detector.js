// JavaScript port of dynamic_panelzoom.koplugin/panel_detector.lua.
// Keep both in sync: the editor pre-detects panels with the same algorithm the
// plugin uses, so what you correct is what the plugin would have produced.
//
// detect(planes, gw, gh, readingDir, opts) -> [{x, y, w, h}] normalized, in reading order.
// planes: {r, g, b}, each indexable as plane[y * gw + x] with values 0..255.

(function (root) {
  "use strict";

  const DEFAULTS = {
    min_tolerance: 14,
    max_tolerance: 40,
    noise_levels: [0.012, 0.04, 0.09, 0.16, 0.25],
    loose_max_gap_frac: 0.04,
    gap_frac: 0.003,
    loose_gap_frac: 0.004,
    min_segment_frac: 0.04,
    min_panel_w: 0.05,
    min_panel_h: 0.04,
    min_panel_area: 0.012,
    border_frac: 0.02,
    edge_margin_frac: 0.03,
    max_skew_deg: 2.5,
    skew_step_deg: 0.25,
    max_depth: 12,
  };

  function opt(opts, key) {
    return opts && opts[key] !== undefined ? opts[key] : DEFAULTS[key];
  }

  function estimateBackground(planes, gw, gh, borderFrac) {
    const { r, g, b } = planes;
    const bx = Math.max(1, Math.floor(gw * borderFrac));
    const by = Math.max(1, Math.floor(gh * borderFrac));
    const hist = new Array(16).fill(0);
    const luma = (i) => (r[i] * 3 + g[i] * 6 + b[i]) / 10;

    function forBorder(fn) {
      for (let y = 0; y < gh; y++) {
        if (y < by || y >= gh - by) {
          for (let x = 0; x < gw; x++) fn(y * gw + x);
        } else {
          for (let x = 0; x < bx; x++) fn(y * gw + x);
          for (let x = gw - bx; x < gw; x++) fn(y * gw + x);
        }
      }
    }

    forBorder((i) => {
      let bin = Math.floor(luma(i) / 16);
      if (bin > 15) bin = 15;
      hist[bin]++;
    });

    let best = 15, bestCount = -1;
    for (let i = 0; i < 16; i++) if (hist[i] > bestCount) { best = i; bestCount = hist[i]; }
    const lo = best * 16 - 8, hi = best * 16 + 24;

    let n = 0, sr = 0, sg = 0, sb = 0;
    forBorder((i) => {
      const l = luma(i);
      if (l >= lo && l < hi) { n++; sr += r[i]; sg += g[i]; sb += b[i]; }
    });
    if (n === 0) {
      const v = best * 16 + 8;
      return [v, v, v, 0, 0];
    }
    const borderTotal = hist.reduce((a, c) => a + c, 0);
    const mr = sr / n, mg = sg / n, mb = sb / n;

    let dev = 0;
    forBorder((i) => {
      const l = luma(i);
      if (l >= lo && l < hi) {
        dev += Math.max(Math.abs(r[i] - mr), Math.abs(g[i] - mg), Math.abs(b[i] - mb));
      }
    });
    return [mr, mg, mb, dev / n, n / Math.max(1, borderTotal)];
  }

  function estimateGutterColors(planes, gw, gh, marginX, marginY, tol, maxRunFrac) {
    const { r, g, b } = planes;
    const weights = new Map();
    const colors = new Map();

    function median(hist, n) {
      const half = n / 2;
      let acc = 0;
      for (let v = 0; v < 256; v++) {
        acc += hist[v];
        if (acc >= half) return v;
      }
      return 255;
    }

    function scan(count, idx, lo, hi, margin, maxRun) {
      let runColor = null, runLen = 0;
      function flush() {
        if (runColor && runLen > 0 && runLen <= maxRun) {
          const key = Math.floor(runColor[0] / 24) * 10000 + Math.floor(runColor[1] / 24) * 100 + Math.floor(runColor[2] / 24);
          weights.set(key, (weights.get(key) || 0) + runLen);
          if (!colors.has(key)) colors.set(key, runColor);
        }
        runColor = null; runLen = 0;
      }
      const hr = new Int32Array(256), hg = new Int32Array(256), hb = new Int32Array(256);
      for (let line = margin; line <= count - 1 - margin; line++) {
        hr.fill(0); hg.fill(0); hb.fill(0);
        let n = 0;
        for (let k = lo; k <= hi; k++) {
          const i = idx(line, k);
          hr[r[i]]++; hg[g[i]]++; hb[b[i]]++;
          n++;
        }
        const mr = median(hr, n), mg = median(hg, n), mb = median(hb, n);
        let close = 0;
        for (let k = lo; k <= hi; k++) {
          const i = idx(line, k);
          if (Math.abs(r[i] - mr) <= tol && Math.abs(g[i] - mg) <= tol && Math.abs(b[i] - mb) <= tol) close++;
        }
        if (close >= 0.9 * n) {
          if (runColor && Math.abs(runColor[0] - mr) <= tol && Math.abs(runColor[1] - mg) <= tol && Math.abs(runColor[2] - mb) <= tol) {
            runLen++;
          } else {
            flush();
            runColor = [mr, mg, mb]; runLen = 1;
          }
        } else {
          flush();
        }
      }
      flush();
    }

    const loX = Math.floor(gw * 0.04), hiX = Math.floor(gw * 0.96);
    const loY = Math.floor(gh * 0.04), hiY = Math.floor(gh * 0.96);
    scan(gh, (line, k) => line * gw + k, loX, hiX, marginY, Math.floor(maxRunFrac * gh));
    scan(gw, (line, k) => k * gw + line, loY, hiY, marginX, Math.floor(maxRunFrac * gw));

    const list = [];
    for (const [key, w] of weights) list.push({ color: colors.get(key), w });
    list.sort((a, c) => c.w - a.w);
    const out = [];
    for (const e of list) {
      let far = true;
      for (const o of out) {
        if (Math.abs(o[0] - e.color[0]) <= tol && Math.abs(o[1] - e.color[1]) <= tol && Math.abs(o[2] - e.color[2]) <= tol) far = false;
      }
      if (far && e.w >= 3) out.push(e.color);
      if (out.length >= 2) break;
    }
    return out;
  }

  function findSegments(counts, n, lineLen, noiseFrac, minGap, minLen, maxGap) {
    const thresh = Math.floor(noiseFrac * lineLen);
    const runs = [];
    let start = null;
    for (let i = 0; i < n; i++) {
      if (counts[i] > thresh) {
        if (start === null) start = i;
      } else if (start !== null) {
        runs.push({ s: start, e: i });
        start = null;
      }
    }
    if (start !== null) runs.push({ s: start, e: n });

    const merged = [];
    for (const r of runs) {
      const last = merged[merged.length - 1];
      const gap = last ? r.s - last.e : 0;
      if (last && (gap < minGap || (maxGap !== undefined && gap > maxGap))) {
        last.e = r.e;
      } else {
        merged.push({ s: r.s, e: r.e });
      }
    }
    return merged.filter((r) => r.e - r.s >= minLen);
  }

  function rowCounts(mask, gw, x0, y0, x1, y1, xa, xb) {
    const counts = new Array(y1 - y0);
    for (let y = y0; y < y1; y++) {
      let c = 0;
      const base = y * gw;
      for (let x = x0 + xa; x <= x1 - 1 - xb; x++) c += mask[base + x];
      counts[y - y0] = c;
    }
    return counts;
  }

  function colCounts(mask, gw, x0, y0, x1, y1, ya, yb) {
    const counts = new Array(x1 - x0).fill(0);
    for (let y = y0 + ya; y <= y1 - 1 - yb; y++) {
      const base = y * gw;
      for (let x = x0; x < x1; x++) counts[x - x0] += mask[base + x];
    }
    return counts;
  }

  function findPageBounds(planes, gw, gh, opts) {
    const { r, g, b } = planes;
    const [bgr, bgg, bgb, noise] = estimateBackground(planes, gw, gh, opt(opts, "border_frac"));
    const tol = Math.min(opt(opts, "max_tolerance"), Math.max(opt(opts, "min_tolerance"), noise * 3 + 6));
    const rows = new Array(gh).fill(0), cols = new Array(gw).fill(0);
    for (let y = 0; y < gh; y++) {
      const base = y * gw;
      for (let x = 0; x < gw; x++) {
        const i = base + x;
        if (Math.abs(r[i] - bgr) > tol || Math.abs(g[i] - bgg) > tol || Math.abs(b[i] - bgb) > tol) {
          rows[y]++; cols[x]++;
        }
      }
    }
    const first = (counts, n, len) => { for (let i = 0; i < n; i++) if (counts[i] > 0.05 * len) return i; return null; };
    const last = (counts, n, len) => { for (let i = n - 1; i >= 0; i--) if (counts[i] > 0.05 * len) return i + 1; return null; };
    const y0 = first(rows, gh, gw), y1 = last(rows, gh, gw);
    const x0 = first(cols, gw, gh), x1 = last(cols, gw, gh);
    if (x0 === null || x1 === null || y0 === null || y1 === null) return null;
    if (x1 - x0 < 0.3 * gw || y1 - y0 < 0.3 * gh) return null;
    return [x0, y0, x1, y1];
  }

  function estimateSkew(mask, gw, gh, maxDeg, stepDeg) {
    const pxs = [], pys = [];
    for (let y = 0; y < gh; y += 2) {
      const base = y * gw;
      for (let x = Math.floor(gw * 0.04); x <= Math.floor(gw * 0.96); x += 2) {
        if (mask[base + x] === 1) { pxs.push(x); pys.push(y); }
      }
    }
    const n = pxs.length;
    if (n < 200) return 0;

    const cx = gw / 2, cy = gh / 2;
    const size = gh * 2 + 8;
    const off = Math.floor(gh / 2) + 1;
    const hist = new Int32Array(size);

    function score(deg) {
      const phi = (deg * Math.PI) / 180;
      const sn = Math.sin(phi), cs = Math.cos(phi);
      hist.fill(0);
      for (let i = 0; i < n; i++) {
        const row = Math.floor(((pxs[i] - cx) * sn + (pys[i] - cy) * cs + cy + 0.5 + off) / 2);
        if (row >= 0 && row < size) hist[row]++;
      }
      let sum = 0;
      for (let i = Math.floor((off + 0.08 * gh) / 2); i <= Math.floor((off + 0.92 * gh) / 2); i++) {
        const d = hist[i] - hist[i + 1];
        sum += d * d;
      }
      return sum;
    }

    const baseScore = score(0);
    let bestDeg = 0, bestScore = baseScore;
    for (let deg = -maxDeg; deg <= maxDeg + 1e-9; deg += stepDeg) {
      if (Math.abs(deg) > 1e-9) {
        const sc = score(deg);
        if (sc > bestScore) { bestDeg = deg; bestScore = sc; }
      }
    }
    const fine = stepDeg / 4, center = bestDeg;
    for (let k = -3; k <= 3; k++) {
      const d = center + k * fine;
      if (k !== 0 && Math.abs(d) <= maxDeg) {
        const sc = score(d);
        if (sc > bestScore) { bestDeg = d; bestScore = sc; }
      }
    }
    if (bestScore < baseScore * 1.15) return 0;
    return bestDeg;
  }

  function rotateMask(mask, gw, gh, deg) {
    const phi = (deg * Math.PI) / 180;
    const sn = Math.sin(phi), cs = Math.cos(phi);
    const cx = gw / 2, cy = gh / 2;
    const out = new Uint8Array(gw * gh);
    for (let y = 0; y < gh; y++) {
      const dy = y - cy;
      for (let x = 0; x < gw; x++) {
        const dx = x - cx;
        const xs = Math.floor(dx * cs + dy * sn + cx + 0.5);
        const ys = Math.floor(-dx * sn + dy * cs + cy + 0.5);
        out[y * gw + x] = xs >= 0 && xs < gw && ys >= 0 && ys < gh ? mask[ys * gw + xs] : 0;
      }
    }
    return out;
  }

  function detectCore(planes, gw, gh, readingDir, opts) {
    const minGapX = Math.max(2, Math.floor(opt(opts, "gap_frac") * gw + 0.5));
    const minGapY = Math.max(2, Math.floor(opt(opts, "gap_frac") * gh + 0.5));
    const looseMinX = Math.max(3, Math.floor(opt(opts, "loose_gap_frac") * gw + 0.5));
    const looseMinY = Math.max(3, Math.floor(opt(opts, "loose_gap_frac") * gh + 0.5));
    const minLenX = Math.max(2, Math.floor(opt(opts, "min_segment_frac") * gw));
    const minLenY = Math.max(2, Math.floor(opt(opts, "min_segment_frac") * gh));
    const maxDepth = opt(opts, "max_depth");
    const marginX = Math.floor(opt(opts, "edge_margin_frac") * gw);
    const marginY = Math.floor(opt(opts, "edge_margin_frac") * gh);
    const rtl = readingDir === "rtl";

    const [bgr, bgg, bgb, noise] = estimateBackground(planes, gw, gh, opt(opts, "border_frac"));
    const tol = Math.min(opt(opts, "max_tolerance"), Math.max(opt(opts, "min_tolerance"), noise * 3 + 6));

    const palette = [[bgr, bgg, bgb]];
    const gc = estimateGutterColors(planes, gw, gh, marginX, marginY, Math.max(10, tol * 0.6), opt(opts, "loose_max_gap_frac"));
    for (const c of gc) {
      if (Math.max(Math.abs(c[0] - bgr), Math.abs(c[1] - bgg), Math.abs(c[2] - bgb)) > tol * 0.6) palette.push(c);
    }

    const mask = new Uint8Array(gw * gh);
    const { r: pr, g: pg, b: pb } = planes;
    for (let i = 0; i < gw * gh; i++) {
      let best = 1000;
      for (const c of palette) {
        const d = Math.max(Math.abs(pr[i] - c[0]), Math.abs(pg[i] - c[1]), Math.abs(pb[i] - c[2]));
        if (d < best) best = d;
      }
      mask[i] = best > tol ? 1 : 0;
    }

    function cut(m) {
      const panels = [];
      const levels = opt(opts, "noise_levels");
      const looseGapX = Math.floor(opt(opts, "loose_max_gap_frac") * gw);
      const looseGapY = Math.floor(opt(opts, "loose_max_gap_frac") * gh);

      function addLeaf(x0, y0, x1, y1) {
        const p = { x: x0 / gw, y: y0 / gh, w: (x1 - x0) / gw, h: (y1 - y0) / gh };
        if (p.w >= opt(opts, "min_panel_w") && p.h >= opt(opts, "min_panel_h") && p.w * p.h >= opt(opts, "min_panel_area")) {
          panels.push(p);
        }
      }

      function rowSegs(x0, y0, x1, y1, level) {
        const xa = x0 === 0 ? marginX : 0;
        const xb = x1 === gw ? marginX : 0;
        return findSegments(rowCounts(m, gw, x0, y0, x1, y1, xa, xb), y1 - y0, x1 - x0 - xa - xb,
          levels[level - 1], level > 1 ? looseMinY : minGapY, minLenY, level > 1 ? looseGapY : undefined);
      }
      function colSegs(x0, y0, x1, y1, level) {
        const ya = y0 === 0 ? marginY : 0;
        const yb = y1 === gh ? marginY : 0;
        return findSegments(colCounts(m, gw, x0, y0, x1, y1, ya, yb), x1 - x0, y1 - y0 - ya - yb,
          levels[level - 1], level > 1 ? looseMinX : minGapX, minLenX, level > 1 ? looseGapX : undefined);
      }

      function recurseY(x0, y0, x1, y1, segs, depth) {
        for (const s of segs) split(x0, y0 + s.s, x1, y0 + s.e, depth + 1);
      }
      function recurseX(x0, y0, x1, y1, segs, depth) {
        const order = rtl ? segs.slice().reverse() : segs;
        for (const s of order) split(x0 + s.s, y0, x0 + s.e, y1, depth + 1);
      }

      function split(x0, y0, x1, y1, depth) {
        if (x1 <= x0 || y1 <= y0) return;
        if (depth > maxDepth) { addLeaf(x0, y0, x1, y1); return; }

        const ys = rowSegs(x0, y0, x1, y1, 1);
        if (ys.length === 0) return;
        if (ys.length > 1) return recurseY(x0, y0, x1, y1, ys, depth);
        const ny0 = y0 + ys[0].s, ny1 = y0 + ys[0].e;

        const xs = colSegs(x0, ny0, x1, ny1, 1);
        if (xs.length === 0) return;
        if (xs.length > 1) return recurseX(x0, ny0, x1, ny1, xs, depth);
        const nx0 = x0 + xs[0].s, nx1 = x0 + xs[0].e;

        if (nx0 !== x0 || nx1 !== x1 || ny0 !== y0 || ny1 !== y1) {
          return split(nx0, ny0, nx1, ny1, depth + 1);
        }

        for (let level = 2; level <= levels.length; level++) {
          const lys = rowSegs(x0, y0, x1, y1, level);
          if (lys.length > 1) return recurseY(x0, y0, x1, y1, lys, depth);
          const lxs = colSegs(x0, y0, x1, y1, level);
          if (lxs.length > 1) return recurseX(x0, y0, x1, y1, lxs, depth);
        }
        addLeaf(x0, y0, x1, y1);
      }

      split(0, 0, gw, gh, 0);
      return panels;
    }

    let panels = cut(mask);

    const skew = estimateSkew(mask, gw, gh, opt(opts, "max_skew_deg"), opt(opts, "skew_step_deg"));
    if (skew !== 0) {
      const rotated = cut(rotateMask(mask, gw, gh, skew));
      if (rotated.length > panels.length) {
        const phi = (skew * Math.PI) / 180;
        const sn = Math.sin(phi), cs = Math.cos(phi);
        const cx = gw / 2, cy = gh / 2;
        panels = rotated.map((p) => {
          let minx = 1e9, miny = 1e9, maxx = -1e9, maxy = -1e9;
          for (const c of [[p.x, p.y], [p.x + p.w, p.y], [p.x, p.y + p.h], [p.x + p.w, p.y + p.h]]) {
            const dx = c[0] * gw - cx, dy = c[1] * gh - cy;
            const xs = dx * cs + dy * sn + cx;
            const ys = -dx * sn + dy * cs + cy;
            minx = Math.min(minx, xs); maxx = Math.max(maxx, xs);
            miny = Math.min(miny, ys); maxy = Math.max(maxy, ys);
          }
          minx = Math.max(0, minx); miny = Math.max(0, miny);
          maxx = Math.min(gw, maxx); maxy = Math.min(gh, maxy);
          return { x: minx / gw, y: miny / gh, w: (maxx - minx) / gw, h: (maxy - miny) / gh };
        });
      }
    }
    return panels;
  }

  function detect(planes, gw, gh, readingDir, opts) {
    if (!(opts && opts.no_crop)) {
      const bounds = findPageBounds(planes, gw, gh, opts);
      if (bounds) {
        const [x0, y0, x1, y1] = bounds;
        if (x0 > 0.015 * gw || y0 > 0.015 * gh || gw - x1 > 0.015 * gw || gh - y1 > 0.015 * gh) {
          const cw = x1 - x0, ch = y1 - y0;
          const sub = { r: new Uint8Array(cw * ch), g: new Uint8Array(cw * ch), b: new Uint8Array(cw * ch) };
          for (const k of ["r", "g", "b"]) {
            for (let y = 0; y < ch; y++) {
              const sb = (y + y0) * gw + x0, db = y * cw;
              for (let x = 0; x < cw; x++) sub[k][db + x] = planes[k][sb + x];
            }
          }
          const [bgr, bgg, bgb] = estimateBackground(planes, gw, gh, opt(opts, "border_frac"));
          let same = 0, total = 0;
          for (let i = 0; i < cw * ch; i += 3) {
            total++;
            if (Math.abs(sub.r[i] - bgr) <= 14 && Math.abs(sub.g[i] - bgg) <= 14 && Math.abs(sub.b[i] - bgb) <= 14) same++;
          }
          if (same / total > 0.04) return detectCore(planes, gw, gh, readingDir, opts);
          const subOpts = Object.assign({}, opts || {}, { no_crop: true });
          const found = detect(sub, cw, ch, readingDir, subOpts);
          for (const p of found) {
            p.x = (x0 + p.x * cw) / gw; p.y = (y0 + p.y * ch) / gh;
            p.w = (p.w * cw) / gw; p.h = (p.h * ch) / gh;
          }
          return found;
        }
      }
    }
    return detectCore(planes, gw, gh, readingDir, opts);
  }

  root.PanelDetector = { detect };
})(typeof window !== "undefined" ? window : globalThis);
