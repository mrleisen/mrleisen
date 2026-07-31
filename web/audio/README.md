# Station programme

One A Wired Spine track per station, streamed and looped at low level
while the dial is inside a station's tolerance window. Drop the files
here with exactly these names:

| Band | Freq   | Call | File            |
|------|--------|------|-----------------|
| FM   | 89.5   | ITNW | `aws-itnw.mp3`  |
| FM   | 92.4   | BBL  | `aws-bbl.mp3`   |
| FM   | 95.3   | WHO  | `aws-who.mp3`   |
| FM   | 98.7   | DTU  | `aws-dtu.mp3`   |
| FM   | 102.3  | TRP  | `aws-trp.mp3`   |
| FM   | 105.9  | AWS  | `aws-aws.mp3`   |
| AM   | 660    | NUM  | `aws-num.mp3`   |
| AM   | 820    | AYU  | `aws-ayu.mp3`   |
| AM   | 1000   | KIW  | `aws-kiw.mp3`   |
| AM   | 1120   | CSP  | `aws-csp.mp3`   |
| AM   | 1280   | NFT  | `aws-nft.mp3`   |
| AM   | 1600   | PNK  | `aws-pnk.mp3`   |

The names are the source of truth in `lib/models/station.dart` - the
`music:` field on each `Station`. Rename a file here and you rename it
there, or the station goes silent.

A missing file is survivable by design: the engine marks the track dead
on the first load error and the station broadcasts a carrier and nothing
else. The dial, the panels and the static all keep working, so this
folder can fill up one track at a time.

## Encoding

Mono or stereo MP3, 128 kbps is plenty - the programme peaks at 0.18
gain under a layer of static, so bitrate spent on top end is wasted.
Keep each file under ~4 MB: twelve of them ship in the repo and every
one is served from GitHub Pages.

Loop points are not honoured - the element loops the whole file, so a
track that ends cold will restart cold. Tracks that fade out and in, or
that are ambient enough not to announce the seam, work best.
