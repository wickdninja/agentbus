/* Terminal frames for the storyboard, drawn by xterm.js from the captured or mocked ANSI.
   <figure class="term" data-frame="ID" data-set="captured|mocked"> draws one frame.
   <figure class="term" data-seq="ID@0,ID@1000,ID@3000" data-set="mocked"> plays frames at those times (ms). */
(function () {
  "use strict";

  var THEMES = {
    dark: {
      background: "#12141a", foreground: "#e3e6ec", cursor: "#12141a", cursorAccent: "#12141a",
      selectionBackground: "#3a3f4b",
      black: "#1c1f27", red: "#ff6b6b", green: "#5fd38d", yellow: "#ffc533", blue: "#5aa9ff",
      magenta: "#d68cff", cyan: "#4fd6e0", white: "#d8dde6",
      brightBlack: "#6b7280", brightRed: "#ff9b9b", brightGreen: "#8ef0b0", brightYellow: "#ffe08a",
      brightBlue: "#8cc4ff", brightMagenta: "#e9b8ff", brightCyan: "#8ff0f5", brightWhite: "#ffffff"
    },
    light: {
      background: "#fdfcf8", foreground: "#1f2328", cursor: "#fdfcf8", cursorAccent: "#fdfcf8",
      selectionBackground: "#e6dfc8",
      black: "#1f2328", red: "#c62828", green: "#2b8a3e", yellow: "#b58900", blue: "#1f6fd1",
      magenta: "#a33ea1", cyan: "#12818a", white: "#8c959f",
      brightBlack: "#6e7781", brightRed: "#e5534b", brightGreen: "#3fa45a", brightYellow: "#c99a06",
      brightBlue: "#3d8bfd", brightMagenta: "#c25ec0", brightCyan: "#1b9aa3", brightWhite: "#57606a"
    }
  };

  function theme(fig) {
    var forced = fig && fig.getAttribute("data-term-theme");
    if (forced === "light" || forced === "dark") return forced;
    var t = document.documentElement.getAttribute("data-theme");
    if (t === "light" || t === "dark") return t;
    return window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
  }

  function frame(set, id) {
    var src = set === "mocked" ? window.MOCKED : window.CAPTURED;
    return src && src[id];
  }

  // A page can rename the badges and the switch: window.SB_LABELS = {captured: ..., mocked: ...}, window.SB_NEW = "W1".
  var LABEL = Object.assign({
    captured: "captured from the real tool",
    edited: "captured, one line edited",
    mocked: "mocked: the PR B design",
    drawn: "drawn: Codex's screen"
  }, window.SB_LABELS || {});
  var NEW = window.SB_NEW || "PR B";

  var terms = [];

  // Under this width the terminal keeps its real size and scrolls sideways inside its card.
  var PHONE = window.matchMedia ? window.matchMedia("(max-width: 700px)") : { matches: false };

  function cue(t) {
    var b = t.box, more = b.scrollWidth - b.clientWidth - b.scrollLeft > 2;
    t.wrap.classList.toggle("more", b.classList.contains("scrolls") && more);
  }

  function fit(t) {
    var outer = t.box, inner = t.inner, fig = t.fig;
    inner.style.marginRight = "0px";
    fig.style.maxWidth = "";
    var natural = inner.scrollWidth, h = inner.scrollHeight;
    if (!natural) return;
    if (PHONE.matches) {
      // Real column count, real font size: the card scrolls, nothing is shrunk or clipped.
      outer.classList.toggle("scrolls", natural > outer.clientWidth + 1);
      inner.style.transform = "";
      outer.style.height = Math.ceil(h) + "px";
      cue(t);
      return;
    }
    // Fit the width, but never below 60%.
    var s = Math.max(0.6, Math.min(1, outer.clientWidth / natural));
    outer.classList.toggle("scrolls", s * natural > outer.clientWidth + 1);
    inner.style.transform = "scale(" + s + ")";
    inner.style.marginRight = Math.floor(natural * s - natural) + "px";  // the layout box shrinks with the picture
    outer.style.height = Math.ceil(h * s) + "px";
    fig.style.maxWidth = Math.ceil(natural * s) + 2 + "px";
    cue(t);
  }

  function make(fig) {
    var set = fig.getAttribute("data-set") || "captured";
    var seq = fig.getAttribute("data-seq");
    var compare = fig.getAttribute("data-compare");
    if (compare) {
      // "captured:ID,mocked:ID": one terminal, a switch between today and PR B. Starts on PR B.
      var pairs = compare.split(",").map(function (p) { var b = p.split(":"); return { set: b[0], id: b[1] }; });
      set = pairs[pairs.length - 1].set;
      fig.setAttribute("data-frame", pairs[pairs.length - 1].id);
    }
    var steps = seq ? seq.split(",").map(function (p) {
      var bits = p.split("@");
      return { id: bits[0], at: Number(bits[1] || 0) };
    }) : [{ id: fig.getAttribute("data-frame"), at: 0 }];
    var first = frame(set, steps[0].id);
    if (!first) {
      fig.innerHTML = '<p class="missing">Frame ' + steps[0].id + " is missing: run storyboard/capture/capture.py.</p>";
      return;
    }
    var source = first.source || set;
    var bar = document.createElement("div");
    bar.className = "term-bar";
    bar.innerHTML = '<span class="dims">' + first.cols + " × " + first.rows + "</span>" +
      '<span class="cmd"></span>' +
      '<span class="badge badge-' + source + '">' + LABEL[source] + "</span>";
    bar.querySelector(".cmd").textContent = fig.getAttribute("data-title") || first.cmd;
    var box = document.createElement("div");
    box.className = "term-box";
    var inner = document.createElement("div");
    inner.className = "term-inner";
    box.appendChild(inner);
    var wrap = document.createElement("div");
    wrap.className = "term-wrap";
    wrap.appendChild(box);
    fig.appendChild(bar);
    fig.appendChild(wrap);
    box.addEventListener("scroll", function () { cue(t); }, { passive: true });
    if (compare) {
      var sw = document.createElement("div");
      sw.className = "switch";
      sw.setAttribute("role", "group");
      sw.setAttribute("aria-label", "Today or " + NEW);
      pairs.forEach(function (p, i) {
        var b = document.createElement("button");
        b.type = "button";
        b.textContent = p.set === "mocked" ? NEW : "Today";
        b.setAttribute("aria-pressed", String(i === pairs.length - 1));
        b.addEventListener("click", function () {
          sw.querySelectorAll("button").forEach(function (x) { x.setAttribute("aria-pressed", String(x === b)); });
          t.set = p.set;
          t.steps = [{ id: p.id, at: 0 }];
          var f = frame(p.set, p.id);
          var badge = bar.querySelector(".badge");
          badge.className = "badge badge-" + (f.source || p.set);
          badge.textContent = LABEL[f.source || p.set];
          show(t, 0);
        });
        sw.appendChild(b);
      });
      bar.insertBefore(sw, bar.querySelector(".badge"));
    }
    var cap = fig.getAttribute("data-caption");
    var stamp = null;
    if (seq) {
      var controls = document.createElement("div");
      controls.className = "term-controls";
      controls.innerHTML = '<button type="button" class="play">Play at real speed</button><span class="stamp"></span>';
      fig.appendChild(controls);
      stamp = controls.querySelector(".stamp");
    }
    if (cap) {
      var fc = document.createElement("figcaption");
      fc.textContent = cap;
      fig.appendChild(fc);
    }
    var term = new window.Terminal({
      cols: first.cols, rows: first.rows, allowProposedApi: true, disableStdin: true,
      cursorBlink: false, cursorStyle: "bar", cursorWidth: 1, scrollback: 0,
      fontFamily: '"JetBrains Mono", ui-monospace, Menlo, monospace', fontSize: 13, lineHeight: 1.15,
      theme: THEMES[theme(fig)], drawBoldTextInBrightColors: false, minimumContrastRatio: 1
    });
    if (window.Unicode11Addon) {
      term.loadAddon(new window.Unicode11Addon.Unicode11Addon());
      term.unicode.activeVersion = "11";
    }
    term.open(inner);
    box.style.background = THEMES[theme(fig)].background;
    wrap.style.setProperty("--term-bg", THEMES[theme(fig)].background);
    var t = { term: term, fig: fig, wrap: wrap, box: box, inner: inner, steps: steps, set: set, stamp: stamp, timers: [] };
    terms.push(t);
    show(t, 0);
    setTimeout(function () { fit(t); }, 30);
    if (seq) {
      fig.querySelector(".play").addEventListener("click", function () { play(t); });
    }
  }

  function show(t, i) {
    var f = frame(t.set, t.steps[i].id);
    t.term.reset();
    t.term.write("\x1b[?25l" + f.ansi.replace(/\r?\n/g, "\r\n"));
    if (t.stamp) t.stamp.textContent = f.note || "";
  }

  function play(t) {
    t.timers.forEach(clearTimeout);
    t.timers = [];
    t.steps.forEach(function (s, i) {
      t.timers.push(setTimeout(function () { show(t, i); }, s.at));
    });
  }

  function retheme() {
    terms.forEach(function (t) { var th = THEMES[theme(t.fig)]; t.term.options.theme = th; t.box.style.background = th.background; t.wrap.style.setProperty("--term-bg", th.background); });
  }

  function start() {
    document.querySelectorAll("figure.term").forEach(make);
    window.addEventListener("resize", function () { terms.forEach(fit); });
    if (window.matchMedia) {
      window.matchMedia("(prefers-color-scheme: dark)").addEventListener("change", retheme);
    }
    document.addEventListener("sb-theme", retheme);
  }

  // Theme switch: auto (the system), light, dark. A remembered choice is a convenience only.
  function setTheme(v) {
    if (v === "light" || v === "dark") document.documentElement.setAttribute("data-theme", v);
    else document.documentElement.removeAttribute("data-theme");
    document.querySelectorAll("[data-theme-set]").forEach(function (b) {
      b.setAttribute("aria-pressed", String(b.getAttribute("data-theme-set") === (v || "auto")));
    });
    document.dispatchEvent(new Event("sb-theme"));
  }
  var q = new URLSearchParams(location.search).get("theme");
  var saved = null;
  try { saved = localStorage.getItem("sb-theme"); } catch (e) { saved = null; }
  setTheme(q || saved || "auto");
  document.addEventListener("click", function (e) {
    var b = e.target.closest && e.target.closest("[data-theme-set]");
    if (!b) return;
    var v = b.getAttribute("data-theme-set");
    try { localStorage.setItem("sb-theme", v); } catch (err) { /* private window */ }
    setTheme(v);
  });

  var fontReady = document.fonts && document.fonts.load ? document.fonts.load('13px "JetBrains Mono"') : Promise.resolve();
  Promise.race([fontReady, new Promise(function (r) { setTimeout(r, 1500); })]).then(function () {
    if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", start);
    else start();
  });
})();
