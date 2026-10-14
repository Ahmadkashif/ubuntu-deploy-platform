export const dynamic = "force-dynamic";
export function GET() {
  return Response.json({ status: "ok", version: process.env.SHIP_VERSION });
}
