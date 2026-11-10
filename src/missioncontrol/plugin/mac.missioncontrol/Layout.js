.pragma library

// Where each window goes in the overview.
//
// The model is the one Mission Control shows: the screen zooms out and the
// windows that overlap are pushed apart until none does. A window keeps its
// place relative to the others and all windows share one scale, so the big
// one stays the big one and the one in the top-right corner stays there.
//
// spread() is the "natural" layout that KWin's Present Windows has used since
// 2008 (calculateWindowTransformationsNatural), written to imitate Exposé: the
// bounding box starts as the screen, every overlapping pair is nudged apart a
// step at a time, and windows near an edge are pulled toward a corner so the
// box keeps the screen's shape. Whatever the box has grown to is then scaled
// back into the area the overview has.
//
// It can lose to a long diagonal cascade, where pushing along the line
// between two centres only ever makes the line longer. rows() packs the
// windows into rows by where they are (the GNOME overview's strategy) and
// arrange() takes it instead whenever spreading came out clearly smaller.

var STEP = 20          // px a pair is pushed apart per pass
var MAX_PASSES = 3000
var ROWS_WIN_BY = 1.1  // rows() replaces spread() when its windows are this much larger

function union(a, b) {
  var x = Math.min(a.x, b.x), y = Math.min(a.y, b.y)
  return { x: x, y: y, w: Math.max(a.x + a.w, b.x + b.w) - x, h: Math.max(a.y + a.h, b.y + b.h) - y }
}

function overlaps(a, b, m) {
  return a.x - m < b.x + b.w + m && b.x - m < a.x + a.w + m
      && a.y - m < b.y + b.h + m && b.y - m < a.y + a.h + m
}

// frames: [{x, y, w, h}] in screen coordinates; margin: half the gap wanted
// between two windows, in the same (unscaled) pixels.
// Returns { rects, bounds }: where the windows are once nothing overlaps, and
// the box around the screen and all of them.
function spread(frames, screen, margin) {
  var n = frames.length
  var r = []
  var bounds = { x: screen.x, y: screen.y, w: screen.w, h: screen.h }
  for (var i = 0; i < n; i++) {
    r.push({ x: frames[i].x, y: frames[i].y, w: frames[i].w, h: frames[i].h })
    bounds = union(bounds, r[i])
  }

  var overlap = true
  for (var pass = 0; overlap && pass < MAX_PASSES; pass++) {
    overlap = false
    for (var a = 0; a < n; a++) {
      for (var b = 0; b < n; b++) {
        if (a === b || !overlaps(r[a], r[b], margin)) continue
        overlap = true
        var w = r[a], e = r[b]

        // Push the two apart along the line between their centres.
        var dx = (e.x + e.w / 2) - (w.x + w.w / 2)
        var dy = (e.y + e.h / 2) - (w.y + w.h / 2)
        if (dx === 0 && dy === 0) dx = 1
        var k = STEP / (Math.abs(dx) + Math.abs(dy))
        dx *= k; dy *= k
        w.x -= dx; w.y -= dy
        e.x += dx; e.y += dy

        // Keep the box the screen's shape: split it in nine, pull a window in
        // a corner section toward that corner, and one in an edge section
        // toward one of that edge's two corners (by index, so the result is
        // the same every time).
        var xs = Math.floor((w.x - bounds.x) / (bounds.w / 3))
        var ys = Math.floor((w.y - bounds.y) / (bounds.h / 3))
        if (xs !== 1 || ys !== 1) {
          if (xs === 1) xs = (a % 4) >= 2 ? 2 : 0
          if (ys === 1) ys = (a % 2) ? 2 : 0
        }
        var cx = w.x + w.w / 2, cy = w.y + w.h / 2
        var px = 0, py = 0
        if (xs <= 0 && ys <= 0) { px = bounds.x - cx; py = bounds.y - cy }
        else if (xs >= 2 && ys <= 0) { px = bounds.x + bounds.w - cx; py = bounds.y - cy }
        else if (xs >= 2 && ys >= 2) { px = bounds.x + bounds.w - cx; py = bounds.y + bounds.h - cy }
        else if (xs <= 0 && ys >= 2) { px = bounds.x - cx; py = bounds.y + bounds.h - cy }
        if (px !== 0 || py !== 0) {
          k = STEP / (Math.abs(px) + Math.abs(py))
          w.x += px * k; w.y += py * k
        }

        bounds = union(union(bounds, w), e)
      }
    }
  }
  return { rects: r, bounds: bounds }
}

