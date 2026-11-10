// Drives cli/devtools.html in jsdom against a timeline recorded from a word-game app.
// Usage: NODE_PATH=/path/with/jsdom/node_modules node devtools_checks.js
const fs = require("fs");
const path = require("path");
const { JSDOM } = require("jsdom");

const html = fs.readFileSync(path.join(__dirname, "../devtools.html"), "utf8");
const fixture = JSON.parse(fs.readFileSync(path.join(__dirname, "fixtures/devtools-timeline.json"), "utf8"));
const empty = { ok: true, timeline: { ...fixture.timeline, entries: [], hasMore: false } };
const respond = (body) => Promise.resolve({ json: () => Promise.resolve(body) });
const dom = new JSDOM(html, {
  runScripts: "dangerously", url: "http://127.0.0.1:8780/", pretendToBeVisual: true,
  beforeParse(window) {
    window.fetch = (url) => respond(url.endsWith("since=0") ? fixture : empty);
    window.Element.prototype.scrollIntoView = () => {};
    window.navigator.clipboard = { writeText: () => Promise.resolve() };
  },
});
const w = dom.window, d = w.document;
const results = [];
const check = (label, ok, detail = "") => results.push([label, !!ok, detail]);
const rows = () => [...d.querySelectorAll("#rows .row")];
const row = (re) => rows().find((r) => re.test(r.querySelector(".name").textContent));
const tab = (name) => d.querySelector(`[data-tab="${name}"]`).click();
const panel = () => d.getElementById("panel").textContent;
const selected = () => d.querySelector('[aria-current="true"] .name').textContent;
const key = (k) => d.dispatchEvent(new w.KeyboardEvent("keydown", { key: k }));

setTimeout(() => {
  const count = fixture.timeline.entries.length;
  check("renders every entry newest first", rows().length === count && rows()[0].dataset.index === String(count - 1));
  check("starts live", d.getElementById("mode").textContent === "Live");
  check("header shows detail and recorder cost", /projected state.*recorder .* in reducer, .* to snapshot/.test(d.getElementById("meta").textContent));

  row(/submitButtonTapped$/).click();
  check("selecting pauses", /^Paused \(\d+\)$/.test(d.getElementById("mode").textContent));
  check("changed branches are marked", d.querySelectorAll("#panel .tree-row.changed").length > 0);
  tab("diff");
  check("diff shows old and new values", d.querySelectorAll("#panel .change .old").length > 0 && d.querySelectorAll("#panel .change .new").length > 0);
  tab("action");
  check("action shows agent operation", panel().includes("Agent dispatch") && panel().includes("/submit@"));
  check("projected payload hides values", panel().includes("values hidden"));
  check("recorder cost is shown", panel().includes("Recorder"));
  tab("mounts");
  check("mounts list features and operations", d.querySelectorAll("#panel .mount").length > 0 && d.querySelectorAll("#panel .ops li").length > 0);

  row(/timerTick$/).click();
  tab("effects");
  check("effect-sent action links its cause", panel().includes("Triggered by") && panel().includes("gameLoaded"));
  d.querySelector("#panel .link").click();
  check("cause link selects the cause", /gameLoaded$/.test(selected()));
  check("cause lists actions its effect sent", d.querySelectorAll("#panel .change").length >= 5);

  const source = d.getElementById("source");
  source.value = "agent"; source.dispatchEvent(new w.Event("change"));
  check("source filter", rows().length > 0 && rows().every((r) => r.textContent.includes("agent")));
  source.value = ""; source.dispatchEvent(new w.Event("change"));
  const query = d.getElementById("query");
  query.value = "TAP"; query.dispatchEvent(new w.Event("input"));
  check("name filter is case-insensitive", rows().length > 0 && rows().every((r) => /tap/i.test(r.textContent)));
  query.value = ""; query.dispatchEvent(new w.Event("input"));

  const scrub = d.getElementById("scrub");
  scrub.value = "0"; scrub.dispatchEvent(new w.Event("input"));
  check("scrubber selects the oldest entry", d.querySelector('[aria-current="true"]').dataset.index === "0");
  key("ArrowUp");
  check("arrow up moves to a newer entry", d.querySelector('[aria-current="true"]').dataset.index === "1");
  key("Escape");
  check("escape resumes live", d.getElementById("mode").textContent === "Live" && d.getElementById("resume").hidden);

  for (const [label, ok, detail] of results) console.log((ok ? "PASS " : "FAIL ") + label + (detail ? " — " + detail : ""));
  process.exit(results.every(([, ok]) => ok) ? 0 : 1);
}, 300);
