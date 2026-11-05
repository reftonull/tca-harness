window.traceReady.then(() => {
  const checks = [];
  const check = (label, value) => checks.push([label, !!value]);
  const api = window.runExplorer;
  const root = document.getElementById("run-explorer");
  check(
    "failed goal selected initially",
    document.getElementById("goal-status").textContent.startsWith("failed"),
  );
  document.querySelectorAll("#goals button")[0].click();
  check(
    "goal button selects the goal",
    document.getElementById("goal-title").textContent ===
      "comfortable settings",
  );
  const goal = api.data.goals[0];
  const decision = goal.events.find(
    (e) => e.kind === "model" && String(e.candidate).includes("/darkMode@"),
  );
  api.selectEvent(decision.id);
  check(
    "event selection updates inspector",
    document.querySelector("#inspector h2").textContent ===
      "root/home/settings/darkMode",
  );
  if (api.data.snapshotCount > 8) {
    check(
      "offered alternatives are inspectable",
      [...document.querySelectorAll("#inspector summary")].some((n) =>
        n.textContent.includes("offered operations"),
      ),
    );
    const volume = goal.events.find(
      (e) =>
        e.kind === "action" && String(e.candidate).includes("/musicVolume@"),
    );
    api.selectEvent(volume.id);
    check(
      "numeric argument visible",
      document.getElementById("inspector").textContent.includes("0.25"),
    );
    check(
      "state change shows actual volume",
      document.querySelector(".state-list").textContent.includes("musicVolume"),
    );
    const before = volume.before.settings.musicVolume,
      after = volume.after.settings.musicVolume;
    check(
      "state comparison uses actual snapshots",
      before === 1 && after === 0.25,
    );
    check(
      "timing chart renders measured spans",
      document.querySelectorAll("#timing rect").length > 0,
    );
  } else {
    check(
      "legacy timing gap is explicit",
      document
        .getElementById("timing")
        .textContent.includes("did not record timestamps"),
    );
  }
  const delta = api.stateDiff(
    { a: [1, null], unchanged: true },
    { a: [2, { x: 3 }], unchanged: true },
  );
  check(
    "nested and nullable state diff",
    delta.length === 2 && delta[0].before === 1 && delta[0].after === 2,
  );
  const absent = api.stateDiff({ secret: "gone" }, {});
  check(
    "removed fields remain distinguishable",
    absent.length === 1 && absent[0].after === undefined,
  );
  const mechanical = document.getElementById("mechanical");
  if (!mechanical.hidden) {
    mechanical.click();
    check(
      "mechanical/pacing toggle works",
      mechanical.textContent.startsWith("Hide"),
    );
  } else {
    check("empty mechanical controls stay hidden", mechanical.hidden);
  }
  api.data.goals.forEach((g, index) => {
    api.selectGoal(index);
    for (const event of g.events) {
      api.selectEvent(event.id);
      if (!document.querySelector("#inspector h2").textContent)
        throw new Error("Missing event detail " + event.id);
    }
  });
  check("every event has readable detail", true);
  check(
    "no horizontal viewport overflow",
    document.documentElement.scrollWidth <= innerWidth,
  );
  api.selectGoal(0);
  const volume = api.data.goals[0].events.find(
    (e) => e.kind === "action" && String(e.candidate).includes("/musicVolume@"),
  );
  if (volume) api.selectEvent(volume.id);
  console.log("RUN_VIEWER_CHECKS " + JSON.stringify(checks));
  console.log(
    "CHECK_SUMMARY " +
      checks.filter((c) => c[1]).length +
      "/" +
      checks.length +
      " passed",
  );
  if (checks.some((c) => !c[1]))
    throw new Error("Run viewer interaction checks failed");
});
