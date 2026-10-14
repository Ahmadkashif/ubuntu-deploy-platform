// Drives headless Chromium over the DevTools protocol (no npm deps; Node >= 22 has a global WebSocket).
// Loads https://<host>:<port><path>, records CSP violations + console errors, reads #js-status, clicks the first
// <button> and reads its text (proves hydration / event handlers work under the CSP).
// usage: node browser-check.mjs <chrome-ip> <url>
const [chromeIp, url] = process.argv.slice(2);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const tgt = await (await fetch(`http://${chromeIp}:9222/json/new?about:blank`, { method: "PUT" })).json();
const ws = new WebSocket(tgt.webSocketDebuggerUrl.replace("localhost", chromeIp).replace("127.0.0.1", chromeIp));
await new Promise((r) => ws.addEventListener("open", r, { once: true }));
let id = 0; const pending = new Map(); const events = [];
ws.addEventListener("message", (m) => {
  const msg = JSON.parse(m.data);
  if (msg.id && pending.has(msg.id)) { pending.get(msg.id)(msg); pending.delete(msg.id); } else events.push(msg);
});
const send = (method, params = {}) => new Promise((r) => { const i = ++id; pending.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
await send("Runtime.enable"); await send("Log.enable"); await send("Page.enable");
await send("Page.addScriptToEvaluateOnNewDocument", { source:
  "window.__csp=[];document.addEventListener('securitypolicyviolation',e=>window.__csp.push(e.violatedDirective+' '+(e.blockedURI||'inline')));" });
await send("Page.navigate", { url });
await sleep(4000);
const ev = async (expr) => (await send("Runtime.evaluate", { expression: expr, returnByValue: true })).result?.result?.value;
const status = await ev("document.querySelector('#js-status')?.textContent ?? '<no #js-status>'");
const before = await ev("document.querySelector('button')?.textContent ?? '<no button>'");
await ev("document.querySelector('button')?.click()"); await sleep(500);
const after = await ev("document.querySelector('button')?.textContent ?? '<no button>'");
const csp = await ev("JSON.stringify(window.__csp||[])");
const consoleErrors = events.filter((e) => (e.method === "Log.entryAdded" && ["error"].includes(e.params.entry.level)) ||
  (e.method === "Runtime.exceptionThrown")).map((e) => e.params.entry?.text ?? e.params.exceptionDetails?.text);
console.log(JSON.stringify({ url, jsStatus: status, button: { before, after }, cspViolations: JSON.parse(csp || "[]"), consoleErrors }, null, 1));
ws.close(); process.exit(JSON.parse(csp || "[]").length ? 1 : 0);
