# Zit's website

The site at [damienmonchaty.github.io/zit](https://damienmonchaty.github.io/zit/),
built with [Astro Starlight](https://starlight.astro.build). Needs Node 22.23 or later.

```sh
cd site
npm install
npm run dev       # http://localhost:4321/zit/
npm run build     # into site/dist
```

- Pages are in `src/content/docs/`. Write links from the site's root —
  `/start/install/` — and `plugins/repo-links.mjs` adds the `/zit` base.
- The changelog, contributing guide, privacy and security policies are the
  repository's own files, imported as they are: edit `CHANGELOG.md` and the
  others at the root, not here.
- The screenshots and the icon come from `docs/screenshots/` and `assets/`.

`.github/workflows/pages.yml` builds the site on every pull request that
touches it, and publishes it from `main`.
