# Build notes — how the Rama replica was made

A complete, chronological record of building a self-contained offline copy of
<https://rama.framer.media/>, every problem hit, and how each was solved. Read
this before re-mirroring or changing how the site is served — most of the work was
in working around how Framer ships sites and how `wget` mishandles them.

- **Source site:** `https://rama.framer.media/` (Framer "Rama – Creative Agency"
  template, published 2026-05-21). Framer site ID `5LeW06E5i3LR827u1NsnHA`.
- **Goal:** reproduce locally + in Docker, then deploy publicly.
- **Final result:** OpenResty container, clean console on every page, live at
  `http://89.37.212.232:8081/`, source on GitHub `LightBringer90/Vannys`.

---

## 1. Environment & approach

- Local machine: macOS, Docker Desktop, no `wget`/`httrack` (only `curl`).
- Chosen approach: mirror the static site with GNU `wget`, rewrite asset URLs to
  local paths, serve with nginx in Docker.
- The site is multi-page (home, about, works + 6 items, blog + 6 posts, contact,
  legal) with assets mostly on `framerusercontent.com` and `fonts.gstatic.com`.

## 2. Mirroring the site

### Problem: no local wget; Docker Desktop bind mounts are broken here

- `wget` isn't installed locally. Ran it inside a throwaway Docker container.
- **alpine's musl `wget` failed** with "No file descriptors available", and even
  on Debian the crawl failed writing to the **bind-mounted** macOS volume with
  "Too many open files" — Docker Desktop's default `nofile` soft limit is ~1M and
  the virtiofs/gRPC-FUSE bind mount chokes on many small writes.
- **Fix:** cap the fd limit (`--ulimit nofile=4096:4096` + `ulimit -n 1024`) **and
  don't write to the bind mount at all** — run the crawl in the container's own
  filesystem, then extract the result with `docker cp` and untar natively on macOS.

### The mirror command (final, WITHOUT `--convert-links`)

```bash
wget --recursive --level=15 --page-requisites --adjust-extension \
     --span-hosts \
     --domains=rama.framer.media,framerusercontent.com,fonts.gstatic.com,app.framerstatic.com,events.framer.com,unpkg.com \
     --no-parent -e robots=off --tries=3 --timeout=30 --waitretry=2 \
     --user-agent="Mozilla/5.0 ..." \
     https://rama.framer.media/
```

> **Important:** `--convert-links` was dropped (see §4). URL rewriting is done by
> hand afterwards instead.

## 3. Serving it: nginx → OpenResty

- Pages live under `rama.framer.media/`; third-party assets under their own host
  dirs (`framerusercontent.com/`, etc.). nginx serves pages at the web root with
  clean URLs (`try_files $uri $uri.html $uri/index.html`) and the host dirs at
  `/<host>/...`.
- The site is **baked into the image** (`COPY site/`), not bind-mounted (both
  because of the broken bind mount and for portability).
- Later switched base image from `nginx:alpine` to `openresty/openresty:alpine`
  to get Lua for the CMS range handler (§7).

---

## 4. Fixes required for a clean console

Each of these was found by driving real headless Chrome (puppeteer-core) against
the local site, capturing page errors, console errors, failed requests and
HTTP ≥400 responses — then scrolling and navigating to trigger lazy code.

### 4.1 Corrupted `srcset` (≈30 image 404s)

`wget --convert-links` does **not** understand `srcset` syntax and mangles it,
concatenating multiple responsive-image URLs into one broken string. The browser
then requested garbage URLs.
**Fix:** re-mirror **without** `--convert-links`; rewrite URLs by hand (§5).

### 4.2 Missing dynamically-imported JS chunks (404 → "Failed to fetch module")

`wget` can't see JS `import()` calls, so dynamically-loaded `.mjs` chunks were
never downloaded (e.g. `PX9hIOIVM.CB5_kqUa.mjs`).
**Fix:** a second pass that scans the downloaded `.mjs` for `*.mjs` references and
downloads any missing ones, repeating until closure (recovered 14 chunks).

```bash
SITE=framerusercontent.com/sites/5LeW06E5i3LR827u1NsnHA
for round in $(seq 1 12); do
  grep -rohE "[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.mjs" $SITE/ | sort -u > refs
  new=0
  while read m; do
    [ -f "$SITE/$m" ] || { wget -q "https://$SITE/$m" -O "$SITE/$m" && new=$((new+1)) || rm -f "$SITE/$m"; }
  done < refs
  [ "$new" -eq 0 ] && break
done
```

