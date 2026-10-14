"use client";
import { useEffect, useState } from "react";
export default function Counter() {
  const [n, setN] = useState(0);
  const [hydrated, setHydrated] = useState(false);
  useEffect(() => setHydrated(true), []);
  return (
    <div>
      <p id="js-status">{hydrated ? "Hydrated under the edge CSP." : "Server HTML (not hydrated yet)."}</p>
      <button type="button" onClick={() => setN(n + 1)}>Clicked {n} times</button>
    </div>
  );
}
