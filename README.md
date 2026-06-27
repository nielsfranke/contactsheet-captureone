# ContactSheet — Capture One export plugin

A Capture One **publish plugin** that exports selected variants straight into a
[ContactSheet](https://github.com/nielsfranke/contactsheet) gallery. Capture One renders the
variants per the export recipe; the plugin uploads them to a ContactSheet instance using a
personal access token (`cs_pat_…`), so no password is shared.

MIT-licensed and independent of ContactSheet itself (it only speaks ContactSheet's public REST
API over HTTPS). It links — but does **not** bundle — Capture One's proprietary
`CaptureOnePlugins.framework`.

## Status

Early. The current build is a **load-test stage**: it registers an "Upload to ContactSheet"
publish action and confirms the plugin loads in Capture One. The settings UI (instance URL /
token / gallery) and the actual upload are the next milestones.

## Building (no Xcode required)

The plugin builds with the macOS Command Line Tools (clang + codesign) — no full Xcode needed.
You do need the **Capture One Plugin SDK for macOS** (gated download from Capture One's developer
portal); point `CO_SDK` at the extracted folder if it isn't at the default path:

```bash
export CO_SDK="/path/to/Capture One Plugin SDK (Mac) v1.0.1"
./build.sh        # → build/ContactSheet.coplugin (universal arm64 + x86_64, ad-hoc signed)
./install.sh      # copies it to ~/Library/Application Support/Capture One/Plug-ins/
```

Restart Capture One, then check *Preferences → Plugins* (the Plugin Manager) for **ContactSheet**.

## Layout

| Path | Purpose |
|---|---|
| `Sources/CSContactSheetPlugin.m` | Plugin principal class (`COPublishingPlugin`) |
| `Info.plist` | Bundle manifest (`NSPrincipalClass`, author, version) |
| `build.sh` | Compile + assemble + ad-hoc sign the `.coplugin` |
| `install.sh` | Install into the user Plug-ins folder |