// The spread windows scaled into `area`. Two rounds: the gap is wanted in
// pixels on screen, and how many unscaled pixels that is depends on the scale.
function natural(frames, screen, area, gap, maxScale) {
  var scale = Math.min(area.w / screen.w, area.h / screen.h, maxScale)
  var out = null
  for (var round = 0; round < 3; round++) {
    var res = spread(frames, screen, gap / 2 / scale)
    var b = res.bounds
    var s = Math.min(area.w / b.w, area.h / b.h, maxScale)
    var ox = area.x + (area.w - b.w * s) / 2
    var oy = area.y + (area.h - b.h * s) / 2
    out = { scale: s, slots: [] }
    for (var i = 0; i < frames.length; i++)
      out.slots.push({ x: ox + (res.rects[i].x - b.x) * s, y: oy + (res.rects[i].y - b.y) * s, s: s })
    if (Math.abs(s - scale) < 0.02 * scale) break
    scale = s
  }
  return out
}

// Spreading leaves air: pairs part in whole steps and the box only ever
// grows. grow() takes the spread windows where they are and finds the largest
// common scale at which they still fit, letting neighbours shove each other
// (along the axis they overlap least on) inside the area.
function settle(frames, centers, s, area, gap) {
  var n = frames.length
  var r = []
  for (var i = 0; i < n; i++)
    r.push({ cx: centers[i].cx, cy: centers[i].cy, w: frames[i].w * s, h: frames[i].h * s })

  function clamp(q) {
    if (q.w >= area.w) q.cx = area.x + area.w / 2
    else q.cx = Math.max(area.x + q.w / 2, Math.min(area.x + area.w - q.w / 2, q.cx))
    if (q.h >= area.h) q.cy = area.y + area.h / 2
    else q.cy = Math.max(area.y + q.h / 2, Math.min(area.y + area.h - q.h / 2, q.cy))
  }

  for (i = 0; i < n; i++) {
    if (r[i].w > area.w || r[i].h > area.h) return null
    clamp(r[i])
  }
  for (var pass = 0; pass < 250; pass++) {
    var moved = false
    for (var a = 0; a < n; a++) {
      for (var b = a + 1; b < n; b++) {
        var p = r[a], q = r[b]
        var dx = q.cx - p.cx, dy = q.cy - p.cy
        var ox = (p.w + q.w) / 2 + gap - Math.abs(dx)
        var oy = (p.h + q.h) / 2 + gap - Math.abs(dy)
        if (ox <= 0.5 || oy <= 0.5) continue
        moved = true
        if (ox < oy) {
          var sx = dx < 0 ? -1 : 1
          p.cx -= sx * ox / 2; q.cx += sx * ox / 2
        } else {
          var sy = dy < 0 ? -1 : 1
          p.cy -= sy * oy / 2; q.cy += sy * oy / 2
        }
        clamp(p); clamp(q)
      }
    }
    if (!moved) return r
  }
  return null
}

function grow(frames, layout, area, gap, maxScale) {
  var n = frames.length
  var centers = []
  for (var i = 0; i < n; i++)
    centers.push({ cx: layout.slots[i].x + frames[i].w * layout.scale / 2,
                   cy: layout.slots[i].y + frames[i].h * layout.scale / 2 })
  var lo = layout.scale, hi = Math.min(maxScale, layout.scale * 2), best = null
  for (var round = 0; round < 9 && hi - lo > 0.004; round++) {
    var mid = round === 0 ? hi : (lo + hi) / 2
    var r = settle(frames, best ? best.centers : centers, mid, area, gap)
    if (r) {
      best = { scale: mid, centers: r.map(function(q) { return { cx: q.cx, cy: q.cy } }) }
      lo = mid
      if (round === 0) break
    } else {
      hi = mid
    }
  }
  if (!best) return layout
  var out = { scale: best.scale, slots: [] }
  for (i = 0; i < n; i++)
    out.slots.push({ x: best.centers[i].cx - frames[i].w * best.scale / 2,
                     y: best.centers[i].cy - frames[i].h * best.scale / 2, s: best.scale })
  return out
}