### 4.3 `.mjs` MIME type

nginx's default `mime.types` maps `.js` but not `.mjs`; browsers refuse to execute
ES modules served as the wrong type.
**Fix (Dockerfile):**
`sed -i -E 's#(application/javascript[[:space:]]+)js;#\1js mjs;#' .../mime.types`

### 4.4 Image filenames carry the query string

Framer image URLs look like `NAME.jpg?width=1392&height=800`. `wget` saved them
with the query **in the filename**. References must reach those files and get the
right MIME.
**Fix:** rewrite the `?` in image refs to `%3F` (so the browser requests the
literal filename, not a query); nginx regex locations restore `image/jpeg`,
`image/png`, etc. (nginx otherwise sees no real extension → `octet-stream`).

### 4.5 `new URL(rel, "/root-relative")` → "Invalid base URL" → "non-interactive UI"

Framer's CMS loader builds URLs like
`new URL("./x.framercms", "/framerusercontent.com/modules/.../X.js")`.
Once the host was localized, the **base** became root-relative, which the URL spec
rejects (it requires an absolute base) → threw during module init → the whole
component tree went non-interactive.
**Fix:** a tiny classic `<script>` injected at the top of every page's `<head>`
(marker `<!--__local_url_shim__-->`) that wraps the global `URL` constructor: if
`new URL(u, base)` throws and `base` is a root-relative string, it retries with
`new URL(u, location.origin + base)`. Runs before any module (modules are
deferred).

### 4.6 CMS data not mirrored

Framer loads collection data (blog/works) client-side from
`/framerusercontent.com/cms/{id}/{id}/{name}.framercms` (the loader takes the
module path under `/modules/` and string-replaces it with `/cms/`).
**Fix:** downloaded the 9 `.framercms` chunks directly from the CDN (host `curl`
works fine — only Docker *writes* to the bind mount were broken). 7 collections;
`-chunk-default-0` for each, plus `-indexes-default-0` for the two with indexes.

### 4.7 Analytics 404

`events.framer.com/script?v=2` was saved as `script?v=2`; the browser strips
`?v=2` as a query.
**Fix:** renamed the file to `script`; nginx serves it as JavaScript at
`= /events.framer.com/script`. Inert offline; no beacons leave the machine.

## 5. URL rewriting (the hand-rolled replacement for `--convert-links`)

Applied with `perl -i -pe` across all `.html/.css/.mjs/.js/.json` files:

```perl
# localize mirrored hosts -> root-relative
s{https?://framerusercontent\.com}{/framerusercontent.com}g;
s{https?://fonts\.gstatic\.com}{/fonts.gstatic.com}g;
s{https?://app\.framerstatic\.com}{/app.framerstatic.com}g;
s{https?://events\.framer\.com}{/events.framer.com}g;
s{https?://unpkg\.com}{/unpkg.com}g;
s{https?://rama\.framer\.media}{}g;          # self-refs -> root-relative
# encode the image-CDN query delimiter so requests hit the on-disk filenames
s{\.(jpe?g|png|webp|gif|avif|svg)\?}{.$1%3F}gi;
```

External links (social, framer.com, agency demos) are intentionally left absolute.

## 6. The scroll-triggered crash ("Unexpected response length")

After the above, fresh page loads were clean — but **scrolling / navigating**
triggered a Framer "code override crashed" error. The real error was
`Request failed: Unexpected response length` in the `.framercms` loader.

### Root cause

The CMS loader doesn't fetch whole `.framercms` files. It computes the byte ranges
it needs and requests them via a **custom `?range=from-to,from-to` query param**,
expecting the response to be **only those bytes, concatenated** (it then checks the
length and rejects a mismatch):

```js
a.searchParams.set("range", "0-99,200-299");
const l = new Uint8Array(await (await fetch(a)).arrayBuffer());
if (l.length !== expectedTotal) throw Error("Request failed: Unexpected response length");
```

A plain static server ignores `?range=` and returns the whole file → length
mismatch → throw. It only surfaced on scroll/navigation because that's when those
collections actually render (`evalQuery → lookupItems → loadModel`).

### Fix: OpenResty + Lua range handler (`nginx.conf`)

