// Example page script for the devtools panel. Run inside the page during a recording to pause on
// actions and caption what each tab shows. Rows are found by action name, not position: the log
// re-renders on every poll and new entries shift rows.
//
// Set the two action names for your app. The defaults fit the Shelf example (examples/shelf) after
// an agent adds a book: `tca do 'Add book'`, `tca do 'Set title' '{"value":"Dune"}'`, `tca do Save`.
const PROOF = /saveButtonTapped$/;   // the action that proves the behavior
const EFFECT = /saveResponse$/;      // an action sent by that action's effect
(async () => {
  const wait = (ms) => new Promise(r => setTimeout(r, ms));
  const cap = document.createElement('div');
  cap.style.cssText = 'position:fixed;left:50%;bottom:56px;transform:translateX(-50%);background:#a98bf5;color:#161827;font:600 15px ui-monospace,Menlo,monospace;padding:8px 16px;border-radius:8px;z-index:9;box-shadow:0 6px 24px #0008;transition:opacity .2s';
  document.body.append(cap);
  const say = (t) => { cap.textContent = t; };
  const rows = (re) => [...document.querySelectorAll('#rows .row')].filter(r => re.test(r.querySelector('.name').textContent));
  const tab = (n) => document.querySelector(`[data-tab="${n}"]`).click();
  say('Click the action that proves it: the log pauses, the app keeps running');
  rows(PROOF)[0].click(); await wait(3500);
  say('Diff: what the action changed in the state agents see, old → new');
  tab('diff'); await wait(4000);
  say('Action: agent operation ID, recorder cost; payload values stay hidden');
  tab('action'); await wait(3500);
  say('Mounts: operations the agent can use after this action');
  tab('mounts'); await wait(4000);
  say('This action was sent by an effect…');
  rows(EFFECT)[0].click();
  tab('effects'); await wait(3500);
  say('…started by the action that returned it');
  document.querySelector('#panel .link')?.click(); await wait(4000);
  tab('state');
  say('Filter to actions the agent dispatched');
  const src = document.getElementById('source'); src.value = 'agent'; src.dispatchEvent(new Event('change')); await wait(3500);
  src.value = ''; src.dispatchEvent(new Event('change'));
  say('Scrub through history');
  const scrub = document.getElementById('scrub');
  for (let i = 0; i <= Number(scrub.max || 32); i++) { scrub.value = String(i); scrub.dispatchEvent(new Event('input')); await wait(140); }
  await wait(1200);
  say('Esc returns to live');
  document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' })); await wait(3000);
  cap.remove();
})();