// Rows: windows sorted top to bottom fill `count` rows of about equal width,
// each row then runs left to right. One scale for all.
function rowsOf(frames, count) {
  var order = []
  var total = 0
  for (var i = 0; i < frames.length; i++) { order.push(i); total += frames[i].w }
  order.sort(function(p, q) {
    return (frames[p].y + frames[p].h / 2) - (frames[q].y + frames[q].h / 2) || p - q
  })
  var ideal = total / count
  var rows = []
  var at = 0
  for (var row = 0; row < count && at < order.length; row++) {
    var items = [], width = 0, height = 0
    for (; at < order.length; at++) {
      var f = frames[order[at]]
      var keep = row === count - 1 || items.length === 0 || width + f.w <= ideal
          || Math.abs(1 - (width + f.w) / ideal) < Math.abs(1 - width / ideal)
      if (!keep) break
      items.push(order[at]); width += f.w; height = Math.max(height, f.h)
    }
    items.sort(function(p, q) {
      return (frames[p].x + frames[p].w / 2) - (frames[q].x + frames[q].w / 2) || p - q
    })
    rows.push({ items: items, w: width, h: height })
  }
  return rows
}

function rows(frames, area, gap, maxScale) {
  var best = null
  for (var count = 1; count <= frames.length; count++) {
    var list = rowsOf(frames, count)
    var widest = 0, tall = 0, most = 0
    for (var i = 0; i < list.length; i++) {
      widest = Math.max(widest, list[i].w); tall += list[i].h; most = Math.max(most, list[i].items.length)
    }
    var s = Math.min((area.w - (most - 1) * gap) / widest, (area.h - (list.length - 1) * gap) / tall, maxScale)
    if (s <= 0) continue
    if (!best || s > best.scale * 1.02) best = { scale: s, rows: list, tall: tall }
  }
  if (!best) return null

  var out = { scale: best.scale, slots: [] }
  var s2 = best.scale
  var y = area.y + (area.h - (best.tall * s2 + (best.rows.length - 1) * gap)) / 2
  for (var r = 0; r < best.rows.length; r++) {
    var row = best.rows[r]
    var x = area.x + (area.w - (row.w * s2 + (row.items.length - 1) * gap)) / 2
    for (var c = 0; c < row.items.length; c++) {
      var f = frames[row.items[c]]
      out.slots[row.items[c]] = { x: x, y: y + (row.h - f.h) * s2 / 2, s: s2 }
      x += f.w * s2 + gap
    }
    y += row.h * s2 + gap
  }
  return out
}

// frames in screen coordinates -> [{x, y, s}] (top-left corner and scale), in
// the same order.
function arrange(frames, screen, area, gap, maxScale) {
  if (frames.length === 0) return []
  var a = natural(frames, screen, area, gap, maxScale)
  a = grow(frames, a, area, gap, maxScale)
  if (frames.length > 2) {
    var b = rows(frames, area, gap, maxScale)
    if (b && b.scale > a.scale * ROWS_WIN_BY) return b.slots
  }
  return frames.length > 1 ? centred(frames, a.slots, area) : a.slots
}

// Windows that had to move end up as a group; put the group in the middle.
// (A window on its own stays where zooming out left it.)
function centred(frames, slots, area) {
  var box = null
  for (var i = 0; i < slots.length; i++) {
    var r = { x: slots[i].x, y: slots[i].y, w: frames[i].w * slots[i].s, h: frames[i].h * slots[i].s }
    box = box ? union(box, r) : r
  }
  var dx = area.x + (area.w - box.w) / 2 - box.x
  var dy = area.y + (area.h - box.h) / 2 - box.y
  for (i = 0; i < slots.length; i++) { slots[i].x += dx; slots[i].y += dy }
  return slots
}
