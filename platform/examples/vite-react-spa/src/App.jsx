import { useEffect, useState } from "react";

// Minimal client-side router: deep links like /about must be served index.html by the server (SPA fallback).
function usePath() {
  const [path, setPath] = useState(window.location.pathname);
  useEffect(() => {
    const onPop = () => setPath(window.location.pathname);
    window.addEventListener("popstate", onPop);
    return () => window.removeEventListener("popstate", onPop);
  }, []);
  const go = (p) => { window.history.pushState({}, "", p); setPath(p); };
  return [path, go];
}

export default function App() {
  const [path, go] = usePath();
  const [n, setN] = useState(0);
  const [ping, setPing] = useState("…");
  useEffect(() => {
    fetch("/version.json").then((r) => r.json()).then((j) => setPing(j.version)).catch(() => setPing("error"));
  }, []);
  return (
    <main>
      <p id="js-status">React rendered under the strict CSP.</p>
      <nav>
        <a href="/" onClick={(e) => { e.preventDefault(); go("/"); }}>Home</a> ·{" "}
        <a href="/about" onClick={(e) => { e.preventDefault(); go("/about"); }}>About</a>
      </nav>
      {path === "/about" ? <h1>About (client route)</h1> : <h1>Vite + React SPA behind the ship edge</h1>}
      <button type="button" onClick={() => setN(n + 1)}>Clicked {n} times</button>
      <p>Build: <span id="v">{__SHIP_VERSION__}</span> · /version.json: {ping}</p>
    </main>
  );
}
