# Wiki source

The GitHub wiki lives in a separate repository
(`FORGE-AI.wiki.git`), which means its pages are not reviewed, linted or
link-checked by this repository's CI. Keeping the source here fixes
that: a wiki page is edited through a pull request like anything else,
and only then published.

| File | Wiki page |
|---|---|
| [`Home.md`](Home.md) | `Home` — the wiki landing page |

## Conventions

- **The repository is the source of truth.** Wiki pages point at
  `docs/`; they do not duplicate it. A wiki page that restates a
  procedure will be wrong the first time the procedure changes.
- **Absolute links only.** A wiki page is served from a different
  repository, so a relative link into `docs/` resolves to nothing. Link
  with the full `https://github.com/danielesalpietro/FORGE-AI/...` URL —
  which is also what keeps CI's broken-relative-link check honest about
  these files.
- **No secrets, no host-specific addresses.** The wiki is public even
  when a repository is not.

## Publishing

The wiki has its own clone URL. From a checkout of this branch:

```bash
git clone https://github.com/danielesalpietro/FORGE-AI.wiki.git /tmp/forge-wiki
cp docs/wiki/Home.md /tmp/forge-wiki/Home.md
git -C /tmp/forge-wiki add Home.md
git -C /tmp/forge-wiki commit -m "docs: wiki home page"
git -C /tmp/forge-wiki push
```

The clone fails with a 404 until the wiki has at least one page: GitHub
creates the wiki repository the first time a page is saved. If that
happens, create the `Home` page once from **Wiki → Create the first
page** in the web UI — content does not matter, the push above replaces
it — and then run the commands.

Pasting the file's content into that same editor is equally valid for a
single page. The commands are worth it once more than one page exists.
