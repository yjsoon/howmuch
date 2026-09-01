# Halation — the HowMuch app icon

A small cream sun sits on the upper ridgeline of a rising landscape — simultaneously
a dawn sun and the marker you drag along your net-worth chart. Its glow is
posterized into stepped rings ("halation": the halo that bleeds around a bright
light source on film), over a rose-mauve dusk in light mode and a near-black
sky in dark mode. The palette is the app's own: cream paper, ledger greens,
warm amber light.

## Files

- `halation-light.svg`, `halation-dark.svg` — master artwork, 1024×1024,
  edge-to-edge (no rounded corners: the OS applies its own mask). All colour
  and geometry changes should be made here and re-exported.
- `png/` — rasterized exports at 1024/512/256/180/120/64/32 for both variants,
  plus `halation-tinted-1024.png` (grayscale of the dark variant, used for the
  iOS tinted appearance).
- `icon-composer/` — the artwork split into stacked layers (`1-sky`,
  `2-back-ridge`, `3-front-ridge`, `4-marker`) for each variant, for import
  into Apple's Icon Composer as a layered icon with depth/specular effects.
  Layers composite back to the exact master image.
- `HowMuch.icon` — a ready-made Icon Composer document: the warm sky as the
  icon fill (with a near-black dark-appearance override), and glow, ridges,
  and marker as stacked layers, the marker with Liquid Glass + specular
  enabled. Open in Icon Composer to fine-tune appearances, then export or
  reference from Xcode 26.

## Where it's used

- **iOS**: `apps/ios/HowMuch/Assets.xcassets/AppIcon.appiconset` — single
  1024px universal icon with dark and tinted appearance variants, wired into
  the Xcode project via `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`.
- **Web**: `apps/web/public/favicon.svg` (the light master), plus
  `icon-192.png`, `icon-512.png`, and `apple-touch-icon.png` (180px), linked
  from `apps/web/index.html`. The in-app mark is the same light master,
  imported by `apps/web/src/components/Brand.tsx` into the sidebar, the API
  docs header, and the sign-in / setup screen.

## Re-exporting

```sh
python3 -c "
import cairosvg
for v in ('light','dark'):
    for s in (1024,512,256,180,120,64,32):
        cairosvg.svg2png(url=f'assets/icon/halation-{v}.svg',
                         output_width=s, output_height=s,
                         write_to=f'assets/icon/png/halation-{v}-{s}.png')
"
```

The tinted iOS variant is the dark 1024 PNG converted to grayscale.
