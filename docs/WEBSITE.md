# Narad community website

The repository includes a static, SEO-ready GitHub Pages website. It publishes
an app overview, searchable project documentation, downloadable source documents,
feedback, Patreon support, and collaborators. Website code lives in `site/`.

## Deployment

Expected default address: **https://tyqeron.github.io/narad/**.

One-time GitHub repository setup:

1. In **Settings → Pages → Build and deployment**, select **GitHub Actions** as
   the source.
2. If the `github-pages` environment limits deployment branches/tags, allow the
   release tags you intend to publish. Required environment approvals still apply.
3. Keep **Issues** enabled for community feedback.

The **Build and deploy Narad website** workflow builds and validates the site on
website/documentation changes and pull requests. A push of **any tag** builds the
website from that tag and deploys it to Pages. Deleted tags do not deploy. A manual
workflow run can deploy its selected revision for the first launch or recovery.
The application release workflow remains independent; website builds do not wait
for platform binaries. The download button links to the release list so new tags
can build their application artifacts afterward.

Use the normal release procedure in [RELEASING.md](RELEASING.md). For example,
after the website commits are on GitHub, pushing a valid app release tag also
starts website deployment. This implementation does not push a tag or publish the
site by itself.

Only the deploy job gets `pages: write` and `id-token: write`. Pull requests build
and validate without publishing. No personal access token or payment credentials
are needed by the website.

## Local preview

```sh
python3 -m venv /tmp/narad-site-env
/tmp/narad-site-env/bin/pip install -r site/requirements.txt
/tmp/narad-site-env/bin/python site/build.py --url https://localhost --version main
python3 -m http.server 8765 --directory site/_build
```

Visit `http://localhost:8765/`. The command above overrides the default `/narad/`
project subpath for this local preview. HTTPS in the build option describes
canonical metadata; the local preview server still uses HTTP.

```sh
/tmp/narad-site-env/bin/python site/build.py --url https://localhost --version main
/tmp/narad-site-env/bin/python tests/site_test.py
```

Generated output in `site/_build/` is ignored by Git. The build requires only
Python and the pinned Python-Markdown dependency; there is no client framework,
CDN font, analytics tracker, account service, or application backend.

## Documentation and SEO

All root Markdown documents, `docs/**/*.md`, client README documents, and the
license are rendered automatically. Generated/private client build directories
are excluded. This includes the PRD, architecture, technical implementation spec,
roadmap, sprint backlog, development journal, and platform/feature guides.

Each page has a unique title, description, canonical URL, Open Graph/Twitter
metadata and JSON-LD. A sitemap and robots.txt support discovery. HTML content,
links, document listings, source downloads, and a table of contents work without
JavaScript. Search progressively adds a local full-document index. SEO readiness
does not guarantee search engine indexing or rankings.

The published documents come from the tagged snapshot. Original Markdown source
links point to the same tag on GitHub. Local Markdown links are rewritten to
website routes; source-code links point to the repository. The site distinguishes
available implementations from platform previews and pending native QA.

Configure `site_url` and `repository` in `site/config.json` if the project moves.
`SITE_URL` or `--url` overrides the canonical address for a custom domain. Configure
the domain and DNS in GitHub Pages separately. Rebuild after changing the URL.

## Feedback

The feedback form opens a prefilled **public GitHub issue draft**. Users must sign
in, review and submit it on GitHub. The website does not claim to submit or store
feedback itself. Without JavaScript, users can use the linked issue template.
Do not include personal messages, tokens or private data in public feedback.

## Patreon

The Patreon section intentionally shows **Patreon details coming soon** until the
community supplies its real destination. Add the complete HTTPS Patreon URL to
`donation_url` in `site/config.json`, and optionally change `donation_label`.
Commit the change and include it in the next tag, or manually deploy the website.
The site then links directly to Patreon; it never handles payment details.
No recipient, payment address, fundraising total or donation claim is invented.

## Collaborators

The collaborators page recognizes author names and commit counts from the tagged
Git history and links to GitHub’s contributors page. Author email addresses are
never published. The workflow checks out full history for accurate recognition.
The page also welcomes testing, documentation and design work, and links to
issues for people who want to participate.

## Browser checks

CI also uses an isolated headless Chrome session to check full-text search, an
empty search result, GitHub issue draft encoding, mobile navigation and layouts
at 320, 360 and 390 pixels. Feedback navigation is intercepted: tests never post
an issue. For local browser checks, install the test dependency in `/tmp`, serve
the generated site under `/narad/`, and run:

```sh
npm install --prefix /tmp/narad-site-browser playwright-core@1.56.1 --no-audit --no-fund
NARAD_PLAYWRIGHT_MODULE=/tmp/narad-site-browser/node_modules/playwright-core/index.mjs \
NARAD_CHROME=/usr/bin/google-chrome node tests/site_browser.mjs
```

`NARAD_SITE_PREVIEW` overrides the preview URL (default
`http://127.0.0.1:8765/narad/`). `NARAD_SITE_SCREENSHOTS` optionally names an existing
directory for desktop, documentation and mobile screenshots.
