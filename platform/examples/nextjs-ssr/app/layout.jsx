export const metadata = { title: "Next.js SSR example" };
export default function RootLayout({ children }) {
  return (
    <html lang="en">
      <body>
        <nav><a href="/">Home</a> · <a href="/about">About</a></nav>
        {children}
        <footer>nextjs-ssr · version <span id="v">{process.env.SHIP_VERSION}</span></footer>
      </body>
    </html>
  );
}
