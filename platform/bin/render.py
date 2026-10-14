#!/usr/bin/env python3
"""Render platform templates for one host profile.

  bin/render.py <profile>              -> build/<profile>/... (+ render-report.txt)
  bin/render.py --all                  -> every profile in profiles/
  bin/render.py --check-agnostic       -> fail if templates contain values unique to the verification profile
  bin/render.py --get <profile> a.b    -> print one profile value (used by up.sh / ship)

Stdlib only (Python >= 3.8). Profiles use a small YAML subset: top-level scalars, one level of sections
(2-space indent), inline lists [a, b], '#' comments. Templates use:
  {{a.b}}  {{a.b | join}}  {{a.b | nftset}}  {{a.b | yamllist}}  {{a.b | spaces}}
  (GitHub/Forgejo expressions written as ${{ ... }} are left untouched)
  line-level blocks: {{#if a.b}} / {{#if a.b == value}} / {{#unless a.b}} / {{#else}} / {{/if}} / {{/unless}}
Unknown or missing profile keys are errors (a typo must never silently render an empty value).
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROFILES = os.path.join(ROOT, "profiles")
TEMPLATES = os.path.join(ROOT, "templates")
BUILD = os.path.join(ROOT, "build")
VERIFY_SUFFIX = "-verify"   # every profile named *-verify is a verification profile (its values must not leak)

SCHEMA = {
    "": ["name", "description", "status", "platform"],
    "minimum": ["os", "arch", "ram_gb", "cpu_cores", "disk_free_gb", "docker_major", "notes"],
    "render": ["host", "relay"],
    "exposure": ["mode", "bind_ip", "http_port", "https_port", "domain", "tls", "acme_email", "acme_staging",
                 "proxy_protocol", "relay_wg_ip", "hsts"],
    "edge": ["project", "public_subnet", "public_gateway", "public_ipv6", "caddy_mem", "crowdsec_mem", "proxy_mem", "registry_mem"],
    "limits": ["rate_events", "rate_window", "max_body", "app_mem", "app_pids", "app_cpus"],
    "crowdsec": ["online_api", "appsec", "ticker", "whitelist"],
    "registry": ["bind", "push"],
    "security": ["scan_fail_on", "sign"],
    "firewall": ["uplink", "public_sources", "ssh_iface", "lan_subnet", "wg_port", "wg_subnet", "host_wg_ip"],
    "relay": ["public_iface", "wg_ip", "home_wg_ip", "wg_port"],
    "ci": ["runner_label"],
}
GROUPS = {"edge": None, "ci": None, "host": "render.host", "relay": "render.relay"}


class RenderError(Exception):
    pass


def _scalar(raw):
    v = raw.strip()
    if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
        return v[1:-1]
    if v.startswith("[") and v.endswith("]"):
        inner = v[1:-1].strip()
        return [_scalar(x) for x in inner.split(",")] if inner else []
    return v


def _strip_comment(line):
    out, q = [], None
    for i, ch in enumerate(line):
        if q:
            if ch == q:
                q = None
        elif ch in "\"'":
            q = ch
        elif ch == "#" and (i == 0 or line[i - 1] in " \t"):
            break
        out.append(ch)
    return "".join(out).rstrip()


def load_profile(name):
    path = os.path.join(PROFILES, name + ".yaml")
    if not os.path.isfile(path):
        raise RenderError("no such profile: %s (have: %s)" % (name, ", ".join(list_profiles())))
    data, section = {}, ""
    for n, line in enumerate(open(path, encoding="utf-8"), 1):
        line = _strip_comment(line.rstrip("\n"))
        if not line.strip():
            continue
        indent = len(line) - len(line.lstrip(" "))
        key, sep, val = line.strip().partition(":")
        if not sep:
            raise RenderError("%s:%d: expected 'key: value'" % (path, n))
        if indent == 0 and val.strip() == "":
            section = key
            if section not in SCHEMA:
                raise RenderError("%s:%d: unknown section '%s'" % (path, n, section))
            continue
        if indent == 0:
            section = ""
        full = key if indent == 0 else section + "." + key
        sec = "" if indent == 0 else section
        if key not in SCHEMA.get(sec, []):
            raise RenderError("%s:%d: unknown key '%s'" % (path, n, full))
        data[full] = _scalar(val)
    missing = [(k if s == "" else s + "." + k) for s, ks in SCHEMA.items() for k in ks
               if (k if s == "" else s + "." + k) not in data]
    if missing:
        raise RenderError("%s: missing keys: %s" % (path, ", ".join(missing)))
    if data["name"] != name:
        raise RenderError("%s: name '%s' != file name" % (path, data["name"]))
    return data


def truthy(v):
    if isinstance(v, list):
        return len(v) > 0
    return str(v).strip().lower() not in ("", "false", "no", "0", "none", "null")


def derive(p, profile):
    d = {}
    ps = p["firewall.public_sources"]
    d["derived.public_any"] = "true" if ps == "any" else "false"
    d["derived.public_set"] = ps if isinstance(ps, list) else []
    d["derived.acme_ca"] = ("https://acme-staging-v02.api.letsencrypt.org/directory"
                            if truthy(p["exposure.acme_staging"]) else "https://acme-v02.api.letsencrypt.org/directory")
    d["derived.generated"] = "GENERATED by bin/render.py for profile '%s' — edit the profile/template, not this file." % profile
    d["derived.profile"] = profile
    d["derived.lan"] = "true" if truthy(p["firewall.lan_subnet"]) else "false"
    ws = p["firewall.wg_subnet"]
    d["derived.wg_prefix"] = ws.split("/")[1] if "/" in ws else "24"
    d["derived.ipv6"] = "true" if truthy(p["edge.public_ipv6"]) else "false"
    d["derived.publish_v6"] = "true" if (truthy(p["edge.public_ipv6"]) and p["exposure.bind_ip"] in ("0.0.0.0", "::")) else "false"
    d["derived.smoke_ip"] = "127.0.0.1" if p["exposure.bind_ip"] in ("0.0.0.0", "::") else p["exposure.bind_ip"]
    return d


FILTERS = {
    "join": lambda v: ", ".join(v) if isinstance(v, list) else str(v),
    "spaces": lambda v: " ".join(v) if isinstance(v, list) else str(v),
    "nftset": lambda v: "{ %s }" % ", ".join(v if isinstance(v, list) else [v]),
    "yamllist": lambda v: "[%s]" % ", ".join('"%s"' % x for x in (v if isinstance(v, list) else [v] if v else [])),
}
VAR = re.compile(r"(?<!\$)\{\{\s*([a-z0-9_.]+)\s*(?:\|\s*([a-z]+)\s*)?\}\}")
BLOCK = re.compile(r"^\s*(?:#\s*)?\{\{\s*(#if|#unless|#else|/if|/unless)\s*([a-z0-9_.]*)\s*(?:==\s*(\S+))?\s*\}\}\s*$")


def render_text(text, ctx, where):
    out, stack = [], []  # stack of (active, branch_taken)
    for n, line in enumerate(text.splitlines(keepends=True), 1):
        m = BLOCK.match(line.rstrip("\n"))
        if m:
            kind, key, eq = m.groups()
            parent = all(a for a, _ in stack)
            if kind in ("#if", "#unless"):
                if key not in ctx:
                    raise RenderError("%s:%d: unknown key in block: %s" % (where, n, key))
                val = ctx[key]
                cond = (str(val) == eq) if eq is not None else truthy(val)
                if kind == "#unless":
                    cond = not cond
                stack.append((parent and cond, cond))
            elif kind == "#else":
                if not stack:
                    raise RenderError("%s:%d: else without if" % (where, n))
                _, taken = stack.pop()
                stack.append((all(a for a, _ in stack) and not taken, True))
            else:
                if not stack:
                    raise RenderError("%s:%d: unbalanced %s" % (where, n, kind))
                stack.pop()
            continue
        if not all(a for a, _ in stack):
            continue

        def sub(mm):
            key, flt = mm.group(1), mm.group(2)
            if key not in ctx:
                raise RenderError("%s:%d: unknown key {{%s}}" % (where, n, key))
            val = ctx[key]
            if flt:
                if flt not in FILTERS:
                    raise RenderError("%s:%d: unknown filter %s" % (where, n, flt))
                return FILTERS[flt](val)
            if isinstance(val, list):
                raise RenderError("%s:%d: list {{%s}} needs a filter" % (where, n, key))
            return str(val)

        out.append(VAR.sub(sub, line))
    if stack:
        raise RenderError("%s: unclosed block" % where)
    return "".join(out)


def list_profiles():
    return sorted(f[:-5] for f in os.listdir(PROFILES) if f.endswith(".yaml"))


def render(profile):
    p = load_profile(profile)
    ctx = dict(p)
    ctx.update(derive(p, profile))
    outdir = os.path.join(BUILD, profile)
    written = []
    for group, flag in GROUPS.items():
        if flag and not truthy(p[flag]):
            continue
        gdir = os.path.join(TEMPLATES, group)
        for base, _, files in os.walk(gdir):
            for f in sorted(files):
                if not f.endswith(".tmpl"):
                    continue
                src = os.path.join(base, f)
                rel = os.path.relpath(src, TEMPLATES)[:-5]
                dst = os.path.join(outdir, rel)
                os.makedirs(os.path.dirname(dst), exist_ok=True)
                text = render_text(open(src, encoding="utf-8").read(), ctx, os.path.relpath(src, ROOT))
                if not any(l.strip() and not l.lstrip().startswith(("#", "//")) for l in text.splitlines()):
                    if os.path.exists(dst):
                        os.remove(dst)
                    continue  # template rendered to comments only -> feature disabled in this profile
                with open(dst, "w", encoding="utf-8") as fh:
                    fh.write(text)
                if rel.endswith(".sh"):
                    os.chmod(dst, 0o755)
                written.append(rel)
    report = ["profile: %s (%s)" % (profile, p["status"]), "files:"] + ["  " + w for w in written]
    with open(os.path.join(outdir, "render-report.txt"), "w", encoding="utf-8") as fh:
        fh.write("\n".join(report) + "\n")
    return written


def check_agnostic():
    names = list_profiles()
    vnames = [n for n in names if n.endswith(VERIFY_SUFFIX)]
    verifies = [load_profile(n) for n in vnames]
    others = [load_profile(n) for n in names if not n.endswith(VERIFY_SUFFIX)]
    forbidden = {"/Users/", "/opt/homebrew", "Docker Desktop", "/home/"} | set(vnames)
    # host-specific values only (ports, subnets, addresses, registry, HSTS) that appear in a verification profile and
    # in NO production profile — enum values like "internal" and container-local 127.0.0.1 are legitimate in templates.
    keys = ("exposure.http_port", "exposure.https_port", "exposure.hsts", "exposure.domain", "edge.public_subnet",
            "edge.public_gateway", "edge.project", "registry.bind", "registry.push", "firewall.lan_subnet",
            "exposure.relay_wg_ip")
    for verify in verifies:
        for k in keys:
            v = str(verify[k])
            if v and v != "localhost" and all(str(o.get(k)) != v for o in others):  # "localhost" is generic
                forbidden.add(v)
        for v in verify.get("crowdsec.whitelist", []):
            if all(v not in o.get("crowdsec.whitelist", []) for o in others):
                forbidden.add(v)
    hits = []
    for base, _, files in os.walk(TEMPLATES):
        for f in files:
            path = os.path.join(base, f)
            for n, line in enumerate(open(path, encoding="utf-8"), 1):
                for tok in forbidden:
                    if re.search(r"(?<![0-9A-Za-z.])" + re.escape(tok) + r"(?![0-9A-Za-z])", line):
                        hits.append("%s:%d: '%s'" % (os.path.relpath(path, ROOT), n, tok))
    print("verification profiles: %s" % ", ".join(vnames))
    print("forbidden tokens (unique to them): %s" % ", ".join(sorted(forbidden)))
    if hits:
        print("FAIL — templates contain verification-host values:\n  " + "\n  ".join(hits))
        return 1
    print("PASS — templates are host-agnostic")
    return 0


def main(argv):
    try:
        if not argv or argv[0] in ("-h", "--help"):
            print(__doc__)
            return 0
        if argv[0] == "--check-agnostic":
            return check_agnostic()
        if argv[0] == "--get":
            p = load_profile(argv[1])
            p.update(derive(p, argv[1]))
            v = p[argv[2]]
            print(" ".join(v) if isinstance(v, list) else v)
            return 0
        names = list_profiles() if argv[0] == "--all" else [argv[0]]
        for name in names:
            files = render(name)
            print("rendered %-20s %2d files -> build/%s/" % (name, len(files), name))
        return 0
    except (RenderError, KeyError) as e:
        print("render error: %s" % e, file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
