# Station programme

What the stations broadcast: A Wired Spine, one track per station,
streamed and looped at low level while the dial is inside a station's
tolerance window.

## The band plan

FM carries *Rutina* (2012) in album order, with two swaps: *un dilema*
plays on WHO, the station about Rafael, and *un hola* on DTU, DeTodoUIS.
AM carries *Please, Please!!!* and two songs from the 2011 EP.

| Band | Freq   | Call | File        | Track                                    |
|------|--------|------|-------------|------------------------------------------|
| FM   | 89.5   | ITNW | `aws-itnw.…` | una preocupación                         |
| FM   | 92.4   | BBL  | `aws-bbl.…`  | una compra                               |
| FM   | 95.3   | WHO  | `aws-who.…`  | un dilema                                |
| FM   | 98.7   | DTU  | `aws-dtu.…`  | un hola                                  |
| FM   | 102.3  | TRP  | `aws-trp.…`  | una encerrona                            |
| FM   | 105.9  | AWS  | `aws-aws.…`  | un adios                                 |
| AM   | 660    | NUM  | `aws-num.…`  | Remember the day we were happy, please!! |
| AM   | 820    | AYU  | `aws-ayu.…`  | y tu                                     |
| AM   | 1000   | KIW  | `aws-kiw.…`  | Vámonos Por La sombrita, Por Favor!!!    |
| AM   | 1120   | CSP  | `aws-csp.…`  | Beware Of The Sad Word                   |
| AM   | 1280   | NFT  | `aws-nft.…`  | The Empty Space Between L VE             |
| AM   | 1440   | PIX  | `aws-pix.…`  | hielito                                  |
| AM   | 1600   | PNK  | `aws-pnk.…`  | ITIHSTS                                  |

Names keyed to the call sign rather than numbered, because a numbered set
misaligns silently the first time a station moves. A station whose file
is missing marks it dead after one failed load and goes back to
broadcasting a carrier and nothing else, which the rest of the receiver
already knows how to handle.

Moving between stations swaps `src`. The engine remembers where each
track was, so coming back to a station resumes it rather than restarting
it. Dropping into dead air fades the music out and pauses it.

## The sound

These are not meant to sound good. Anyone who wants to hear the songs
properly has SoundCloud; here they are a radio in the next room. Every
track goes through the same chain with ffmpeg, from the source MP3s:

1. Mono, leading and trailing silence trimmed.
2. Band-limited to roughly 700 Hz - 5 kHz with a presence lift near
   2 kHz (the curve the first shipped track was mastered with):
   `highpass=f=700:p=2,highpass=f=700:p=2,highpass=f=600:p=2,lowpass=f=5000:p=2,lowpass=f=6000:p=2,equalizer=f=2000:t=o:w=2.5:g=9`
3. Dulled, to take the shine off that lift:
   `equalizer=f=2000:t=o:w=2.5:g=-8,equalizer=f=800:t=o:w=1.5:g=3,lowpass=f=3200:p=2,lowpass=f=3500:p=2`
4. Gain-matched to -22.5 LUFS integrated, limited at -4 dBFS, 0.3 s fade
   in and 2 s fade out so the loop seam is soft.

*un hola* gets one more step before 3: its two-note bell (A and F,
sounding in several octaves at once) ends up ~16 dB over everything else
once band-limited, so every octave of both notes is cut with narrow
peaking filters (880 Hz -20/-15, 440 -14, 1760 -12, 698.5 -16, 1397 -15,
349.2 -10 dB).

## Encoding

**Ship every track twice: `<name>.ogg` and `<name>.mp3`.**

Ogg Vorbis plays in Chrome, Firefox and Edge, and in Safari from 17 -
older Safari and older iOS do not decode it at all. Stations declare the
`.ogg` path and nothing else; the engine probes `canPlayType` once and
swaps the extension to `.mp3` for a browser that can't take the Ogg
(`_resolveMusicSrc` in `lib/components/radio_audio.dart`). The `<audio>`
element takes one `src` at a time, so this is the substitute for the
`<source>` children a plain player would use.

A track with no MP3 sibling still works everywhere Ogg works, and lands
on the missing-file path - silent station, everything else intact - where
it doesn't. So the pair is a requirement of reaching every browser, not
of the engine running.

Both at 22.05 kHz mono: Vorbis `-q:a 0` (~28 kbps), MP3 32 kbps CBR. The
chain above leaves nothing above ~3.5 kHz and the programme peaks at
`_musicCeiling` (0.304) underneath a layer of static, so anything more is
bitrate nobody hears. All thirteen pairs come to about 11 MB; they ship
in the repo and are served from GitHub Pages.

Loop points are not honoured - the element loops the whole file, so a
track that ends cold restarts cold. That is what the fade out is for.
