// Bullwhip shared renderer + drivers.
//
// One canvas scene — the supply chain as a conveyor: customers on the left,
// then Retailer, Wholesaler, Distributor, Factory stations, and the
// factory's production line on the right. Each station shows its cog, its
// inventory as stacked crates, its backlog as red crates, the order slip it
// just wrote flying upstream, and its last message as a speech bubble. The
// belts between stations carry the in-transit shipments. Under the chain a
// seismograph strip charts every stage's orders against customer demand —
// the bullwhip, drawn.
//
// Fed by three drivers: live /global websocket, live /player websocket,
// and replay (from the game's /replay websocket or the static wasm
// bundle). All state derivation happens server-side / wasm-side; this file
// only draws state objects:
//   {seats:[{name,stage,role,score,cost,inventory,backlog,received,incoming,
//            shipped,shipPipe[2],costWeek,costTotal,lastOrder,order|null,
//            say,heard[],notes,pending} ×4 by SEAT],
//    stageSeat[4], week, weeks, weeksPlayed, demand[], orders[4][] by stage,
//    phase:"orders|done", gameDone, reason}
(function () {
  "use strict";

  // Ink & Print palette, matching the coworld-ctf broadcast chrome. Seats
  // are red, blue, green, yellow; stations are laid out by STAGE but
  // coloured by SEAT, so a seat keeps its colour across episodes.
  var COLORS = ["red", "blue", "green", "yellow", "violet", "orange"];
  var COLOR_HEX = {
    red: "#e0523a",
    blue: "#3f7cc4",
    green: "#45a85e",
    yellow: "#ddc531",
    violet: "#a86fd6",
    orange: "#e08a3a"
  };
  var PAPER = "#f2e8d8";
  var PAPER_DIM = "#b8ac98";
  var INK = "#2a1f16";
  var AMBER = "#e8a33d";
  var GHOST = "#8a7f72";
  var CRATE = "#c9a46a";
  var CRATE_EDGE = "#6b4c22";
  var BACKLOG = "#e0523a";
  var BACKLOG_EDGE = "#7a2414";
  var BELT = "#3a2d22";
  var STRIP = "rgba(242, 232, 216, 0.06)";
  var ROLES = ["Retailer", "Wholesaler", "Distributor", "Factory"];
  // Timing of the week transition: crates slide one belt slot, order slips
  // fly upstream, speech bubbles pop.
  var SLIDE_MS = 700;
  var SLIP_MS = 900;
  var BUBBLE_HOLD_MS = 6000;
  var MAX_CRATES = 30;

  function assetUrl(base, name) {
    return base.replace(/\/$/, "") + "/" + name;
  }

  function loadImages(base, names, done) {
    var images = {};
    var pending = names.length;
    names.forEach(function (name) {
      var img = new Image();
      img.onload = img.onerror = function () {
        pending -= 1;
        if (pending === 0) done(images);
      };
      img.src = assetUrl(base, name);
      images[name] = img;
    });
  }

  function seatColor(index) {
    return COLORS[index % COLORS.length];
  }

  function makeRenderer(canvas, assetBase, onReady) {
    var ctx = canvas.getContext("2d");
    var names = ["soldier_red_front.png", "soldier_blue_front.png",
      "soldier_green_front.png", "soldier_yellow_front.png",
      "arena_floor.png"];
    loadImages(assetBase, names, function (images) {
      onReady({
        draw: function (view) { draw(ctx, canvas, images, view); }
      });
    });
  }

  function ellipsize(ctx, text, maxWidth) {
    if (ctx.measureText(text).width <= maxWidth) return text;
    var cut = text;
    while (cut.length > 1 && ctx.measureText(cut + "…").width > maxWidth) {
      cut = cut.slice(0, -1);
    }
    return cut + "…";
  }

  function hexToRgb(hex) {
    var n = parseInt(hex.slice(1), 16);
    return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
  }
  function rgba(hex, alpha) {
    var c = hexToRgb(hex);
    return "rgba(" + c[0] + "," + c[1] + "," + c[2] + "," + alpha + ")";
  }

  function money(value) {
    return "$" + (Math.round((value || 0) * 10) / 10).toFixed(1);
  }

  function roundRect(ctx, x, y, w, h, r) {
    ctx.beginPath();
    ctx.moveTo(x + r, y);
    ctx.arcTo(x + w, y, x + w, y + h, r);
    ctx.arcTo(x + w, y + h, x, y + h, r);
    ctx.arcTo(x, y + h, x, y, r);
    ctx.arcTo(x, y, x + w, y, r);
    ctx.closePath();
  }

  // ---- Layout --------------------------------------------------------------

  // Six columns: customers, four stations, production. The belt between
  // neighbouring columns carries two shipment slots. The chart takes the
  // bottom of the canvas. Everything is measured from the station pitch so
  // the scene scales to whatever frame the viewer is embedded in.
  function computeLayout(width, height) {
    var margin = 10;
    var chartH = Math.max(90, Math.min(height * 0.34, 200));
    var chainTop = margin;
    var chainH = height - chartH - margin * 2;
    var pitch = (width - 2 * margin) / 6;
    var size = Math.max(28, Math.min(84, pitch * 0.42, chainH * 0.26));
    var scale = size / 84;
    var cogY = chainTop + chainH * 0.36;
    var beltY = chainTop + chainH * 0.58;
    var beltH = Math.max(14, size * 0.28);
    var dockY = beltY + beltH + 6 * scale;
    var columns = [];
    for (var c = 0; c < 6; c++) {
      columns.push({ x: margin + pitch * (c + 0.5) });
    }
    return {
      width: width, height: height, size: size, scale: scale, pitch: pitch,
      chainTop: chainTop, chainH: chainH, cogY: cogY, beltY: beltY,
      beltH: beltH, dockY: dockY, dockH: chainTop + chainH - dockY,
      columns: columns,
      chart: { x: margin, y: height - chartH - margin, w: width - 2 * margin,
        h: chartH }
    };
  }

  // ---- Drawing -------------------------------------------------------------

  function draw(ctx, canvas, images, view) {
    var w = canvas.width;
    var h = canvas.height;
    var seats = view.seats || [];
    var stageSeat = view.stageSeat || [0, 1, 2, 3];
    var now = view.now || Date.now();
    var L = computeLayout(w, h);
    var scale = L.scale;
    var fx = view.effects || {};

    // Floor.
    var floor = images["arena_floor.png"];
    if (floor && floor.width) {
      ctx.fillStyle = ctx.createPattern(floor, "repeat");
    } else {
      ctx.fillStyle = "#16110d";
    }
    ctx.fillRect(0, 0, w, h);
    ctx.fillStyle = "rgba(18, 13, 9, 0.45)";
    ctx.fillRect(0, 0, w, h);

    // Chain plate.
    ctx.save();
    ctx.fillStyle = STRIP;
    roundRect(ctx, 4, L.chainTop, w - 8, L.chainH, 10 * scale);
    ctx.fill();
    ctx.restore();

    var slide = typeof fx.weekAt === "number" ?
      Math.min(1, (now - fx.weekAt) / SLIDE_MS) : 1;
    var eased = 1 - Math.pow(1 - slide, 3);

    // Belts: customers<-R, R<-W, W<-D, D<-F, F<-production.
    for (var b = 0; b < 5; b++) {
      drawBelt(ctx, L, b, scale);
    }

    // Shipments in transit. Belt b runs between columns b and b+1; the
    // pipeline INTO stage s rides belt s+1 (slot [1] upstream, slot [0]
    // downstream); belt 4 feeds the factory from production and belt 0
    // carries the retailer's deliveries off to the customers.
    // During a week transition crates slide one slot downstream.
    for (var stage = 0; stage < 4; stage++) {
      var seat = seats[stageSeat[stage]];
      if (!seat) continue;
      var pipe = seat.shipPipe || [0, 0];
      drawShipment(ctx, L, stage, 0, pipe[0], eased, scale);
      drawShipment(ctx, L, stage, 1, pipe[1], eased, scale);
    }
    // What the retailer just shipped rolls off to the customers.
    var retailer = seats[stageSeat[0]];
    if (retailer) {
      drawCustomerDelivery(ctx, L, retailer.shipped || 0, eased, scale);
    }

    // Customers and production bookends.
    var demand = view.demand || [];
    drawCustomers(ctx, L, demand.length ? demand[demand.length - 1] : null,
      scale);
    drawProduction(ctx, L, scale);

    // Lowest cost leads once the table is settled.
    var best = Infinity;
    var level = true;
    seats.forEach(function (seat) { if (seat.cost < best) best = seat.cost; });
    seats.forEach(function (seat) { if (seat.cost !== best) level = false; });

    // Stations.
    for (var s = 0; s < 4; s++) {
      var seatIndex = stageSeat[s];
      var station = seats[seatIndex];
      if (!station) continue;
      drawStation(ctx, images, L, s, seatIndex, station, scale, {
        pending: station.pending && !view.done,
        leads: view.done && !level && station.cost === best,
        orderAt: fx.orderAt ? fx.orderAt[s] : null,
        sayAt: fx.sayAt ? fx.sayAt[s] : null,
        say: fx.lastSay ? fx.lastSay[s] : "",
        now: now
      });
    }

    // Seismograph.
    drawChart(ctx, L.chart, view, stageSeat, scale);
  }

  function drawBelt(ctx, L, index, scale) {
    var x0 = L.columns[index].x;
    var x1 = L.columns[index + 1].x;
    var y = L.beltY;
    ctx.save();
    ctx.fillStyle = BELT;
    roundRect(ctx, x0, y, x1 - x0, L.beltH, 3 * scale);
    ctx.fill();
    // Rollers.
    ctx.strokeStyle = "rgba(242, 232, 216, 0.10)";
    ctx.lineWidth = 1;
    var step = 10 * scale;
    for (var x = x0 + step; x < x1; x += step) {
      ctx.beginPath();
      ctx.moveTo(x, y + 2);
      ctx.lineTo(x, y + L.beltH - 2);
      ctx.stroke();
    }
    // Direction arrow (downstream = left).
    ctx.fillStyle = "rgba(242, 232, 216, 0.22)";
    var ax = (x0 + x1) / 2;
    var ay = y + L.beltH + 7 * scale;
    ctx.beginPath();
    ctx.moveTo(ax - 9 * scale, ay);
    ctx.lineTo(ax - 3 * scale, ay - 4 * scale);
    ctx.lineTo(ax - 3 * scale, ay + 4 * scale);
    ctx.closePath();
    ctx.fill();
    ctx.fillRect(ax - 3 * scale, ay - 1, 12 * scale, 2);
    ctx.restore();
  }

  // Slot positions along belt b: slot 1 at 70% of the way upstream, slot 0
  // at 30%. A sliding crate moves from slot k+1's position to slot k's.
  function slotX(L, belt, slot) {
    var x0 = L.columns[belt].x;
    var x1 = L.columns[belt + 1].x;
    return x0 + (x1 - x0) * (slot === 0 ? 0.32 : 0.68);
  }

  function drawShipment(ctx, L, stage, slot, units, eased, scale) {
    if (!units) return;
    // Column 0 is the customers, so the belt into stage `stage` (from the
    // column upstream of it) is belt `stage + 1`.
    var belt = stage + 1;
    var from = slot === 0 ? slotX(L, belt, 1) : L.columns[belt + 1].x;
    var to = slotX(L, belt, slot);
    var x = from + (to - from) * eased;
    drawCrateCluster(ctx, x, L.beltY + L.beltH / 2, units, scale, CRATE,
      CRATE_EDGE, true);
  }

  function drawCustomerDelivery(ctx, L, units, eased, scale) {
    if (!units) return;
    var from = L.columns[1].x;
    var to = L.columns[0].x + L.pitch * 0.32;
    var x = from + (to - from) * eased;
    ctx.save();
    ctx.globalAlpha = 0.55 + 0.45 * (1 - eased);
    drawCrateCluster(ctx, x, L.beltY + L.beltH / 2, units, scale, CRATE,
      CRATE_EDGE, true);
    ctx.restore();
  }

  // A compact crate cluster on the belt: up to 12 crates in rows of 4,
  // with the quantity printed on a tag.
  function drawCrateCluster(ctx, cx, cy, units, scale, fill, edge, tag) {
    var n = Math.min(12, Math.max(1, Math.ceil(units / 4)));
    var cs = 9 * scale;
    var cols = Math.min(4, n);
    var rows = Math.ceil(n / cols);
    var x0 = cx - cols * cs / 2;
    var y0 = cy + rows * cs / 2 - cs;
    ctx.save();
    for (var i = 0; i < n; i++) {
      var cxi = x0 + (i % cols) * cs;
      var cyi = y0 - Math.floor(i / cols) * cs;
      drawCrate(ctx, cxi, cyi, cs - 1, fill, edge);
    }
    if (tag) {
      ctx.font = "700 " + Math.round(13 * scale) +
        "px 'rajdhani', system-ui, sans-serif";
      ctx.textAlign = "center";
      ctx.textBaseline = "bottom";
      ctx.fillStyle = PAPER;
      ctx.shadowColor = "rgba(0,0,0,0.9)";
      ctx.shadowBlur = 3;
      ctx.fillText(String(units), cx, y0 - rows * cs + cs - 3 * scale);
    }
    ctx.restore();
  }

  function drawCrate(ctx, x, y, s, fill, edge) {
    ctx.fillStyle = fill;
    ctx.fillRect(x, y, s, s);
    ctx.strokeStyle = edge;
    ctx.lineWidth = 1;
    ctx.strokeRect(x + 0.5, y + 0.5, s - 1, s - 1);
    // Plank line.
    ctx.beginPath();
    ctx.moveTo(x + 1, y + s / 2);
    ctx.lineTo(x + s - 1, y + s / 2);
    ctx.stroke();
  }

  function drawCustomers(ctx, L, demand, scale) {
    var x = L.columns[0].x;
    ctx.save();
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    ctx.font = "700 " + Math.round(11 * scale) +
      "px 'rajdhani', system-ui, sans-serif";
    ctx.fillStyle = PAPER_DIM;
    ctx.fillText("CUSTOMERS", x, L.cogY - L.size * 0.55);
    // A little crowd: three paper silhouettes.
    for (var i = -1; i <= 1; i++) {
      var px = x + i * 14 * scale;
      var py = L.cogY + (i === 0 ? -4 : 2) * scale;
      ctx.fillStyle = i === 0 ? PAPER : PAPER_DIM;
      ctx.beginPath();
      ctx.arc(px, py - 9 * scale, 5 * scale, 0, Math.PI * 2);
      ctx.fill();
      roundRect(ctx, px - 7 * scale, py - 3 * scale, 14 * scale, 16 * scale,
        4 * scale);
      ctx.fill();
    }
    ctx.font = "700 " + Math.round(13 * scale) +
      "px 'rajdhani', system-ui, sans-serif";
    ctx.fillStyle = AMBER;
    ctx.fillText(demand === null || demand === undefined ? "demand ?" :
      "want " + demand + " / wk", x, L.cogY + L.size * 0.5);
    ctx.restore();
  }

  function drawProduction(ctx, L, scale) {
    var x = L.columns[5].x;
    ctx.save();
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    ctx.font = "700 " + Math.round(11 * scale) +
      "px 'rajdhani', system-ui, sans-serif";
    ctx.fillStyle = PAPER_DIM;
    ctx.fillText("PRODUCTION", x, L.cogY - L.size * 0.55);
    // A gear.
    var r = 14 * scale;
    ctx.fillStyle = PAPER_DIM;
    ctx.beginPath();
    for (var i = 0; i < 16; i++) {
      var a = i * Math.PI / 8;
      var rr = i % 2 ? r : r * 0.78;
      var px = x + Math.cos(a) * rr;
      var py = L.cogY + Math.sin(a) * rr;
      if (i === 0) ctx.moveTo(px, py); else ctx.lineTo(px, py);
    }
    ctx.closePath();
    ctx.fill();
    ctx.fillStyle = "#16110d";
    ctx.beginPath();
    ctx.arc(x, L.cogY, r * 0.35, 0, Math.PI * 2);
    ctx.fill();
    ctx.font = "600 " + Math.round(9 * scale) +
      "px 'rajdhani', system-ui, sans-serif";
    ctx.fillStyle = GHOST;
    ctx.fillText("2-WEEK LEAD", x, L.cogY + L.size * 0.5);
    ctx.restore();
  }

  function drawStation(ctx, images, L, stage, seatIndex, seat, scale, opts) {
    var col = L.columns[stage + 1];
    var x = col.x;
    var size = L.size;
    var color = seatColor(seatIndex);
    var sprite = images["soldier_" + color + "_front.png"];

    // Role tag over the cog; LEADS once it is over.
    drawTag(ctx, x, L.cogY - size * 0.62,
      opts.leads ? "LEADS" : ROLES[stage].toUpperCase(),
      opts.leads ? AMBER : COLOR_HEX[color], scale);

    ctx.save();
    ctx.translate(x, L.cogY);
    if (sprite && sprite.width) {
      ctx.imageSmoothingEnabled = false;
      ctx.drawImage(sprite, -size / 2, -size / 2, size, size);
    } else {
      ctx.fillStyle = COLOR_HEX[color];
      ctx.fillRect(-size / 3, -size / 3, size / 1.5, size / 1.5);
    }
    ctx.restore();

    // Acting halo while the table waits on this seat.
    if (opts.pending) {
      ctx.save();
      ctx.strokeStyle = AMBER;
      ctx.lineWidth = 3;
      ctx.setLineDash([6, 5]);
      ctx.beginPath();
      ctx.arc(x, L.cogY, size * 0.6, 0, Math.PI * 2);
      ctx.stroke();
      ctx.restore();
    }

    // Name and cost.
    ctx.save();
    ctx.textAlign = "center";
    ctx.textBaseline = "alphabetic";
    ctx.font = "600 " + Math.round(13 * scale) +
      "px 'rajdhani', system-ui, sans-serif";
    ctx.fillStyle = PAPER;
    ctx.shadowColor = "rgba(0,0,0,0.8)";
    ctx.shadowBlur = 4;
    ctx.fillText(ellipsize(ctx, seat.name || "", L.pitch * 0.9), x,
      L.cogY + size * 0.62 + 12 * scale);
    ctx.font = "700 " + Math.round(13 * scale) +
      "px 'rajdhani', system-ui, sans-serif";
    ctx.fillStyle = AMBER;
    ctx.fillText(money(seat.cost) + " cost", x,
      L.cogY + size * 0.62 + 27 * scale);
    ctx.restore();

    // Dock: inventory crates (paper) and backlog crates (red) stacked
    // under the station, with the numbers printed large.
    var dockW = L.pitch * 0.84;
    drawDock(ctx, x - dockW / 2, L.dockY, dockW, L.dockH, seat, scale);

    // Order slip: the number the seat wrote, flying upstream along the
    // belt into the next column. Rests at the upstream edge once landed.
    if (typeof seat.order === "number") {
      var age = typeof opts.orderAt === "number" ? opts.now - opts.orderAt :
        SLIP_MS;
      var t = Math.min(1, age / SLIP_MS);
      var e = 1 - Math.pow(1 - t, 2);
      var sx = x + (L.pitch * 0.72) * e;
      var sy = L.beltY - 12 * scale - Math.sin(e * Math.PI) * 18 * scale;
      drawSlip(ctx, sx, sy, "ORDER " + seat.order, scale, COLOR_HEX[color]);
    }

    // Speech bubble above the role tag.
    if (opts.say) {
      var sayAge = typeof opts.sayAt === "number" ? opts.now - opts.sayAt :
        BUBBLE_HOLD_MS;
      var alpha = sayAge < BUBBLE_HOLD_MS ? 1 :
        Math.max(0.45, 1 - (sayAge - BUBBLE_HOLD_MS) / 4000);
      drawBubble(ctx, x, L.cogY - size * 0.62 - 14 * scale, opts.say,
        L.pitch * 1.3, scale, alpha);
    }
  }

  function drawDock(ctx, x, y, w, h, seat, scale) {
    // Crates big enough to count: five per row, rows filling the dock.
    var cs = Math.max(6, Math.min(16 * scale, (w / 2 - 8) / 5, (h - 18) / 6));
    var half = w / 2;
    // Inventory: up to MAX_CRATES crates, 6 per row, bottom up.
    drawStack(ctx, x + 4, y, half - 8, h, seat.inventory || 0, cs, CRATE,
      CRATE_EDGE, "STOCK", PAPER);
    drawStack(ctx, x + half + 4, y, half - 8, h, seat.backlog || 0, cs,
      BACKLOG, BACKLOG_EDGE, "BACKLOG", BACKLOG);
  }

  function drawStack(ctx, x, y, w, h, units, cs, fill, edge, label, labelColor) {
    var cols = Math.max(1, Math.floor(w / cs));
    var shown = Math.min(MAX_CRATES, units);
    var perCrate = units > MAX_CRATES ? Math.ceil(units / MAX_CRATES) : 1;
    if (perCrate > 1) shown = Math.ceil(units / perCrate);
    var rows = Math.ceil(shown / cols);
    var baseY = y + h - 14;
    ctx.save();
    for (var i = 0; i < shown; i++) {
      var cx = x + (i % cols) * cs;
      var cy = baseY - Math.floor(i / cols) * cs - cs;
      drawCrate(ctx, cx, cy, cs - 1, fill, edge);
    }
    ctx.font = "700 " + Math.round(Math.max(13, 1.4 * cs)) +
      "px 'rajdhani', system-ui, sans-serif";
    ctx.textAlign = "left";
    ctx.textBaseline = "alphabetic";
    ctx.fillStyle = units > 0 ? labelColor : GHOST;
    ctx.shadowColor = "rgba(0,0,0,0.9)";
    ctx.shadowBlur = 3;
    ctx.fillText(String(units), x, y + h - 2);
    ctx.font = "600 " + Math.round(Math.max(8, 0.7 * cs)) +
      "px 'rajdhani', system-ui, sans-serif";
    ctx.fillStyle = GHOST;
    var numW = ctx.measureText(String(units)).width;
    ctx.fillText(label + (perCrate > 1 ? " (×" + perCrate + ")" : ""),
      x + numW + 18, y + h - 2);
    ctx.restore();
    void rows;
  }

  function drawSlip(ctx, x, y, text, scale, accent) {
    ctx.save();
    ctx.font = "700 " + Math.round(10 * scale) +
      "px 'rajdhani', system-ui, sans-serif";
    var pad = 5 * scale;
    var bw = ctx.measureText(text).width + pad * 2;
    var bh = 15 * scale;
    ctx.shadowColor = "rgba(0,0,0,0.6)";
    ctx.shadowBlur = 4;
    ctx.fillStyle = PAPER;
    ctx.fillRect(x - bw / 2, y - bh / 2, bw, bh);
    ctx.shadowColor = "transparent";
    ctx.strokeStyle = accent;
    ctx.lineWidth = 1.5;
    ctx.strokeRect(x - bw / 2, y - bh / 2, bw, bh);
    ctx.fillStyle = INK;
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    ctx.fillText(text, x, y + scale);
    ctx.restore();
  }

  function drawTag(ctx, x, y, text, accent, scale) {
    ctx.save();
    ctx.font = "700 " + Math.round(10 * scale) +
      "px 'rajdhani', system-ui, sans-serif";
    var label = text.toUpperCase();
    var pad = 5 * scale;
    var bw = ctx.measureText(label).width + pad * 2;
    var bh = 15 * scale;
    ctx.fillStyle = "rgba(242, 232, 216, 0.95)";
    ctx.strokeStyle = accent;
    ctx.lineWidth = 2;
    roundRect(ctx, x - bw / 2, y - bh / 2, bw, bh, 4 * scale);
    ctx.fill();
    ctx.stroke();
    ctx.fillStyle = INK;
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    ctx.fillText(label, x, y + scale);
    ctx.restore();
  }

  function wrapLines(ctx, text, maxWidth, maxLines) {
    var words = text.split(/\s+/);
    var lines = [];
    var line = "";
    words.forEach(function (word) {
      var probe = line ? line + " " + word : word;
      if (ctx.measureText(probe).width > maxWidth && line) {
        lines.push(line);
        line = word;
      } else {
        line = probe;
      }
    });
    if (line) lines.push(line);
    var overflow = lines.length > maxLines;
    lines = lines.slice(0, maxLines);
    if (overflow && lines.length) {
      lines[lines.length - 1] = ellipsize(ctx, lines[lines.length - 1] + "…",
        maxWidth);
    }
    return lines.map(function (l) { return ellipsize(ctx, l, maxWidth); });
  }

  function drawBubble(ctx, x, bottom, text, maxW, scale, alpha) {
    ctx.save();
    ctx.globalAlpha = alpha;
    ctx.font = Math.round(10.5 * scale) +
      "px -apple-system, BlinkMacSystemFont, 'Segoe UI', system-ui, sans-serif";
    var pad = 6 * scale;
    var lineH = 13 * scale;
    var lines = wrapLines(ctx, text, maxW - pad * 2, 3);
    var bw = 0;
    lines.forEach(function (l) { bw = Math.max(bw, ctx.measureText(l).width); });
    bw += pad * 2;
    var bh = lines.length * lineH + pad * 2 - 2;
    var y = bottom - bh - 6 * scale;
    ctx.shadowColor = "rgba(0,0,0,0.6)";
    ctx.shadowBlur = 5;
    ctx.fillStyle = PAPER;
    roundRect(ctx, x - bw / 2, y, bw, bh, 5 * scale);
    ctx.fill();
    ctx.shadowColor = "transparent";
    // Tail.
    ctx.beginPath();
    ctx.moveTo(x - 5 * scale, y + bh);
    ctx.lineTo(x, y + bh + 6 * scale);
    ctx.lineTo(x + 5 * scale, y + bh);
    ctx.closePath();
    ctx.fill();
    ctx.fillStyle = INK;
    ctx.textAlign = "left";
    ctx.textBaseline = "top";
    lines.forEach(function (l, i) {
      ctx.fillText(l, x - bw / 2 + pad, y + pad + i * lineH);
    });
    ctx.restore();
  }

  // The seismograph: orders placed per stage over the weeks, against
  // customer demand. Revealed only as far as play has reached.
  function drawChart(ctx, rect, view, stageSeat, scale) {
    var orders = view.orders || [[], [], [], []];
    var demand = view.demand || [];
    var weeks = Math.max(view.weeks || 0, 8);
    var padL = 34 * scale;
    var padR = 82 * scale;
    var padT = 16 * scale;
    var padB = 16 * scale;
    var x0 = rect.x + padL;
    var x1 = rect.x + rect.w - padR;
    var y0 = rect.y + padT;
    var y1 = rect.y + rect.h - padB;
    var maxY = 8;
    orders.forEach(function (series) {
      series.forEach(function (v) { if (v > maxY) maxY = v; });
    });
    demand.forEach(function (v) { if (v > maxY) maxY = v; });
    maxY = Math.ceil(maxY * 1.15 / 4) * 4;
    function px(week) { return x0 + (x1 - x0) * week / weeks; }
    function py(v) { return y1 - (y1 - y0) * v / maxY; }

    ctx.save();
    ctx.fillStyle = "rgba(18, 13, 9, 0.55)";
    roundRect(ctx, rect.x, rect.y, rect.w, rect.h, 6 * scale);
    ctx.fill();
    ctx.strokeStyle = "rgba(242, 232, 216, 0.12)";
    ctx.lineWidth = 1;
    ctx.stroke();

    // Title and axes.
    ctx.font = "700 " + Math.round(10 * scale) +
      "px 'rajdhani', system-ui, sans-serif";
    ctx.fillStyle = PAPER_DIM;
    ctx.textAlign = "left";
    ctx.textBaseline = "top";
    ctx.fillText("ORDERS PER WEEK", rect.x + 8 * scale, rect.y + 3 * scale);
    ctx.strokeStyle = "rgba(242, 232, 216, 0.14)";
    for (var g = 0; g <= 4; g++) {
      var gv = maxY * g / 4;
      var gy = py(gv);
      ctx.beginPath();
      ctx.moveTo(x0, gy);
      ctx.lineTo(x1, gy);
      ctx.stroke();
      ctx.fillStyle = GHOST;
      ctx.font = "600 " + Math.round(9 * scale) +
        "px 'rajdhani', system-ui, sans-serif";
      ctx.textAlign = "right";
      ctx.textBaseline = "middle";
      ctx.fillText(String(Math.round(gv)), x0 - 4 * scale, gy);
    }
    // Week ticks every 4.
    ctx.textAlign = "center";
    ctx.textBaseline = "top";
    for (var wk = 0; wk <= weeks; wk += 4) {
      ctx.fillStyle = GHOST;
      ctx.fillText(String(wk), px(wk), y1 + 3 * scale);
    }

    // Demand: a stepped ghost line.
    if (demand.length) {
      ctx.strokeStyle = "rgba(242, 232, 216, 0.5)";
      ctx.lineWidth = 2;
      ctx.setLineDash([4, 3]);
      ctx.beginPath();
      demand.forEach(function (v, i) {
        var x = px(i);
        if (i === 0) ctx.moveTo(x, py(v));
        else {
          ctx.lineTo(x, py(demand[i - 1]));
          ctx.lineTo(x, py(v));
        }
      });
      ctx.stroke();
      ctx.setLineDash([]);
    }

    // Orders per stage, seat-coloured.
    for (var stage = 0; stage < 4; stage++) {
      var series = orders[stage] || [];
      if (!series.length) continue;
      var color = COLOR_HEX[seatColor(stageSeat[stage])];
      ctx.strokeStyle = color;
      ctx.lineWidth = 2;
      ctx.lineJoin = "round";
      ctx.beginPath();
      series.forEach(function (v, i) {
        var x = px(i);
        var y = py(v);
        if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
      });
      ctx.stroke();
      // Head dot.
      var last = series.length - 1;
      ctx.fillStyle = color;
      ctx.beginPath();
      ctx.arc(px(last), py(series[last]), 3 * scale, 0, Math.PI * 2);
      ctx.fill();
    }

    // Now line.
    var nowX = px(view.week || 0);
    ctx.strokeStyle = rgba(AMBER, 0.8);
    ctx.lineWidth = 1.5;
    ctx.beginPath();
    ctx.moveTo(nowX, y0 - 4 * scale);
    ctx.lineTo(nowX, y1);
    ctx.stroke();

    // Legend.
    var lx = x1 + 10 * scale;
    var ly = y0;
    ctx.font = "600 " + Math.round(9.5 * scale) +
      "px 'rajdhani', system-ui, sans-serif";
    ctx.textAlign = "left";
    ctx.textBaseline = "middle";
    for (var r = 0; r < 4; r++) {
      ctx.fillStyle = COLOR_HEX[seatColor(stageSeat[r])];
      ctx.fillRect(lx, ly + r * 13 * scale - 3 * scale, 10 * scale, 6 * scale);
      ctx.fillStyle = PAPER_DIM;
      ctx.fillText(ROLES[r], lx + 14 * scale, ly + r * 13 * scale);
    }
    ctx.strokeStyle = "rgba(242, 232, 216, 0.5)";
    ctx.setLineDash([3, 2]);
    ctx.beginPath();
    ctx.moveTo(lx, ly + 4 * 13 * scale);
    ctx.lineTo(lx + 10 * scale, ly + 4 * 13 * scale);
    ctx.stroke();
    ctx.setLineDash([]);
    ctx.fillStyle = PAPER_DIM;
    ctx.fillText("Demand", lx + 14 * scale, ly + 4 * 13 * scale);
    ctx.restore();
  }

  // ---- Names ---------------------------------------------------------------

  // The agents only ever hear anonymous table names ("Sprocket", "Gizmo");
  // the payload carries the policy names separately, spectator-side only.
  // A name map swaps them in wherever a name is RENDERED while the
  // underlying events keep the aliases. Baseline fillers keep their alias.
  function isBaselineFiller(name) {
    return /^baseline(\s*\(\d+\))?$/i.test(name);
  }

  function makeNameMap(tableNames, policyNames) {
    var table = tableNames || [];
    var display = table.map(function (name, i) {
      var policy = policyNames && policyNames[i];
      return (policy && !isBaselineFiller(policy)) ? policy : name;
    });
    var byAlias = {};
    table.forEach(function (name, i) {
      if (name && display[i] && display[i] !== name) byAlias[name] = display[i];
    });
    var aliases = Object.keys(byAlias);
    var pattern = aliases.length ? new RegExp(
      "\\b(?:" + aliases.map(function (name) {
        return name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
      }).join("|") + ")\\b", "g") : null;
    return {
      seat: function (i) { return display[i] || ("Seat " + i); },
      text: function (text) {
        if (!pattern) return text;
        return text.replace(pattern, function (match) {
          return byAlias[match];
        });
      }
    };
  }

  function applyNames(seats, nameMap) {
    return (seats || []).map(function (seat, i) {
      var copy = Object.assign({}, seat);
      copy.name = nameMap.seat(i);
      return copy;
    });
  }

  function clampName(name) {
    var n = name || "";
    return n.length > 24 ? n.slice(0, 23) + "…" : n;
  }

  // ---- Event feed ----------------------------------------------------------

  function stageOfSeat(events, seat) {
    for (var i = 0; i < events.length; i++) {
      if (events[i].kind === "order" && events[i].seat === seat) {
        return events[i].stage;
      }
    }
    return -1;
  }

  // `ctx` carries what a line needs from earlier events: the last demand
  // seen and the running chain cost.
  function describeEvent(event, nameMap, ctx) {
    function name(i) {
      return clampName(nameMap.seat(i));
    }
    switch (event.kind) {
      case "start":
        return "Chain primed — 12 in stock everywhere, 4 a week on the belts.";
      case "week":
        var stages = event.stages || [];
        var backlog = 0;
        stages.forEach(function (s) { backlog += s.backlog || 0; });
        var demandNote = event.demand !== ctx.lastDemand ?
          "Customers now want " + event.demand + " a week. " : "";
        return demandNote + "Chain backlog " + backlog + ", chain cost " +
          money(stages.reduce(function (a, s) { return a + (s.costTotal || 0); },
            0)) + ".";
      case "order":
        return name(event.seat) + " (" + ROLES[event.stage] + ") orders " +
          event.order + (event.scripted ? " ·" : "");
      case "end":
        return "Final — chain cost " + money(ctx.chainCost) +
          (event.text === "deadline" ? " — episode deadline." : ".");
      default: return JSON.stringify(event);
    }
  }

  function blockHead(block) {
    return block < 0 ? "SETUP" : "WEEK " + block;
  }

  // Renders the full transcript grouped into one section per week.
  // currentIndex (replay) marks how far playback has reached; omit it for
  // live views.
  function renderFeed(element, events, nameMap, currentIndex) {
    var live = currentIndex === undefined;
    var limit = live ? events.length : currentIndex;
    var html = "";
    var lastBlock = null;
    var ctx = { lastDemand: null, chainCost: 0 };
    var lastNotes = {};
    for (var i = 0; i < events.length; i++) {
      var event = events[i];
      var block = event.kind === "start" ? -1 :
        event.kind === "end" ? lastBlock : event.week;
      if (block !== lastBlock) {
        html += '<div class="feed-round-head">' + blockHead(block) +
          "</div>";
        lastBlock = block;
      }
      var text = describeEvent(event, nameMap, ctx);
      if (event.kind === "week") {
        ctx.lastDemand = event.demand;
        ctx.chainCost = (event.stages || []).reduce(function (a, s) {
          return a + (s.costTotal || 0);
        }, 0);
      }
      var cls = "feed-line feed-" + event.kind +
        (event.kind === "order" ? " seat" + (event.seat % COLORS.length) :
          "") +
        (event.kind === "end" ? " feed-rwin" : "") +
        (i >= limit ? " feed-future" : "");
      html += '<div class="' + cls + '">' + escapeHtml(text) + "</div>";
      if (event.kind === "order" && event.say) {
        html += '<div class="feed-line feed-say' +
          (i >= limit ? " feed-future" : "") + '">' +
          escapeHtml(clampName(nameMap.seat(event.seat)) + " says: " +
            nameMap.text(event.say)) + "</div>";
      }
      // Notes: dim, only when the seat's notes changed.
      if (event.kind === "order" && event.text &&
          event.text !== lastNotes[event.seat]) {
        lastNotes[event.seat] = event.text;
        html += '<div class="feed-line feed-notes' +
          (i >= limit ? " feed-future" : "") + '">' +
          escapeHtml(clampName(nameMap.seat(event.seat)) + " notes: " +
            nameMap.text(event.text)) + "</div>";
      }
    }
    element.innerHTML = html;

    if (live || limit >= events.length) {
      element.scrollTop = element.scrollHeight;
      return;
    }
    // Keep the playhead's neighbourhood in view while scrubbing.
    var lines = element.querySelectorAll(".feed-line");
    var target = null;
    for (var l = 0; l < lines.length; l++) {
      if (!lines[l].classList.contains("feed-future")) target = lines[l];
    }
    if (target && element.dataset.anchor !== String(limit)) {
      element.dataset.anchor = String(limit);
      element.scrollTo({
        top: Math.max(target.offsetTop - element.offsetTop -
          element.clientHeight * 0.6, 0)
      });
    }
  }

  function escapeHtml(text) {
    return text.replace(/[&<>"]/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c];
    });
  }

  // ---- Animation bookkeeping ----------------------------------------------

  // Turns a monotonically-growing event list into transient view effects:
  // when the week turned (crates slide), when each stage's order slip was
  // written (it flies), and each stage's last message (bubble).
  function makeEffects() {
    var seen = 0;
    var weekAt = null;
    var orderAt = [null, null, null, null];
    var sayAt = [null, null, null, null];
    var lastSay = ["", "", "", ""];
    return {
      // `quiet` (a scrub jump): the whole prefix lands at once, so only
      // the newest event gets to animate.
      absorb: function (events, quiet) {
        var now = Date.now();
        for (; seen < events.length; seen++) {
          var event = events[seen];
          var animate = !quiet || seen >= events.length - 1;
          if (event.kind === "week") {
            weekAt = animate ? now : null;
            orderAt = [null, null, null, null];
          } else if (event.kind === "order") {
            orderAt[event.stage] = animate ? now : null;
            if (event.say) {
              lastSay[event.stage] = event.say;
              sayAt[event.stage] = animate ? now : null;
            }
          }
        }
      },
      reset: function () {
        seen = 0; weekAt = null;
        orderAt = [null, null, null, null];
        sayAt = [null, null, null, null];
        lastSay = ["", "", "", ""];
      },
      view: function () {
        return { effects: { weekAt: weekAt, orderAt: orderAt.slice(),
          sayAt: sayAt.slice(), lastSay: lastSay.slice() } };
      }
    };
  }

  // ---- Scorebug, header, endscreen ----------------------------------------

  function matchHeader(state, config) {
    var parts = [];
    if (state) {
      var total = state.weeks || (config && config.weeks) || 0;
      parts.push("WEEK " + (state.week || 0) + (total ? " / " + total : ""));
      if (state.gameDone || state.done) {
        parts.push("FINAL");
      } else if (state.seats) {
        var waiting = state.seats.filter(function (s) { return s.pending; });
        parts.push(waiting.length ? "WAITING ON " + waiting.length :
          "ORDERS IN");
      }
    }
    return parts.join(" · ");
  }

  function updateScorebug(container, state, nameMap) {
    if (!container || !state || !state.seats) return;
    var html = "";
    state.seats.forEach(function (seat, index) {
      var plateName = nameMap ? nameMap.seat(index) : seat.name;
      html += '<div class="plate ' + seatColor(index) + '">' +
        '<span class="plate-name">' + escapeHtml(clampName(plateName)) +
        "</span>" +
        (seat.pending && !state.gameDone ?
          '<span class="plate-it">▶</span>' : "") +
        '<span class="plate-score">' + escapeHtml(money(seat.cost)) +
        "</span>" +
        '<span class="plate-label">' + escapeHtml(seat.role || "") +
        "</span>" +
        (seat.backlog ? '<span class="plate-backlog">' + seat.backlog +
          " owed</span>" : "") +
        "</div>";
    });
    if (container.dataset.html !== html) {
      container.dataset.html = html;
      container.innerHTML = html;
    }
  }

  function reasonLine(results) {
    switch (results.reason) {
      case "deadline":
        return "episode deadline: scored on " + (results.weeks || 0) +
          " of " + (results.maxWeeks || results.weeks || 0) + " weeks";
      default: return "";
    }
  }

  // Final standings overlay: verdict up top, ranked rows below.
  function updateEndscreen(container, results, show, nameMap, peaks) {
    if (!container) return;
    container.classList.toggle("show", !!show);
    if (!show || !results || container.dataset.built === "yes") return;
    container.dataset.built = "yes";
    var names = (results.names || []).map(function (name, i) {
      return nameMap ? nameMap.seat(i) : name;
    });
    var costs = results.costs || [];
    var roles = results.roles || [];
    var order = names.map(function (_, i) { return i; });
    order.sort(function (a, b) { return (costs[a] || 0) - (costs[b] || 0); });
    var topIndex = order.length ? order[0] : -1;
    var level = order.every(function (i) {
      return (costs[i] || 0) === (costs[topIndex] || 0);
    });
    var verdictColor = !level && topIndex >= 0 ? seatColor(topIndex) : "";
    var verdict = !level && topIndex >= 0 ?
      escapeHtml(names[topIndex]) + " RAN THE TIGHTEST SHOP" : "ALL LEVEL";
    var reason = reasonLine(results);
    var html = '<div class="end-panel">' +
      '<div class="end-title">FINAL — ' + (results.weeks || 0) + " WEEK" +
      ((results.weeks || 0) === 1 ? "" : "S") + " · CHAIN COST " +
      escapeHtml(money(results.chainCost)) + "</div>" +
      '<div class="end-verdict ' + verdictColor + '">' + verdict + "</div>" +
      (reason ? '<div class="end-reason">' + escapeHtml(reason) + "</div>" :
        "") +
      '<div class="end-rows">' +
      '<span class="end-head"></span><span class="end-head"></span>' +
      '<span class="end-head">role</span>' +
      '<span class="end-head">cost</span>' +
      '<span class="end-head">peak order</span>' +
      '<span class="end-head">score</span>';
    order.forEach(function (i, rank) {
      var leader = !level && i === topIndex;
      var cell = function (value) {
        return '<span class="end-cell' + (leader ? " end-row-winner" : "") +
          '">' + value + "</span>";
      };
      html += '<span class="end-cell rank' +
        (leader ? " end-row-winner" : "") + '">' + (rank + 1) + "</span>" +
        '<span class="end-cell name ' + seatColor(i) +
        (leader ? " end-row-winner" : "") + '">' + escapeHtml(names[i]) +
        "</span>" +
        cell(escapeHtml(roles[i] || "")) +
        cell(escapeHtml(money(costs[i]))) +
        cell(peaks && typeof peaks[i] === "number" ? peaks[i] : "–") +
        cell(((results.scores || [])[i] || 0).toFixed(1));
    });
    html += "</div></div>";
    container.innerHTML = html;
  }

  function peakOrders(events) {
    var peaks = [null, null, null, null];
    events.forEach(function (event) {
      if (event.kind !== "order") return;
      if (peaks[event.seat] === null || event.order > peaks[event.seat]) {
        peaks[event.seat] = event.order;
      }
    });
    return peaks;
  }

  function bindFeedToggle(button, startCollapsed) {
    if (!button) return;
    if (startCollapsed) {
      document.body.classList.add("feed-collapsed");
      requestAnimationFrame(function () {
        window.dispatchEvent(new Event("resize"));
      });
    }
    function refresh() {
      button.textContent =
        document.body.classList.contains("feed-collapsed") ?
          "« LOG" : "LOG »";
    }
    button.onclick = function () {
      document.body.classList.toggle("feed-collapsed");
      refresh();
      window.dispatchEvent(new Event("resize"));
    };
    refresh();
  }

  // ---- Drivers -------------------------------------------------------------

  function stateToView(state, nameMap, effects, extras) {
    var view = effects.view();
    view.seats = applyNames(state.seats, nameMap);
    view.stageSeat = state.stageSeat || [0, 1, 2, 3];
    view.demand = state.demand || [];
    view.orders = state.orders || [[], [], [], []];
    view.week = state.week || 0;
    view.weeks = state.weeks || 0;
    view.weeksPlayed = state.weeksPlayed || 0;
    view.phase = state.phase || "";
    view.now = Date.now();
    Object.assign(view, extras || {});
    return view;
  }

  // A redacted player frame ({seat:{...}}) becomes a four-seat state with
  // the own seat filled in so the same scene draws.
  function playerFrameToState(data) {
    if (data.seats) return data;
    var seats = [];
    for (var i = 0; i < 4; i++) seats.push({ name: "Seat " + i, cost: 0 });
    if (typeof data.slot === "number" && data.seat) {
      var own = Object.assign({}, data.seat, { name: data.name });
      own.cost = own.costTotal;
      seats[data.slot] = own;
    }
    var stageSeat = [0, 1, 2, 3];
    if (data.seat && typeof data.slot === "number") {
      var stage = ROLES.indexOf(data.seat.role);
      if (stage >= 0) {
        stageSeat = [0, 1, 2, 3].filter(function (s) { return s !== data.slot; });
        stageSeat.splice(stage, 0, data.slot);
      }
    }
    seats.forEach(function (s, i) {
      s.stage = stageSeat.indexOf(i);
      s.role = ROLES[s.stage];
    });
    return {
      seats: seats, stageSeat: stageSeat, week: data.week, weeks: data.weeks,
      weeksPlayed: data.weeksPlayed, demand: [], orders: [[], [], [], []],
      phase: data.done ? "done" : "orders", gameDone: data.done,
      reason: data.reason, events: []
    };
  }

  function attachLive(options) {
    // options: {canvas, feed, status, clock, scorebug, endscreen,
    //           assetBase, wsPath, onFrame}
    makeRenderer(options.canvas, options.assetBase, function (renderer) {
      var latest = null;
      var nameMap = makeNameMap([], null);
      var effects = makeEffects();
      var scheme = location.protocol === "https:" ? "wss://" : "ws://";
      var url = scheme + location.host + options.wsPath;

      function setStatus(text, live) {
        if (!options.status) return;
        options.status.textContent = text;
        options.status.classList.toggle("live", !!live);
      }

      function connect() {
        var socket = new WebSocket(url);
        socket.onmessage = function (frame) {
          var data = JSON.parse(frame.data);
          if (data.type === "state" || data.type === "final") {
            if (data.type === "state") latest = playerFrameToState(data);
            if (latest) {
              nameMap = makeNameMap(seatNames(latest), latest.policyNames);
              effects.absorb(latest.events || []);
              if (options.feed) {
                renderFeed(options.feed, latest.events || [], nameMap,
                  undefined);
              }
              if (options.clock) {
                options.clock.textContent = matchHeader(latest, latest);
              }
              updateScorebug(options.scorebug, latest, nameMap);
            }
            if (data.type === "final") {
              updateEndscreen(options.endscreen, data, true, nameMap,
                peakOrders(latest && latest.events || []));
            }
            if (latest && (latest.done || latest.gameDone)) {
              setStatus("final", false);
            }
          }
          if (options.onFrame) options.onFrame(data);
        };
        socket.onclose = function () {
          setStatus("disconnected", false);
          setTimeout(connect, 2000);
        };
        socket.onopen = function () {
          setStatus("live", true);
        };
      }
      connect();

      function seatNames(data) {
        return (data.seats || []).map(function (s) { return s.name; });
      }

      (function frame() {
        if (latest) {
          var view = stateToView(latest, nameMap, effects, {
            done: !!(latest.done || latest.gameDone)
          });
          renderer.draw(view);
        }
        requestAnimationFrame(frame);
      })();
    });
  }

  // Scrubber: a click/drag-to-seek track with one span per week, a marker
  // per order (coloured by the seat) and the end (taller).
  function buildScrub(container, events, onSeek) {
    container.innerHTML = "";
    var track = document.createElement("div");
    track.className = "scrub-track";
    container.appendChild(track);
    var fill = document.createElement("div");
    fill.className = "scrub-fill";
    container.appendChild(fill);
    var blockStarts = [];
    var lastBlock = null;
    events.forEach(function (event, i) {
      var block = event.kind === "start" ? -1 :
        event.kind === "end" ? lastBlock : event.week;
      if (block !== lastBlock) {
        blockStarts.push(i);
        lastBlock = block;
      }
    });
    blockStarts.forEach(function (startIdx, r) {
      var endIdx = r + 1 < blockStarts.length ?
        blockStarts[r + 1] : events.length;
      var span = document.createElement("div");
      span.className = "round-span" + (r % 2 ? " alt" : "");
      span.style.left = (startIdx / events.length * 100) + "%";
      span.style.width = ((endIdx - startIdx) / events.length * 100) + "%";
      container.appendChild(span);
      if (r > 0 && r % 4 === 0) {
        var sep = document.createElement("div");
        sep.className = "round-sep";
        sep.style.left = (startIdx / events.length * 100) + "%";
        container.appendChild(sep);
      }
    });
    events.forEach(function (event, i) {
      var kind = event.kind;
      if (kind !== "order" && kind !== "end") return;
      var marker = document.createElement("div");
      marker.className = "beat-marker" +
        (kind === "order" ? " seat" + (event.seat % COLORS.length) : "") +
        (kind === "end" ? " death" : "");
      marker.style.left = ((i + 1) / events.length * 100) + "%";
      container.appendChild(marker);
    });
    var head = document.createElement("div");
    head.className = "scrub-head";
    container.appendChild(head);

    function seekFromEvent(evt) {
      var rect = container.getBoundingClientRect();
      if (!rect.width) return;   // hidden/unlaid-out page: nothing to seek
      var x = (evt.touches ? evt.touches[0].clientX : evt.clientX) -
        rect.left;
      var fraction = Math.max(0, Math.min(x / rect.width, 1));
      onSeek(Math.round(fraction * events.length));
    }
    var dragging = false;
    container.addEventListener("pointerdown", function (evt) {
      dragging = true;
      try { container.setPointerCapture(evt.pointerId); } catch (ignore) {}
      seekFromEvent(evt);
    });
    container.addEventListener("pointermove", function (evt) {
      if (dragging) seekFromEvent(evt);
    });
    container.addEventListener("pointerup", function () {
      dragging = false;
    });

    return {
      update: function (index) {
        var pct = events.length ? (index / events.length * 100) : 0;
        fill.style.width = pct + "%";
        head.style.left = pct + "%";
      }
    };
  }

  function attachReplay(options) {
    // options: {canvas, feed, scrub, playButton, label, clock, scorebug,
    //           endscreen, assetBase, payload}
    var payload = options.payload;
    var events = payload.events || [];
    var states = payload.states || [];
    var config = payload.config || {};
    var nameMap = makeNameMap(payload.names, payload.policyNames);
    var peaks = peakOrders(events);
    var index = 0;
    var playing = true;
    var lastStep = 0;

    makeRenderer(options.canvas, options.assetBase, function (renderer) {
      var effects = makeEffects();
      var scrub = buildScrub(options.scrub, events, function (next) {
        playing = false;
        setIndex(next, true);
      });
      if (options.playButton) {
        options.playButton.onclick = function () {
          playing = !playing;
          if (playing && index >= events.length) setIndex(0, true);
        };
      }

      function currentState() {
        return states[Math.min(index, states.length - 1)] ||
          { seats: [], phase: "", week: 0 };
      }

      function setIndex(next, jumped) {
        index = Math.max(0, Math.min(next, events.length));
        scrub.update(index);
        if (jumped) {
          effects.reset();
        }
        effects.absorb(events.slice(0, index), jumped);
        if (options.feed) renderFeed(options.feed, events, nameMap, index);
        if (options.label) {
          options.label.textContent = index + " / " + events.length;
        }
        if (options.clock) {
          options.clock.textContent = matchHeader(currentState(), config);
        }
        updateScorebug(options.scorebug, currentState(), nameMap);
        updateEndscreen(options.endscreen, payload.results,
          index >= events.length && events.length > 0, nameMap, peaks);
      }
      setIndex(0, true);

      (function frame(timestamp) {
        // Dwell on what the viewer is currently looking at: a week turn
        // gets read (the crates slide, the chart grows), an order less so,
        // a message a little longer.
        var shown = index > 0 ? events[index - 1] : null;
        var stepMs = shown && shown.kind === "week" ? 1500 :
          shown && shown.kind === "order" ? (shown.say ? 900 : 450) :
          shown && shown.kind === "end" ? 1500 :
          600;
        if (playing && index < events.length &&
            timestamp - lastStep > stepMs) {
          lastStep = timestamp;
          setIndex(index + 1, false);
        }
        if (options.playButton) {
          var running = playing && index < events.length;
          options.playButton.textContent = running ? "❚❚" : "▶";
          options.playButton.classList.toggle("on", running);
        }
        var view = stateToView(currentState(), nameMap, effects, {
          done: index >= events.length && events.length > 0
        });
        renderer.draw(view);
        requestAnimationFrame(frame);
      })(0);

      document.documentElement.setAttribute("data-replay-loaded", "true");
    });
  }

  window.BullwhipRenderer = {
    attachLive: attachLive,
    attachReplay: attachReplay,
    renderFeed: renderFeed,
    bindFeedToggle: bindFeedToggle
  };
})();
