// Example page script for the devtools panel (isowords). Run inside the page during a recording
// to pause on actions and caption what each tab shows. Rows are found by action name, not position:
// the log re-renders on every poll and new entries shift rows.
(async () => {
  const wait = (ms) => new Promise(r => setTimeout(r, ms));
  const cap = document.createElement('div');
  cap.style.cssText = 'position:fixed;left:50%;bottom:56px;transform:translateX(-50%);background:#a98bf5;color:#161827;font:600 15px ui-monospace,Menlo,monospace;padding:8px 16px;border-radius:8px;z-index:9;box-shadow:0 6px 24px #0008;transition:opacity .2s';
  document.body.append(cap);
  const say = (t) => { cap.textContent = t; };
  const row = (re) => [...document.querySelectorAll('#rows .row')].find(r => re.test(r.querySelector('.name').textContent));
  const tab = (n) => document.querySelector(`[data-tab="${n}"]`).click();
  say('Click the agent\'s submit action: the log pauses, the app keeps running');
  row(/submitButtonTapped$/).click(); await wait(3500);
  say('Diff: what the submit changed in the state agents see, old → new');
  tab('diff'); await wait(4000);
  say('Action: agent operation ID, recorder cost; payload values stay hidden');
  tab('action'); await wait(3500);
  say('Mounts: operations the agent can use after this action');
  tab('mounts'); await wait(4000);
  say('A timer tick was sent by an effect…');
  [...document.querySelectorAll('#rows .row')].filter(r => /timerTick$/.test(r.querySelector('.name').textContent)).at(-3).click();
  tab('effects'); await wait(3500);
  say('…started by gameLoaded, which is still running and has sent every tick');
  document.querySelector('#panel .link').click(); await wait(4000);
  tab('state');
  say('Filter to actions the agent dispatched');
  const src = document.getElementById('source'); src.value = 'agent'; src.dispatchEvent(new Event('change')); await wait(3500);
  src.value = ''; src.dispatchEvent(new Event('change'));
  say('Scrub through history');
  const scrub = document.getElementById('scrub');
  for (let i = 0; i <= 32; i++) { scrub.value = String(i); scrub.dispatchEvent(new Event('input')); await wait(140); }
  await wait(1200);
  say('Esc returns to live');
  document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' })); await wait(3000);
  cap.remove();
})();
