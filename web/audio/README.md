# Station programme

What the stations broadcast: A Wired Spine, streamed and looped at low
level while the dial is inside a station's tolerance window.

## Right now

`aws-routine-a-hello.ogg` - one file, played by all twelve stations.
Declared once as `_programme` in `lib/models/station.dart` and handed to
every `Station.music`.

Because the path is identical everywhere, moving from one station to
another does **not** reload or restart it: the engine only swaps `src`
when the path actually changes, so the track runs continuously across
the band. Dropping into dead air fades it out and pauses it; coming back
to any station resumes where it left off.

## The intended end state

One track per station, `_programme` deleted, and twelve distinct entries:

| Band | Freq   | Call | File           |
|------|--------|------|----------------|
| FM   | 89.5   | ITNW | `aws-itnw.…`   |
| FM   | 92.4   | BBL  | `aws-bbl.…`    |
| FM   | 95.3   | WHO  | `aws-who.…`    |
| FM   | 98.7   | DTU  | `aws-dtu.…`    |
| FM   | 102.3  | TRP  | `aws-trp.…`    |
| FM   | 105.9  | AWS  | `aws-aws.…`    |
| AM   | 660    | NUM  | `aws-num.…`    |
| AM   | 820    | AYU  | `aws-ayu.…`    |
| AM   | 1000   | KIW  | `aws-kiw.…`    |
| AM   | 1120   | CSP  | `aws-csp.…`    |
| AM   | 1280   | NFT  | `aws-nft.…`    |
| AM   | 1600   | PNK  | `aws-pnk.…`    |

Names keyed to the call sign rather than numbered, because a numbered set
misaligns silently the first time a station moves. This can be filled in
one track at a time - a station whose file is missing marks it dead after
one failed load and goes back to broadcasting a carrier and nothing else,
which the rest of the receiver already knows how to handle.

## Encoding

Ogg Vorbis plays in Chrome, Firefox and Edge, and in Safari from 17.
Older Safari and older iOS do not decode it and will land on the
missing-file path - silent station, everything else intact. An MP3 next
to the Ogg is what closes that gap; the engine takes one path per
station, so that means picking a format rather than offering both until
multi-source support exists.

128 kbps mono is plenty - the programme peaks at `_musicCeiling` (0.18)
underneath a layer of static, so bitrate spent on the top end is
inaudible. Keep files small; they ship in the repo and are served from
GitHub Pages.

Loop points are not honoured - the element loops the whole file, so a
track that ends cold restarts cold. Tracks that fade, or that are ambient
enough to hide the seam, work best.