```nginx
location ~* \.framercms$ {
    default_type application/octet-stream;
    add_header Cache-Control "no-store" always;
    content_by_lua_block {
        ngx.header["Cache-Control"] = "no-store"
        local path  = ngx.var.document_root .. ngx.var.uri
        local f = io.open(path, "rb")
        if not f then ngx.status = 404; ngx.say("not found"); return end
        local range = ngx.var.arg_range
        if not range then local d=f:read("*a"); f:close(); ngx.print(d); return end
        local chunks = {}
        for part in string.gmatch(range, "([^,]+)") do
            local a, b = string.match(part, "(%d+)%-(%d+)")
            if a then a,b=tonumber(a),tonumber(b); f:seek("set",a); chunks[#chunks+1]=f:read(b-a+1) end
        end
        f:close(); ngx.print(table.concat(chunks))
    }
}
```

Verified byte-identical to the correct local slice (md5 match) for the exact
ranges the browser requests. `no-store` is essential — see §7.

## 7. The "it's still broken after the fix" red herring (browser cache)

After the range fix, the user still saw the crash. Diagnosis: an earlier build had
served `.framercms` with `Cache-Control: public, immutable`, so the browser had
cached the **whole-file** (wrong-length) response and kept replaying it without
revalidating, even on normal reload. Proven by intercepting requests in headless
Chrome to force the full-file response — which reproduced the exact error.
**Fix:** `.framercms` now sends `Cache-Control: no-store`; clearing site data once
(DevTools → Application → Clear site data, or an Incognito window) resolves stale
clients.

---

## 8. Verification method

`puppeteer-core` driving the installed Google Chrome (`headless: 'new'`),
capturing `console` (error/warning), `pageerror`, `requestfailed`, and `response`
≥400. Three modes:
1. Load + wait.
2. Load + full scroll (down in steps, pause, back up) to fire scroll/intersection
   handlers and lazy loads.
3. Load + **click internal links** (client-side SPA navigation) — this is what
   triggers the CMS `loadModel` chunk fetches; fresh page loads alone don't.

Baseline: the live site reports `0/0/0/0`. The replica matches on every page.
(One benign `ERR_ABORTED` on a `.mp4` remains — normal `<video>` range-abort.)

---

## 9. Deployment

- **Server:** `89.37.212.232`, CentOS 7, Docker 26.1.4 + Compose v2, no host
  firewall (firewalld inactive, iptables ACCEPT-all), 17 GB free.
- **Pre-existing (untouched):** host nginx serves `lapensiuneavlad.ro` on :80/:443;
  `kaya-summer-school` container on :8080; MySQL on :3306.
- **Decision:** expose Rama on a **dedicated port (8081)** — zero changes to the
  existing nginx, lowest risk to the production site.
- **Steps:**
  1. `rsync` the working tree to `/opt/rama` (excluding `.git/.claude/*.tar.gz`).
  2. `/opt/rama/.env` → `RAMA_PORT=8081`.
  3. `docker compose up -d --build`.
  4. Verified externally (`200`s, correct image MIME, byte-correct CMS ranges) and
     with a full headless nav pass (0 console errors).
  5. Confirmed `lapensiuneavlad.ro` (`200`) and kaya (healthy) unaffected.
- `docker-compose.yml` uses `restart: unless-stopped`, so the container survives
  reboots. Port comes from `${RAMA_PORT:-8080}` (local default 8080, server 8081).

## 10. Source control

- Local repo `git init` on `main`; `.gitignore` excludes `.claude/` and
  `*.tar.gz`. `.dockerignore` keeps the tarball out of the build context.
- Pushed to `git@github.com:LightBringer90/Vannys.git` (336 files incl. `site/`).

---

## 11. Open follow-ups / ideas

- **HTTPS + domain:** put Rama behind a real domain with free Let's Encrypt TLS
  instead of a bare `:8081` (would add an nginx vhost on the host or a small TLS
  proxy — careful not to disturb the existing :443 vhost).
- **Git-based deploys:** make `/opt/rama` a clone of the GitHub repo so updates are
  `git pull && docker compose up -d --build`.
- **Content refresh:** re-run the mirror (§2) + module/CMS passes (§4.2, §4.6) to
  pick up any changes to the source site, then re-apply URL rewriting (§5).
- **Server hygiene:** CentOS 7 is end-of-life and SSH warned about non-PQ key
  exchange; consider an OS upgrade and switching root password → SSH keys.
- **Contact form:** currently inert; wire to a backend/`mailto`/form service if a
  working form is needed.
```
