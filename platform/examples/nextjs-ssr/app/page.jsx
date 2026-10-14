import Counter from "./components/Counter";
import { echo } from "./actions";
export const dynamic = "force-dynamic";   // real SSR on every request
export default function Page() {
  return (
    <main>
      <h1>Next.js SSR behind the ship edge</h1>
      <p>Rendered on the server at <time id="t">{new Date().toISOString()}</time></p>
      <Counter />
      <form action={async (fd) => { "use server"; await echo(fd); }}>
        <input name="msg" defaultValue="hello" /> <button type="submit">Server action</button>
      </form>
    </main>
  );
}
