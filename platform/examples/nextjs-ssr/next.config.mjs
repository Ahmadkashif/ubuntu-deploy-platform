/** @type {import('next').NextConfig} */
const nextConfig = {
  output: "standalone",     // self-contained server.js + minimal node_modules
  poweredByHeader: false,
  env: { SHIP_VERSION: process.env.SHIP_VERSION ?? "dev" },
};
export default nextConfig;
