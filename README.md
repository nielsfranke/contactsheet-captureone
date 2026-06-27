# ContactSheet — Capture One export plugin

A Capture One **publish plugin** that exports selected variants straight into a
[ContactSheet](https://github.com/nielsfranke/contactsheet) gallery. Capture One renders the
variants per its export recipe; the plugin uploads them to your ContactSheet instance using a
personal access token (`cs_pat_…`) — no password is shared.

MIT-licensed and independent of ContactSheet itself: it only speaks ContactSheet's public REST API
over HTTPS. It links — but does **not** bundle — Capture One's proprietary
`CaptureOnePlugins.framework` (Capture One ships its own copy).

## Features

- **Publish to a gallery** from Capture One's normal Publish flow, with the full Format & Size
  recipe (format, resolution, scaling, sharpening, metadata) under your control.
- **Pick a destination gallery** from a hierarchy-aware dropdown (sub-galleries are indented), with
  an optional filter box for large libraries.
- **Create a gallery on the fly** — type a name, choose the mode (**Showcase** or **Review**), tick
  *Create new gallery*, and it's created and selected.
- **Export recipes** — define multiple named recipes (e.g. *Client full*, *Web preview*). Each
  becomes its own “ContactSheet: …” entry in the Publish menu, and Capture One remembers its render
  settings **and** gallery separately.
- Upload progress, cancellation, clear error messages, and a success notification that links to the
  gallery.

## Requirements

- macOS with the **Command Line Tools** (`xcode-select --install`) — full Xcode is **not** required.
- **Capture One** with plugin support (tested against 16.6, which ships `CaptureOnePlugins.framework`
  v1.0.1).
- A **ContactSheet** instance, reachable over HTTPS (or `http://127.0.0.1:…` for local testing).
- To build: the **Capture One Plugin SDK for macOS** (gated download from Capture One's
  [developer portal](https://www.captureone.com/en/partnerships/developer)).

## Install

There's no pre-built release yet — build from source (see [Building](#building)):

```bash
export CO_SDK="/path/to/Capture One Plugin SDK (Mac) v1.0.1"   # if not at the default path
./build.sh && ./install.sh
```

Then **restart Capture One**.

## Setup

1. **In ContactSheet** (admin): *Settings → API tokens → Create token*. Give it the
   `galleries:read`, `galleries:write` and `images:write` permissions and copy the `cs_pat_…`
   secret (shown once).
2. **In Capture One**: *Preferences → Plugins → ContactSheet*:
   - **Instance URL** — e.g. `https://photos.example.com` (or `http://127.0.0.1:8000` locally).
   - **API token** — paste the `cs_pat_…`.
   - Click **Load galleries**, then pick a **Default gallery**.

## Usage

Select one or more photos → **Publish → “Upload to ContactSheet”** (or a recipe entry). In the
**ContactSheet** tab of the publish dialog:

- **Upload to** — choose the destination gallery (filter if the list is long).
- **New gallery** — or type a name, pick **Showcase/Review**, and tick **Create new gallery**.

Capture One renders the variants per the recipe below and the plugin uploads them. On success a
notification appears with a *Show* button that opens the gallery.

### Recipes

In *Preferences → Plugins → ContactSheet → **Recipes** tab*, add / rename / remove recipes. Each
recipe is a separate **“ContactSheet: <name>”** publish action whose render recipe (Format & Size)
is persisted by Capture One and whose gallery is remembered by the plugin — so one recipe can be
full-resolution to a client gallery and another a 2000 px web preview to a review gallery.

## How it works

Capture One renders the selected variants to temporary files, then calls the plugin's
`startPublishingTask:`, which multipart-`POST`s them to `/api/galleries/{id}/images` with an
`Authorization: Bearer cs_pat_…` header. Gallery listing uses `GET /api/galleries`; creation uses
`POST /api/galleries`. Settings persist in a private `NSUserDefaults` suite; the plugin runs in
Capture One's out-of-process `COPluginHost`.

## Building

Builds with the Command Line Tools only — `build.sh` compiles the Objective-C source against the SDK
framework, assembles the `.coplugin` bundle (universal arm64 + x86_64), generates the icon, and
ad-hoc code-signs it. No Xcode, no `.xcodeproj`.

```bash
export CO_SDK="/path/to/Capture One Plugin SDK (Mac) v1.0.1"
./build.sh     # → build/ContactSheet.coplugin
./install.sh   # → ~/Library/Application Support/Capture One/Plug-ins/
```

> The Capture One Plugin SDK is proprietary and is **not** included in this repo (it's gitignored).

## Project layout

| Path | Purpose |
|---|---|
| `Sources/CSContactSheetPlugin.m` | The plugin (principal class: `COPublishingPlugin` + `COActionSettings` + `COSettings`) |
| `Info.plist` | Bundle manifest (`NSPrincipalClass`, icon, author, version) |
| `Resources/ContactSheet.png` | Plugin icon source (built into a multi-size `.icns`) |
| `build.sh` | Compile + assemble + sign the `.coplugin` |
| `install.sh` | Install into the user Plug-ins folder |

## Roadmap

- Gallery **cover thumbnails** in the gallery dropdown.
- **Upload to multiple galleries** at once.

## License

[MIT](LICENSE) © 2026 Niels Franke. Not affiliated with Capture One / Phase One.
