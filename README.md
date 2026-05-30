# Rama — self-contained replica of `rama.framer.media`

A fully self-contained, offline copy of <https://rama.framer.media/> (the Framer
"Rama – Creative Agency" template), served by **OpenResty (nginx + Lua)** in Docker.

Every page, asset, JS module, font and CMS data file is mirrored locally and all
asset URLs are rewritten to local, root-relative paths, so **nothing is fetched
from the internet at runtime** — except outbound links you intentionally click
(social icons, etc.). The console is clean (0 errors/warnings) on every page,
through full scroll and client-side navigation, matching the live site.

---

## Quick start (local)

```bash
docker compose up -d --build      # build + run
# open http://localhost:8080
docker compose down               # stop + remove
```

Change the local port with the `RAMA_PORT` env var (defaults to `8080`):

```bash
RAMA_PORT=9000 docker compose up -d --build   # http://localhost:9000
```

---

## Live deployment

| | |
|---|---|
| **Public URL** | http://89.37.212.232:8081/ |
| **Server** | CentOS 7, Docker 26.1.4 + Compose v2 |
| **Path on server** | `/opt/rama` |
| **Container** | `rama-local` (port mapping `8081->80`, `restart: unless-stopped`) |
| **Port** | `8081` (set via `/opt/rama/.env` → `RAMA_PORT=8081`) |
| **GitHub** | `git@github.com:LightBringer90/Vannys.git` (branch `main`) |

The server also runs unrelated projects which this deployment does **not** touch:
`lapensiuneavlad.ro` (host nginx on :80/:443) and `kaya-summer-school` (container
on :8080). Rama lives on its own port to stay isolated.

### Redeploy / update the live site

From your machine (after committing changes):

```bash
# option A: rsync the working tree
sshpass -e rsync -az --delete \
  -e "ssh -o StrictHostKeyChecking=no" \
  --exclude '.git' --exclude '.claude' --exclude '*.tar.gz' \
  /Users/silviu/Vannys/ root@89.37.212.232:/opt/rama/

# then on the server
ssh root@89.37.212.232 'cd /opt/rama && docker compose up -d --build'
```

Or pull from GitHub on the server instead of rsync:

```bash
ssh root@89.37.212.232
cd /opt/rama && git pull && docker compose up -d --build   # if /opt/rama is a git clone
```

> The server currently holds a plain copy (not a git clone). To switch to
> git-based deploys, `git clone git@github.com:LightBringer90/Vannys.git /opt/rama`
> once (after backing up the existing `.env`).

---

## Site specification

### Pages (under `site/rama.framer.media/`)

| URL | File | Notes |
|---|---|---|
| `/` | `index.html` | Home |
| `/about` | `about.html` | |
| `/works` | `works.html` | Works listing (CMS collection) |
| `/works/<slug>` | `works/<slug>.html` | 6 case-study pages |
| `/blog` | `blog.html` | Blog listing (CMS collection) |
| `/blog/<slug>` | `blog/<slug>.html` | 6 blog posts |
| `/contact` | `contact.html` | Form has no backend (static) |
| `/legal/privacy-policy` | `legal/privacy-policy.html` | |
| `/legal/terms-of-service` | `legal/terms-of-service.html` | |

Works slugs: `website-and-branding-for-bima-agency`, `-kresna-agency`,
`-pandawa-agency`, `-sadewa-agency`, `-nakula-agency`, `-mandala`.
Blog slugs: `how-big-brands-win-the-competition`,
`the-real-reason-big-brands-stay-ahead`,
`why-smart-brands-grow-faster-than-the-rest`,
`how-efficient-teams-beat-larger-teams`,
`the-growth-mindset-modern-brands-use`,
`why-simple-systems-win-in-competitive-markets`.

Pages are served at clean, extensionless URLs via nginx
`try_files $uri $uri.html $uri/index.html`.

### Mirrored asset hosts (served at `/<host>/...`)

| Directory | What |
|---|---|
| `framerusercontent.com/` | Images, fonts, ES modules (`.mjs`), CSS, videos (`.mp4`), and CMS data (`cms/*.framercms`) |
| `fonts.gstatic.com/` | Google web-font files |
| `unpkg.com/` | `lenis` smooth-scroll library |
| `events.framer.com/` | Analytics loader (`script`) — served locally, inert offline |

Framer site ID: `5LeW06E5i3LR827u1NsnHA`
(modules live under `framerusercontent.com/sites/5LeW06E5i3LR827u1NsnHA/`).

### Tech stack of the original

- **Framer** export (React + a `motion` runtime + `framer` runtime bundle).
- ES modules (`.mjs`), many loaded via dynamic `import()`.
- **CMS collections** (blog, works) loaded client-side from `*.framercms`
  binary files using HTTP byte-range *query params*.
- `lenis` for smooth scrolling.

---

## How it's served (`nginx.conf` / `Dockerfile`)

The image is **OpenResty** (`openresty/openresty:alpine`) — nginx plus Lua. The
site is baked into the image at build time (`COPY site/ ...`), so the container is
fully portable with no runtime volume.

Key pieces of `nginx.conf`:

1. **`*.framercms` Lua handler** — honours Framer's custom
   `?range=from-to,from-to` query param: it reads only the requested byte ranges,
   concatenates them, and returns them. Marked `Cache-Control: no-store` (a cached
   whole-file copy would fail the loader's length check). **Must precede** the
   generic host-dir location.
2. **Image MIME restore** — Framer image files were saved with their
   `?width=…&height=…` query baked into the filename, so nginx can't infer the
   type. Regex locations set `image/jpeg` / `image/png` etc.
3. **Analytics** — `= /events.framer.com/script` served as JavaScript.
4. **Host dirs** — `framerusercontent.com`, `fonts.gstatic.com`, `unpkg.com`,
   `events.framer.com` served from the web root with long cache.
5. **Pages** — everything else resolves under `rama.framer.media/` with clean URLs.

`Dockerfile` also adds `mjs` to `mime.types` so ES modules are served as
JavaScript.

---

## Known limitations

- **Static mirror.** Layout, styles, fonts, images, videos, animations,
  client-side navigation, and the CMS-driven blog/works lists all work. The
  **contact form has no backend** (submits nowhere). Analytics is a local no-op.
- **Snapshot in time.** Mirrored from the version published 2026-05-21. Re-run the
  mirror (see `BUILD_NOTES.md`) to refresh content.
- **`ERR_ABORTED` on `.mp4`** in devtools is normal browser behaviour (it aborts a
  buffered `<video>` range request); the videos serve fine with `206` range support.

---

## Repository layout

```
.
├── Dockerfile            # OpenResty image, mjs mime fix, bakes in site/
├── docker-compose.yml    # build + run, port via ${RAMA_PORT:-8080}
├── nginx.conf            # routing, framercms range handler, mime fixes
├── .dockerignore         # keeps site.tar.gz etc. out of the build context
├── .gitignore            # excludes .claude/, *.tar.gz
├── README.md             # this file
├── BUILD_NOTES.md        # full chronological build log + every fix
└── site/                 # the mirrored website (≈330 files)
    ├── rama.framer.media/         # HTML pages
    ├── framerusercontent.com/     # assets + modules + cms/*.framercms
    ├── fonts.gstatic.com/
    ├── unpkg.com/
    └── events.framer.com/
```

See **`BUILD_NOTES.md`** for exactly how the mirror was produced, every problem
encountered, and how each was fixed — start there before changing the mirror.
