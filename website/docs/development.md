---
title: Development
sidebar_position: 3
description: Run the server, app and website locally.
---

# Development

## Server

```bash
cd server
go test ./...
go run . \
  --listen 127.0.0.1:8787 \
  --token-file /tmp/nixos-control-token \
  --allow-rebuild=false \
  --allow-power=false
```

The server is intentionally dependency-free (`go.mod` only). It is built by
NixOS with `buildGoModule`.

## iOS

```bash
cd ios
xcodegen generate
xcodebuild -project NixOSControl.xcodeproj \
  -scheme NixOSControl \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  CODE_SIGNING_ALLOWED=NO build
```

## Website

The website lives in `website/` and contains both the marketing page at `/` and
this documentation at `/docs`.

```bash
cd website
npm install
npm run start
```

`npm run start` serves the site at `http://localhost:3000/nixos/` by default.
The marketing page is the root route; documentation is under `/docs`.

Build and preview the production output:

```bash
npm run build
npm run serve
```

### Deployment

Every push to `main` triggers the **Deploy website** GitHub Actions workflow. It
builds `website/` and publishes the result to GitHub Pages using the official
Pages actions.

One-time repository setup:

1. Open **Settings → Pages**.
2. Set **Build and deployment → Source** to **GitHub Actions**.

The project site is published at `https://403access.github.io/nixos/`. To use a
custom domain at the domain root, set the `SITE_BASE_URL` environment variable
to `/` in the workflow and add a `static/CNAME` file with your domain.

## Repository conventions

- Keep the server stdlib-only.
- Update `website/docs/` when behaviour changes; the docs deploy with the site.
- Screenshots used by the site are copied to `website/static/img/screenshots/`.
