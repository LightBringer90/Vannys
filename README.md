# Rama — local replica

A fully self-contained local copy of <https://rama.framer.media/> (a Framer-built
"Rama – Creative Agency" template), served by nginx in Docker.

The site was mirrored statically (all HTML pages + every CSS/JS/font/image asset)
and all asset URLs were rewritten to local, root-relative paths, so **nothing is
fetched from the internet at runtime** (except outbound links you click, e.g. the
social icons).

## Run

```bash
docker compose up -d --build
```

Then open <http://localhost:8080>.

Stop / remove:

```bash
docker compose down
```

To serve on a different port, edit the `ports` mapping in `docker-compose.yml`
(`"8080:80"` → `"<your-port>:80"`).

## What's included

- `site/` — the mirrored website
  - `rama.framer.media/` — the HTML pages (home, about, works + items, blog +
    posts, contact, legal). Served at the web root with clean URLs (`/`,
    `/about`, `/works/...`, `/blog/...`).
  - `framerusercontent.com/`, `fonts.gstatic.com/`, `unpkg.com/`,
    `events.framer.com/` — mirrored third-party assets, served at `/<host>/...`.
- `nginx.conf` — routing + content-type fixes.
- `Dockerfile` — `nginx:alpine` with the site baked in.
- `docker-compose.yml` — build + run on port 8080.

## Notes / known limitations

- This is a **static** mirror. Framer's runtime hydrates the page, animations and
  client-side navigation work, and the CMS-backed blog/works collections load from
  the mirrored `.framercms` data. Form submission still has no backend.
- Console is clean (0 errors/warnings) on every page, matching the live site.

### Things that had to be fixed to get a clean console

- **Responsive images (`srcset`)** — wget's `--convert-links` corrupts `srcset`
  attributes, so the mirror is taken *without* it and asset URLs are rewritten by
  hand instead.
- **Dynamically imported JS chunks** — wget can't see `import()` calls, so the
  `.mjs` chunks they load were fetched in a second pass by scanning the downloaded
  modules for `*.mjs` references until closure.
- **CMS data** — Framer loads collection data (`*.framercms`) client-side from
  `/framerusercontent.com/cms/...`; those files were mirrored too.
- **CMS range queries (crashed on scroll)** — Framer's CMS loader doesn't fetch
  whole `.framercms` files; it requests specific byte ranges via a custom
  `?range=from-to,from-to` *query parameter* and expects only those bytes back,
  concatenated. A plain static server returns the whole file, so the loader throws
  "Unexpected response length" and the bound component crashes when it scrolls
  into view. The server therefore runs **OpenResty** (nginx + Lua) with a small
  handler that honours the `range` query (see `nginx.conf`).
- **`new URL(rel, "/root-relative")`** — Framer's CMS loader builds URLs with a
  root-relative base, which the spec rejects ("Invalid base URL") once the host is
  localized. A tiny shim injected at the top of each page's `<head>`
  (`<!--__local_url_shim__-->`) makes such bases resolve against the page origin.
- **Image-CDN filenames** — saved with their `?width=…&height=…` query baked into
  the filename; references encode the `?` as `%3F` and `nginx.conf` restores the
  correct image MIME types.
- **`.mjs` MIME** — the Dockerfile adds `mjs` to nginx's mime.types so ES modules
  load as JavaScript.
- **Analytics** — `events.framer.com/script` is served locally (a no-op offline);
  no beacons leave the machine.

## How it was mirrored (for reference / re-mirroring)

GNU wget was run inside a throwaway container (Docker Desktop bind mounts on this
machine fail to write many files, so the crawl ran in the container's own
filesystem and the result was copied out via `docker cp`):

```bash
wget --recursive --level=15 --page-requisites --adjust-extension --convert-links \
     --span-hosts \
     --domains=rama.framer.media,framerusercontent.com,fonts.gstatic.com,app.framerstatic.com,events.framer.com,unpkg.com \
     --no-parent -e robots=off \
     https://rama.framer.media/
```

Then absolute and relative asset URLs were normalized to root-relative `/host/...`
paths across all `.html`/`.css`/`.mjs`/`.js` files.
