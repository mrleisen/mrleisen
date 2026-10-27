# Station logos

Each project's own mark, copied from its own repo and never redrawn here.
The originals sit in this folder untouched; what ships is in `web/logos/`,
referenced from `Station.logo` in `lib/models/station.dart`.

| Call  | Original here              | Taken from                                               | Ships as           |
|-------|----------------------------|----------------------------------------------------------|--------------------|
| CRM   | `criptomano-mark.png`      | `criptomano/assets/brand/criptomano-mark.png`             | `criptomano.png`   |
| ITNW  | `itnw-watermark.png`       | `itnw_machine/img/watermark.png`                         | `itnw.png`         |
| BBL   | `bbl-logotipo.png`         | `bbl/assets/images/logotipo.png` (launcher icon)         | `bbl.png`          |
| DTU   | `dtu-logotipo_v4.png`      | `detodouis_core/assets/images/logotipo_v4.png`           | `dtu.png`          |
| TRP   | `trp-tropelorio.png`       | `tropelorio/assets/images/tropleorio.png`                | `trp.png`          |
| AWS   | `aws-spine-logo.svg`       | `awiredspine/web/assets/spine-logo.svg`                  | `aws.svg`          |
| DMTFY | `dmtfy-logo_mark.svg`      | `dmtfy/design/brand/svg/logo_mark.svg` (base logo)       | `dmtfy.svg`        |

Also kept for reference, not shipped: `bbl-logo.svg` (the Inkscape
source, whose artwork sits outside its own viewBox), `dtu-logo_v4.png`
(the wordmark), `dtu-logotipo_v4_ios.png` and `dmtfy-favicon.svg`.

WHO has no logo (it is a person). Most AM ideas have no mark; ITNW retains its original logo after moving to AM.

## How the PNGs were prepared

All cropped to their visible pixels and scaled to 192 px on the long side
(the panel draws them at 56 px, 44 px on phones, so this covers 3x).

- **BBL**: the dark disc behind the mark is removed. On the CRT it was a
  slightly lighter circle than the screen around it, which read as a
  sticker. The gold edge pixels are re-alphaed so the outline stays clean.
- **DTU**: the black outline is recoloured to warm white (`#E9E4D8`).
  The original is drawn for a light background; on the black screen its
  outline vanished and the ring lost its shape.
- **TRP**: scaled with nearest-neighbour, since it is flat blocks.
- **CRM**: transparent approved symbol, cropped and scaled without recolouring.
- **ITNW**: as is; it already is a glow on transparency.

`aws.svg` is copied byte for byte. `dmtfy.svg` only has its viewBox
cropped to the mark (`9 18.5 84 52`): the brand file is a 512 px square
with the worm in a thin band across the middle, so at the same height
it drew at half the size of every other logo.
