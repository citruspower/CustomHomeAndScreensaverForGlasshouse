/*
 * Starry Sky screen saver.
 *
 * A true-black sky - every pixel without a star is off on an OLED - full of
 * stars that each shimmer at their own speed, with a faint band of the Milky
 * Way and now and then a shooting star.
 *
 * How it stays light on the TV: the stars are painted once, into a canvas a
 * tenth larger than the screen, not as colours but as data - each star's
 * pixel holds its brightness (red), where in its twinkle it starts (green)
 * and its twinkle speed and colour (blue). A fragment shader turns that into
 * shimmering, coloured stars on the graphics chip, so all the script does 30
 * times a second is move a clock forward.
 *
 * Burn-in: the whole sky wanders a few dozen pixels over minutes, a whole
 * pixel at a time so no star ever blurs, every start paints a new sky, and
 * every 30 to 40 minutes the camera pans across to a new sky: the new one is painted
 * into a second, hidden layer, chosen so its Milky Way carries on from the
 * old one's, and laid next to the old sky with a wide soft overlap, so the
 * two read as one long sky the camera travels along.
 */
import QtQuick 2.4
import Eos.Window 0.1

WebOSWindow {
    id: win

    // Sized for the compositor's 1920x1080 layout, as Glasshouse's example
    // does; the size, type and app id are what make this the screen saver.
    width: 1920
    height: 1080

    windowType: "_WEBOS_WINDOW_TYPE_SCREENSAVER"
    appId: "com.webos.app.screensaver"
    title: "Screen Saver"
    visible: true
    color: "black"

    // Dim or bright, written in when the screen saver is staged.
    property int level: __TVWEB_LEVEL__
    property real gain: level > 0 ? 1.0 : 0.65

    // The star map is this much larger than the screen, so it can wander.
    readonly property int mapW: 2112
    readonly property int mapH: 1188

    property real t: 0
    property double last: 0
    // The twinkle clock: wraps every 25 seconds. Every twinkle speed is a
    // whole multiple of 0.04 Hz (0.08 to 0.68 Hz, a slow shimmer), so the
    // wrap never shows, and the shader's
    // numbers stay small enough to stay exact.
    property real phase: 0
    property int seed: 1 + Math.floor(Math.random() * 2147483645)

    // Two sky layers: the one showing (front) and the one the next sky is
    // painted into. While panning, the next sky lies beside the current one,
    // overlapping it by `overlap` pixels, where it blends in softly; pan runs
    // 0 to 1 as the camera travels the `overlap`-shortened width across to
    // it, panDir +1 to the right, -1 to the left.
    property int seedA: 0
    property int seedB: 0
    property int front: 0
    property int nextSeed: 0
    property bool panning: false
    property real pan: 0
    property int panDir: 1
    readonly property int overlap: 700
    // How strongly the next sky's near edge blends (1) or is solid (0), and
    // how far it has come in at all (0 to 1, at the very start of the pan).
    property real blend: 1
    property real arrive: 0
    // The slow wander, in whole pixels.
    property int wx: -96
    property int wy: -54

    // The Milky Way's glow is painted at half the size and scaled up
    // smoothly, which gives it soft, even edges.
    readonly property real glowScale: 0.5

    // The star clock: HH:MM in stars, in a part of the sky clear of the Milky
    // Way, hopping to another such place every 10 minutes.
    readonly property int clockW: 560
    readonly property int clockH: 200
    property string clockText: ""
    property int clockSlot: -1

    // Turns star data into shimmering, coloured stars; shared by the sky and
    // the clock so the clock's stars are just like the others.
    readonly property string starShader: "
        uniform sampler2D stars;
        uniform highp float phase0;
        uniform highp float gain;
        uniform highp float famt;
        uniform highp float fdir;
        uniform highp float fw;
        uniform lowp float qt_Opacity;
        varying highp vec2 qt_TexCoord0;
        void main() {
            highp float e = fdir > 0.0 ? qt_TexCoord0.x : 1.0 - qt_TexCoord0.x;
            highp float fa = mix(1.0, smoothstep(0.0, fw, e), famt);
            highp vec4 s = texture2D(stars, qt_TexCoord0);
            highp float b = floor(s.b * 255.0 + 0.5);
            highp float k = floor(b / 16.0);
            highp float c = b - k * 16.0;
            highp float w = k + 2.0;
            highp float p = s.g * 6.2832;
            highp float tw = 0.62 * sin(phase0 * w + p) + 0.38 * sin(phase0 * w * 2.0 + p * 1.7);
            highp float depth = mix(0.2, 0.7, s.r);
            highp float v = s.r * (1.0 - depth * 0.5 + depth * 0.5 * tw);
            highp float ct = c / 15.0;
            highp vec3 cool = vec3(0.70, 0.82, 1.0);
            highp vec3 warm = vec3(1.0, 0.82, 0.60);
            highp vec3 white = vec3(1.0, 1.0, 1.0);
            highp vec3 tint = mix(mix(cool, white, clamp(ct * 2.0, 0.0, 1.0)),
                                  mix(white, warm, clamp(ct * 2.0 - 1.0, 0.0, 1.0)),
                                  step(0.5, ct));
            highp vec3 rgb = tint * v * gain;
            gl_FragColor = vec4(rgb, max(rgb.r, max(rgb.g, rgb.b))) * fa * qt_Opacity;
        }"

    // The Milky Way's glow, from its half-size canvas, smoothly scaled up,
    // with the same soft edge as the stars while a new sky blends in.
    readonly property string glowShader: "
        uniform sampler2D glow;
        uniform highp float gain;
        uniform highp float famt;
        uniform highp float fdir;
        uniform highp float fw;
        uniform lowp float qt_Opacity;
        varying highp vec2 qt_TexCoord0;
        void main() {
            highp float e = fdir > 0.0 ? qt_TexCoord0.x : 1.0 - qt_TexCoord0.x;
            highp float fa = mix(1.0, smoothstep(0.0, fw, e), famt);
            gl_FragColor = texture2D(glow, qt_TexCoord0) * gain * fa * qt_Opacity;
        }"

    // Black behind the next sky, so it hides the sky it slides over, with
    // the same soft edge, so the old sky shows through where they blend.
    readonly property string backShader: "
        uniform highp float famt;
        uniform highp float fdir;
        uniform highp float fw;
        uniform lowp float qt_Opacity;
        varying highp vec2 qt_TexCoord0;
        void main() {
            highp float e = fdir > 0.0 ? qt_TexCoord0.x : 1.0 - qt_TexCoord0.x;
            highp float fa = mix(1.0, smoothstep(0.0, fw, e), famt);
            gl_FragColor = vec4(0.0, 0.0, 0.0, fa) * qt_Opacity;
        }"

    // <draw> Pure drawing functions, also run by the offline preview.

    function makeRnd(seed) {
        var s = seed;
        return function () { s = (s * 16807) % 2147483647; return (s - 1) / 2147483646; };
    }

    // Paints the star map. Each star's pixel: red its brightness (0 is empty
    // sky), green its twinkle phase, blue its twinkle speed (high four bits)
    // and colour from blue-white to warm (low four bits).
    function paintStars(ctx, w, h, seed) {
        var rnd = makeRnd(seed);
        var i;
        ctx.clearRect(0, 0, w, h);

        function gauss() { return (rnd() + rnd() + rnd() + rnd() - 2) / 0.577; }
        function put(x, y, v, g, b) {
            if (x < 0 || y < 0 || x >= w || y >= h) return;
            ctx.fillStyle = "rgb(" + v + "," + g + "," + b + ")";
            ctx.fillRect(x, y, 1, 1);
        }
        function star(x, y, boost) {
            x = Math.floor(x); y = Math.floor(y);
            // Most stars faint, a few bright.
            var v = Math.min(255, Math.round((70 + 185 * Math.pow(rnd(), 2.6)) * boost));
            var g = Math.floor(rnd() * 256);
            var speed = Math.floor(rnd() * 16);
            var col = Math.max(0, Math.min(15, Math.round(7.5 + gauss() * 3.2)));
            var b = speed * 16 + col;
            put(x, y, v, g, b);
            // The brightest get a small cross of light, some bright ones are
            // two pixels across; both twinkle as one with their star.
            if (v > 215 && rnd() < 0.6) {
                var a = Math.round(v * 0.32);
                put(x - 1, y, a, g, b); put(x + 1, y, a, g, b);
                put(x, y - 1, a, g, b); put(x, y + 1, a, g, b);
            } else if (v > 140 && rnd() < 0.35) {
                var e = Math.round(v * 0.55);
                put(x + 1, y, e, g, b); put(x, y + 1, e, g, b); put(x + 1, y + 1, Math.round(e * 0.7), g, b);
            }
        }

        // Stars all over.
        var n = Math.round(w * h / 750);
        for (i = 0; i < n; i++) star(rnd() * w, rnd() * h, 1);

        // The Milky Way: a crowd of stars along the band, half spread over it
        // and half packed into its bright core, with the dust lane hiding
        // most of the stars behind it.
        // The stars thin out where the glow is faint, so both follow the
        // same bright and dim stretches.
        var B = band(seed, w, h);
        for (i = 0; i < 6500; i++) {
            var u = rnd();
            var off = gauss() * B.sd * (rnd() < 0.5 ? 1.0 : 0.45) * bandWidth(B, u);
            if (rnd() > 0.2 + 0.8 * bandLight(B, u)) continue;
            if (Math.abs(off - lane(B, u)) < B.sd * 0.12 && rnd() < 0.75) continue;
            var q = bandPoint(B, u, off);
            star(q.x, q.y, 0.75);
        }
        // A few dense star clouds along it, where the glow has its bright knots.
        for (var c = 0; c < 6; c++) {
            var cp = bandPoint(B, B.clouds[c].u, B.clouds[c].off);
            for (i = 0; i < 180; i++) star(cp.x + gauss() * 22, cp.y + gauss() * 22, 0.7);
        }
    }

    // The Milky Way's line across the map, worked out from the seed alone so
    // its stars and its glow agree: a different slant on every start.
    function band(seed, w, h) {
        var rnd = makeRnd(((seed * 7 + 13) % 2147483646) + 1);
        var y0 = h * (0.2 + rnd() * 0.6), y1 = h * (0.2 + rnd() * 0.6);
        var dy = y1 - y0;
        var B = { y0: y0, dx: w, dy: dy, len: Math.sqrt(w * w + dy * dy),
                  sd: h * 0.075, lanePh: rnd() * 6.2832, ph: [], clouds: [] };
        for (var i = 0; i < 6; i++) B.ph.push(rnd() * 6.2832);
        // Bright knots along the band, each a little off its middle.
        for (i = 0; i < 9; i++)
            B.clouds.push({ u: 0.04 + rnd() * 0.92, off: (rnd() - 0.5) * B.sd * 1.2, s: 0.5 + rnd() * 0.8 });
        return B;
    }
    // How bright the band is along its length, 0 to 1: long bright stretches
    // and dim gaps, different on every start.
    function bandLight(B, u) {
        var n = 0.5 + 0.30 * Math.sin(u * 5.3 + B.ph[0]) + 0.20 * Math.sin(u * 11.7 + B.ph[1])
                    + 0.12 * Math.sin(u * 23.1 + B.ph[2]);
        n = Math.max(0, Math.min(1, n));
        return n * n * (3 - 2 * n);
    }
    // How wide the band is along its length, around 1.
    function bandWidth(B, u) {
        return 0.85 + 0.3 * Math.sin(u * 4.1 + B.ph[3]) + 0.12 * Math.sin(u * 13.3 + B.ph[4]);
    }
    // A point along the band (u from 0 to 1) and off to one side of it.
    function bandPoint(B, u, off) {
        return { x: u * B.dx - B.dy / B.len * off, y: B.y0 + u * B.dy + B.dx / B.len * off };
    }
    // Where the dark dust lane runs, winding just off the band's middle.
    function lane(B, u) { return B.sd * (0.15 + 0.25 * Math.sin(u * 9 + B.lanePh)); }

    // The Milky Way's glow: soft overlapping light along the band, warmer in
    // its core and bluer at its edges, brighter and wider in some stretches
    // and almost gone in others, with bright knots, a few wisps drifting off
    // to the side and the dust lane cut out of it. Kept
    // faint - a dim haze behind the stars, not a bright patch on the panel.
    // Painted into a canvas k times the map's size (k below 1), in map
    // coordinates, and shown scaled back up.
    function paintGlow(ctx, w, h, seed, k) {
        var rnd = makeRnd(((seed * 3 + 5) % 2147483646) + 1);
        var B = band(seed, w, h), i;
        function gauss() { return (rnd() + rnd() + rnd() + rnd() - 2) / 0.577; }
        function blob(x, y, r, rgb, a) {
            var g = ctx.createRadialGradient(x, y, 0, x, y, r);
            g.addColorStop(0, "rgba(" + rgb + "," + a + ")");
            g.addColorStop(1, "rgba(" + rgb + ",0)");
            ctx.fillStyle = g;
            ctx.fillRect(x - r, y - r, 2 * r, 2 * r);
        }
        ctx.clearRect(0, 0, w * k, h * k);
        ctx.save();
        ctx.scale(k, k);
        ctx.globalCompositeOperation = "lighter";
        function tint(off) {
            var core = Math.max(0, 1 - Math.abs(off) / B.sd);
            return Math.round(170 + 60 * core) + "," + Math.round(175 + 35 * core) + "," + Math.round(235 - 25 * core);
        }
        // Many large, very faint patches, so no single one shows at the edge,
        // each as bright as the band is at its place.
        for (i = 0; i < 650; i++) {
            var u = rnd(), bw = bandWidth(B, u);
            var off = gauss() * B.sd * 0.75 * bw, p = bandPoint(B, u, off);
            blob(p.x, p.y, B.sd * bw * (0.6 + rnd() * 1.2), tint(off), 0.003 + 0.011 * bandLight(B, u));
        }
        // Bright knots: tighter, brighter clumps of light.
        for (var c = 0; c < B.clouds.length; c++) {
            var cl = B.clouds[c];
            for (i = 0; i < 40; i++) {
                var o = cl.off + gauss() * B.sd * 0.3 * cl.s, cu = cl.u + gauss() * 0.025 * cl.s;
                var cq = bandPoint(B, cu, o);
                blob(cq.x, cq.y, B.sd * cl.s * (0.25 + rnd() * 0.45), tint(o), 0.010);
            }
        }
        // Wisps: faint streamers drifting off the band to one side.
        for (var s = 0; s < 5; s++) {
            var su = 0.1 + rnd() * 0.8, side = rnd() < 0.5 ? -1 : 1, slope = (rnd() - 0.5) * 0.08;
            for (i = 0; i < 28; i++) {
                var f = i / 27;
                var wq = bandPoint(B, su + slope * f + gauss() * 0.004, side * B.sd * (0.6 + f * 1.5));
                blob(wq.x, wq.y, B.sd * (0.3 + rnd() * 0.3) * (1 - f * 0.5), tint(B.sd), 0.006 * (1 - f));
            }
        }
        ctx.globalCompositeOperation = "destination-out";
        for (i = 0; i < 380; i++) {
            u = rnd();
            var d = bandPoint(B, u, lane(B, u) + gauss() * B.sd * 0.07);
            blob(d.x, d.y, B.sd * (0.12 + rnd() * 0.38), "0,0,0", 0.28);
        }
        ctx.globalCompositeOperation = "source-over";
        ctx.restore();
    }

    // The star clock: each digit's seven segments laid out in stars on a grid
    // 4 wide and 8 tall, a star every eighth step along a segment with the
    // corners shared, like a digital clock picked out in stars. The stars are
    // painted just like the sky's own, same brightness, size and colour, only
    // spread across thick strokes, and scattered a little so the clock melts into the
    // sky. Each star belongs to its grid point and keeps its place,
    // brightness and twinkle from one minute to the next, so only the
    // strokes that change come and go.
    function paintClock(ctx, cw, ch, text, seed) {
        var U = 20, pad = 20;
        var DIGITS = ["abcdef", "bc", "abdeg", "abcdg", "bcfg", "acdfg", "acdefg", "abc", "abcdefg", "abcdfg"];
        var CELL = [0, 7, 12, 15, 22];
        ctx.clearRect(0, 0, cw, ch);
        function put(x, y, v, g, b) {
            if (x < 0 || y < 0 || x >= cw || y >= ch) return;
            ctx.fillStyle = "rgb(" + v + "," + g + "," + b + ")";
            ctx.fillRect(x, y, 1, 1);
        }
        // A clock star, drawn the way paintStars draws the sky's.
        // Strokes are STROKE pixels thick: each star lands anywhere across
        // its stroke's width (sx, sy say which way the stroke runs across).
        var STROKE = 14;
        function dot(ux, uy, key, sx, sy) {
            // Scrambled so neighbouring stars get unrelated numbers (the plain
            // generator gives near neighbours lined-up offsets: a hatched look).
            var hsh = Math.sin(key * 12.9898 + (seed % 100000) * 0.0789) * 43758.5453;
            var r = makeRnd(Math.floor((hsh - Math.floor(hsh)) * 2147483645) + 1);
            r(); r(); r();
            function gauss() { return (r() + r() + r() + r() - 2) / 0.577; }
            var ax = gauss() * 1.5, ay = gauss() * 1.5, across = (r() - 0.5) * STROKE;
            var x = Math.round(pad + ux * U + (sx ? across : ax)), y = Math.round(pad + uy * U + (sy ? across : ay));
            var v = Math.min(255, Math.round(70 + 185 * Math.pow(r(), 2.6)));
            var g = Math.floor(r() * 256);
            var col = Math.max(0, Math.min(15, Math.round(7.5 + gauss() * 3.2)));
            var b = Math.floor(r() * 16) * 16 + col;
            put(x, y, v, g, b);
            if (v > 215 && r() < 0.6) {
                var a = Math.round(v * 0.32);
                put(x - 1, y, a, g, b); put(x + 1, y, a, g, b);
                put(x, y - 1, a, g, b); put(x, y + 1, a, g, b);
            } else if (v > 140 && r() < 0.35) {
                var e = Math.round(v * 0.55);
                put(x + 1, y, e, g, b); put(x, y + 1, e, g, b); put(x + 1, y + 1, Math.round(e * 0.7), g, b);
            }
        }
        // The eighth-step grid points of each segment, ends included.
        function seg(s) {
            var p = [], j;
            for (j = 0; j <= 32; j++) {
                if (s === "a") p.push([j, 0]);
                if (s === "g") p.push([j, 32]);
                if (s === "d") p.push([j, 64]);
                if (s === "f") p.push([0, j]);
                if (s === "b") p.push([32, j]);
                if (s === "e") p.push([0, 32 + j]);
                if (s === "c") p.push([32, 32 + j]);
            }
            return p;
        }
        for (var i = 0; i < text.length && i < 5; i++) {
            var chr = text.charAt(i);
            if (chr === ":") {
                // Each colon dot a tight little knot of nine stars.
                for (var m = 0; m < 9; m++) { dot(CELL[i], 2.5, 9000 + i * 10 + m, 1, 1); dot(CELL[i], 5.5, 9500 + i * 10 + m, 1, 1); }
                continue;
            }
            var segs = DIGITS[+chr] || "", seen = {};
            for (var s = 0; s < segs.length; s++) {
                var sc = segs.charAt(s), across = (sc === "a" || sc === "g" || sc === "d") ? 0 : 1;
                var pts = seg(sc);
                for (var k = 0; k < pts.length; k++) {
                    var id = pts[k][0] * 80 + pts[k][1];
                    if (seen[id]) continue;
                    seen[id] = true;
                    dot(CELL[i] + pts[k][0] / 8, pts[k][1] / 8, i * 10000 + id, across, 1 - across);
                }
            }
        }
    }

    // A seed for the next sky whose Milky Way carries on from this one's
    // across the overlap where the two skies meet: about the same height
    // there and about the same slant. dir +1: the next sky lies to the right.
    function matchSeed(seed, dir, w, h, ov, rand) {
        var A = band(seed, w, h), best = 0, bestErr = 1e9;
        var xa = dir > 0 ? w - ov / 2 : ov / 2, xb = dir > 0 ? ov / 2 : w - ov / 2;
        var ya = A.y0 + xa / w * A.dy;
        for (var i = 0; i < 4000; i++) {
            var s = 1 + Math.floor(rand() * 2147483645), B = band(s, w, h);
            var yb = B.y0 + xb / w * B.dy;
            var err = Math.abs(yb - ya) + Math.abs(B.dy - A.dy) * 0.25;
            if (err < bestErr) { bestErr = err; best = s; }
            if (err < 20) break;
        }
        return best;
    }

    // Places for the clock on the map, all inside the part that is always on
    // screen however the sky wanders, each with how clear it is of the Milky
    // Way's band, in band widths.
    function clockSpots(seed, w, h, cw, ch) {
        var B = band(seed, w, h), nx = -B.dy / B.len, ny = B.dx / B.len;
        var xl = 186 + 40, xr = 1926 - 40 - cw, xc = Math.round((xl + xr) / 2);
        var xq = Math.round((xl + xc) / 2), xs = Math.round((xc + xr) / 2);
        var yt = 104 + 30, yb = 1084 - 30 - ch, ym = Math.round((yt + yb) / 2);
        // Corners, along the top and bottom edges, and halfway up each side.
        var c = [[xl, yt], [xr, yt], [xl, yb], [xr, yb], [xc, yt], [xc, yb],
                 [xq, yt], [xs, yt], [xq, yb], [xs, yb], [xl, ym], [xr, ym]], out = [];
        for (var i = 0; i < c.length; i++) {
            var cx = c[i][0] + cw / 2, cy = c[i][1] + ch / 2;
            var d = Math.abs(cx * nx + (cy - B.y0) * ny) - (Math.abs(nx) * cw / 2 + Math.abs(ny) * ch / 2);
            out.push({ x: c[i][0], y: c[i][1], d: d / B.sd });
        }
        return out;
    }

    // </draw>

    function step() {
        var now = Date.now();
        var dt = last ? Math.min((now - last) / 1000, 0.1) : 0.033;
        last = now;
        t += dt;
        phase = (t % 25) * 0.2513274;
        // A slow wander, whole pixels only: about one pixel every five seconds.
        wx = Math.round(-96 + 90 * Math.sin(t * 0.0021));
        wy = Math.round(-54 + 50 * Math.sin(t * 0.0033 + 1));
    }

    function two(n) { return (n < 10 ? "0" : "") + n; }

    // Repaints the clock's stars when the minute changes.
    function updateClock() {
        var d = new Date(), s = two(d.getHours()) + ":" + two(d.getMinutes());
        if (s === clockText) return;
        clockText = s;
        clockMap.requestPaint();
    }

    // Moves the clock to another place well clear of the Milky Way and its
    // glow (at least 3.2 band widths), out of twelve: corners, along the top
    // and bottom, and halfway up each side. Always at least the three
    // clearest to choose from, so the clock keeps moving around.
    function placeClock() {
        var spots = clockSpots(seed, mapW, mapH, clockW, clockH), order = [], ok = [], i;
        for (i = 0; i < spots.length; i++) order.push(i);
        order.sort(function (a, b) { return spots[b].d - spots[a].d; });
        for (i = 0; i < order.length; i++)
            if ((i < 3 || spots[order[i]].d >= 3.2) && order[i] !== clockSlot) ok.push(order[i]);
        clockSlot = ok[Math.floor(Math.random() * ok.length)];
        clockBox.x = spots[clockSlot].x;
        clockBox.y = spots[clockSlot].y;
    }

    // The two sky layers. Each paints its star map (data, never shown
    // itself) and the Milky Way's glow from its own seed, and shows the
    // stars over the glow, one map pixel to one screen pixel. The front one
    // wanders; during a pan it slides away and fades while the other slides
    // in from the same side. The hidden one is only shown while panning.
    Repeater {
        id: skies
        model: 2
        delegate: Item {
            id: layer
            property int lseed: index === 0 ? win.seedA : win.seedB
            property bool isFront: index === win.front
            // How many of its two canvases have painted the current seed.
            property int painted: 0
            // The next sky: drawn over the current one, blending in at the
            // edge nearest it.
            property real famt: isFront ? 0 : win.blend
            property real fdir: win.panDir
            property real fw: win.overlap / win.mapW
            z: isFront ? 0 : 1
            width: win.mapW
            height: win.mapH
            visible: isFront || win.panning
            opacity: isFront ? 1 : win.arrive
            x: Math.round(win.wx + (isFront ? -win.pan : 1 - win.pan) * win.panDir * (win.mapW - win.overlap))
            y: win.wy
            onLseedChanged: { painted = 0; lmap.requestPaint(); lglow.requestPaint(); }

            Canvas {
                id: lmap
                width: win.mapW
                height: win.mapH
                renderTarget: Canvas.Image
                onPaint: {
                    var ctx = getContext("2d");
                    if (layer.lseed === 0) ctx.clearRect(0, 0, width, height);
                    else win.paintStars(ctx, width, height, layer.lseed);
                }
                onPainted: layer.painted++
            }
            ShaderEffectSource { id: lmapTex; sourceItem: lmap; hideSource: true; smooth: false }

            Canvas {
                id: lglow
                width: Math.round(win.mapW * win.glowScale)
                height: Math.round(win.mapH * win.glowScale)
                renderTarget: Canvas.Image
                onPaint: {
                    var ctx = getContext("2d");
                    if (layer.lseed === 0) ctx.clearRect(0, 0, width, height);
                    else win.paintGlow(ctx, win.mapW, win.mapH, layer.lseed, win.glowScale);
                }
                onPainted: layer.painted++
            }
            ShaderEffectSource { id: lglowTex; sourceItem: lglow; hideSource: true; smooth: true }

            // Black under the next sky only.
            ShaderEffect {
                width: win.mapW
                height: win.mapH
                visible: !layer.isFront
                property real famt: layer.famt
                property real fdir: layer.fdir
                property real fw: layer.fw
                fragmentShader: win.backShader
            }
            ShaderEffect {
                width: win.mapW
                height: win.mapH
                property variant glow: lglowTex
                property real gain: win.gain
                property real famt: layer.famt
                property real fdir: layer.fdir
                property real fw: layer.fw
                fragmentShader: win.glowShader
            }
            ShaderEffect {
                width: win.mapW
                height: win.mapH
                property variant stars: lmapTex
                property real phase0: win.phase
                property real gain: win.gain
                property real famt: layer.famt
                property real fdir: layer.fdir
                property real fw: layer.fw
                fragmentShader: win.starShader
            }
        }
    }

    // The clock's layer, over the skies and wandering with them.
    Item {
        id: clockLayer
        x: win.wx
        y: win.wy
        width: win.mapW
        height: win.mapH

        // The star clock: HH:MM in stars, over the skies.
        Item {
            id: clockBox
            width: win.clockW
            height: win.clockH
            opacity: 0
            // A patch of sky dimmed for the clock: the stars and glow behind
            // it fade to about half towards its middle, softly at the edges,
            // so the clock stands out a little but still sits in the sky.
            ShaderEffect {
                x: -60
                y: -60
                width: win.clockW + 120
                height: win.clockH + 120
                fragmentShader: "
                    uniform lowp float qt_Opacity;
                    varying highp vec2 qt_TexCoord0;
                    void main() {
                        highp vec2 d = abs(qt_TexCoord0 - vec2(0.5)) * 2.0;
                        highp float e = length(max(d - vec2(0.45), vec2(0.0))) / 0.55;
                        highp float a = 1.0 - smoothstep(0.0, 1.0, e);
                        gl_FragColor = vec4(0.0, 0.0, 0.0, a * 0.55) * qt_Opacity;
                    }"
            }
            Canvas {
                id: clockMap
                width: win.clockW
                height: win.clockH
                renderTarget: Canvas.Image
                onPaint: win.paintClock(getContext("2d"), width, height, win.clockText, win.seed)
            }
            ShaderEffectSource { id: clockTex; sourceItem: clockMap; hideSource: true; smooth: false }
            ShaderEffect {
                width: win.clockW
                height: win.clockH
                property variant stars: clockTex
                property real phase0: win.phase
                property real gain: win.gain
                property real famt: 0
                property real fdir: 1
                property real fw: 0.3
                fragmentShader: win.starShader
            }
        }
    }

    // A shooting star, far off: a small bright head with a faint halo,
    // leading a fine tail that stretches out behind it as it streaks and fades.
    Item {
        id: meteor
        property real angle: 0
        property real trail: 0
        visible: false
        opacity: 0
        Item {
            rotation: meteor.angle - 90
            Rectangle {
                width: 6
                height: meteor.trail * 0.7
                x: -3
                y: -height
                radius: 3
                gradient: Gradient {
                    GradientStop { position: 0.0; color: "#00aac8ff" }
                    GradientStop { position: 1.0; color: "#30c8dcff" }
                }
            }
            Rectangle {
                width: 2
                height: meteor.trail
                x: -1
                y: -height
                radius: 1
                gradient: Gradient {
                    GradientStop { position: 0.0; color: "#00ffffff" }
                    GradientStop { position: 0.75; color: "#44dce6ff" }
                    GradientStop { position: 1.0; color: "#e6ffffff" }
                }
            }
            Rectangle { width: 5; height: 5; radius: 2.5; x: -2.5; y: -3.5; color: "#a0ffffff" }
        }
    }
    // Half a second across. It flares in on an ease-out, glows, and dies away
    // on a slow ease-in-out, while its tail draws out to full length.
    ParallelAnimation {
        id: fly
        NumberAnimation { id: flyX; target: meteor; property: "x"; duration: 500 }
        NumberAnimation { id: flyY; target: meteor; property: "y"; duration: 500 }
        SequentialAnimation {
            NumberAnimation { target: meteor; property: "opacity"; from: 0; to: win.gain * 0.8; duration: 160; easing.type: Easing.OutCubic }
            PauseAnimation { duration: 120 }
            NumberAnimation { target: meteor; property: "opacity"; to: 0; duration: 220; easing.type: Easing.InOutSine }
        }
        SequentialAnimation {
            NumberAnimation { target: meteor; property: "trail"; from: 0; to: 280; duration: 300; easing.type: Easing.OutCubic }
            PauseAnimation { duration: 200 }
        }
        onStopped: meteor.visible = false
    }
    function launchMeteor() {
        // Down and to the right or down and to the left, from the upper sky.
        var deg = Math.random() < 0.5 ? 25 + Math.random() * 30 : 125 + Math.random() * 30;
        // Far away, it covers less of the sky in its half second.
        var rad = deg * Math.PI / 180, d = 300 + Math.random() * 250;
        var x0 = 200 + Math.random() * 1520, y0 = 60 + Math.random() * 400;
        meteor.angle = deg;
        flyX.from = x0; flyX.to = x0 + Math.cos(rad) * d;
        flyY.from = y0; flyY.to = y0 + Math.sin(rad) * d;
        meteor.opacity = 0;
        meteor.trail = 0;
        meteor.visible = true;
        fly.restart();
    }

    // 30 updates a second; a shooting star every 40 to 120 seconds.
    Timer { interval: 33; running: true; repeat: true; onTriggered: win.step() }
    Timer {
        interval: 40000 + Math.random() * 80000
        running: true
        repeat: true
        onTriggered: { win.launchMeteor(); interval = 40000 + Math.random() * 80000; }
    }

    // The clock: checked every second, and every 10 minutes it fades out,
    // moves to another clear part of the sky, and fades back in.
    Timer { interval: 1000; running: true; repeat: true; onTriggered: win.updateClock() }
    SequentialAnimation {
        id: hop
        NumberAnimation { target: clockBox; property: "opacity"; to: 0; duration: 2000; easing.type: Easing.InOutSine }
        ScriptAction { script: win.placeClock() }
        NumberAnimation { target: clockBox; property: "opacity"; to: 1; duration: 2000; easing.type: Easing.InOutSine }
    }
    Timer { interval: 600000; running: true; repeat: true; onTriggered: if (!win.panning) hop.restart() }

    // Every 30 to 40 minutes, a new sky: the clock fades out, the next sky is painted
    // into the hidden layer, beside the current one to the left or right,
    // and once it is ready the camera pans along to it over about 30
    // seconds. The seam where the two skies overlap travels across the
    // screen with the camera; at the end what is left of it dissolves.
    function newSky() {
        if (panning) return;
        // Keep the hidden layer invisible until the new sky is painted in it.
        arrive = 0;
        panning = true;
        hop.stop();
        skyOut.restart();
    }
    function prepareSky() {
        panDir = Math.random() < 0.5 ? 1 : -1;
        nextSeed = matchSeed(seed, panDir, mapW, mapH, overlap, Math.random);
        pan = 0;
        blend = 1;
        arrive = 0;
        if (front === 0) seedB = nextSeed; else seedA = nextSeed;
        readyWait.tries = 0;
        readyWait.restart();
    }
    // The new sky shows from here on: it becomes the front layer, already
    // sitting where the pan left it.
    function finishSky() {
        front = 1 - front;
        seed = nextSeed;
        pan = 0;
        blend = 1;
        arrive = 0;
        panning = false;
        clockSlot = -1;
        placeClock();
        clockMap.requestPaint();
    }
    SequentialAnimation {
        id: skyOut
        NumberAnimation { target: clockBox; property: "opacity"; to: 0; duration: 2000; easing.type: Easing.InOutSine }
        ScriptAction { script: win.prepareSky() }
    }
    // Waits for both canvases of the new sky to have painted (at most ten
    // seconds), then pans.
    Timer {
        id: readyWait
        property int tries: 0
        interval: 250
        repeat: true
        onTriggered: {
            tries++;
            if (skies.itemAt(1 - win.front).painted >= 2 || tries > 40) {
                stop();
                panMove.restart();
            }
        }
    }
    SequentialAnimation {
        id: panMove
        PauseAnimation { duration: 500 }
        // The camera sets off slowly while the edge of the next sky, already
        // in view, softly comes up; then it glides along and settles.
        ParallelAnimation {
            NumberAnimation { target: win; property: "arrive"; from: 0; to: 1; duration: 5000; easing.type: Easing.InOutSine }
            NumberAnimation { target: win; property: "pan"; from: 0; to: 1; duration: 32000; easing.type: Easing.InOutSine }
        }
        // What is left of the seam dissolves into the new sky.
        NumberAnimation { target: win; property: "blend"; from: 1; to: 0; duration: 4000; easing.type: Easing.InOutSine }
        ScriptAction { script: win.finishSky() }
        PauseAnimation { duration: 1000 }
        NumberAnimation { target: clockBox; property: "opacity"; to: 1; duration: 2000; easing.type: Easing.InOutSine }
    }
    // A new sky every 30 to 40 minutes, a different wait each time.
    Timer {
        interval: 1800000 + Math.random() * 600000
        running: true
        repeat: true
        onTriggered: { win.newSky(); interval = 1800000 + Math.random() * 600000; }
    }

    Component.onCompleted: {
        seedA = seed;
        t = Math.random() * 3600;
        step();
        updateClock();
        hop.restart();
    }
}
