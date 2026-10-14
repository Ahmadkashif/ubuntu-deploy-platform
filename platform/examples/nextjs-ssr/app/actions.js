"use server";
// Server Action (POST with the Next-Action header) — exercises the WAF with Next.js' action protocol.
export async function echo(formData) {
  const msg = String(formData.get("msg") ?? "").slice(0, 200);
  return { ok: true, length: msg.length };
}
