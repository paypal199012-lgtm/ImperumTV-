#!/usr/bin/env python3
"""
Eigene Musik (lizenzfrei) für den TikTok-Baukasten – jedes Video bekommt einen eigenen Song.
Aufruf: music.py <ausgabe.wav> <anzahl_szenen> [stil] [startwert]

Stile (alle passen auf das Raster: Intro 2,6 s, jede Szene 3,6 s, Abschluss 3 s):
  drama    – ernst, Moll, 100 BPM, schwere Trommeln, Streicherfläche
  upbeat   – fröhlich, Dur, 133 BPM, Klatschen, helle Arpeggios
  chill    – Lo-Fi, 100 BPM, E-Piano, weicher Beat
  playful  – verspielt, Dur, 100 BPM, Zupf-Melodie, Pfeif-Lead
  epic     – groß, Moll, 133 BPM halbe Zeit, Pauken, Bläser-Akkorde
  tech     – modern, 133 BPM, pumpender Bass, Synth-Stabs
  funk     – lässig, 100 BPM, synkopierter Bass, Clavinet-Zupfer
  ambient  – ruhig, schwebende Flächen, Klavier-Arpeggio, kaum Schlagzeug
  house    – 133 BPM, durchgehende Bass-Drum, Offbeat-Bass, Orgel-Akkorde
  trap     – halbe Zeit, tiefer 808-Bass, schnelle Hi-Hat-Rollen, dunkle Glocke
  synthwave– 133 BPM, 80er-Synths, Achtel-Bass, Gated-Snare, Arpeggio
  piano    – ernst, Klavier-Akkorde, leiser Beat, Moll
  garage   – 2-Step, verschobene Bass-Drum, kurze Orgel-Stabs, Swing-Hi-Hats
Ohne Stil wird er aus dem Startwert (z. B. der Video-ID) gewählt.
"""
import sys, zlib
from synth import *

out, n_scenes = sys.argv[1], int(sys.argv[2])
style = sys.argv[3] if len(sys.argv) > 3 and sys.argv[3] else ''
seed_txt = sys.argv[4] if len(sys.argv) > 4 else style
seed = zlib.crc32(seed_txt.encode()) & 0xffffffff
STYLES = ['drama', 'upbeat', 'chill', 'playful', 'epic', 'tech', 'funk', 'ambient', 'house', 'trap', 'synthwave', 'piano', 'garage']
if style not in STYLES:
    style = STYLES[seed % len(STYLES)]

HOOK, SCENE, END = 2.6, 3.6, 3.0
D = HOOK + n_scenes * SCENE + END
m = Mix(D, seed % 1000)

# Tonart: Grundton je Video verschieben (−3 … +3 Halbtöne)
shift = 2 ** (((seed >> 8) % 7 - 3) / 12)
def f(name): return N(name) * shift
MAJOR = [['C4', 'E4', 'G4'], ['A3', 'C4', 'E4'], ['F3', 'A3', 'C4'], ['G3', 'B3', 'D4']]
MAJOR2 = [['F3', 'A3', 'C4'], ['G3', 'B3', 'D4'], ['C4', 'E4', 'G4'], ['A3', 'C4', 'E4']]
MINOR = [['A3', 'C4', 'E4'], ['F3', 'A3', 'C4'], ['C4', 'E4', 'G4'], ['G3', 'B3', 'D4']]
MINOR2 = [['A3', 'C4', 'E4'], ['D3', 'F3', 'A3'], ['E3', 'G3', 'B3'], ['A3', 'C4', 'E4']]

def notes(ch): return [f(x) for x in ch]

def pluck(freq, dur=0.25, g=0.15):
    n = int(SR * dur); t = np.arange(n) / SR
    s = np.sign(np.sin(2 * np.pi * freq * t)) * 0.5 + np.sin(2 * np.pi * freq * 2 * t) * 0.3
    return lp(s * env(n, 0.002, dur / 4), 3000) * g

def whistle(freq, dur, g=0.12):
    n = int(SR * dur); t = np.arange(n) / SR
    vib = 1 + 0.006 * np.sin(2 * np.pi * 5.5 * t)
    s = np.sin(2 * np.pi * np.cumsum(freq * vib) / SR)
    e = np.minimum(1, t / 0.04) * np.minimum(1, np.maximum(0, (dur - t) / 0.08))
    return s * e * g

def tom(freq=110, g=0.8):
    n = int(SR * 0.5); t = np.arange(n) / SR
    fr = freq * (1 + 0.6 * np.exp(-t * 18))
    return np.sin(2 * np.pi * np.cumsum(fr) / SR) * env(n, 0.002, 0.22) * g

def brass(ch, dur, g=0.06):
    s = sum(tone(x, dur, 'saw', a=0.08, gain=g) + tone(x * 1.004, dur, 'saw', a=0.08, gain=g) + tone(x / 2, dur, 'saw', a=0.08, gain=g * 0.6) for x in ch)
    return lp(s, 1800)

def intro(B, rise=True):
    t = 0.3
    while t < HOOK - 0.05:
        m.add(lp(kick(), 300), t, 0.5); m.add(hat(g=0.16), t + B / 2, 1, 0.3); t += B
    if rise: m.add(riser(2.2, 0.32), 0.4)

def outro(ch, B):
    e0 = HOOK + n_scenes * SCENE
    m.add(crash(0.28), e0); m.add(kick(True), e0)
    m.add(chord(notes(ch) + [notes(ch)[0] * 2], END, 0.06, 3000), e0)
    m.add(lp(tone(f('A2') / 2, END, 'sine', a=0.01, d=1.2, gain=0.5), 200), e0)

def transitions(g=0.22):
    for sc in range(n_scenes):
        s0 = HOOK + sc * SCENE
        m.add(whoosh(0.4, True, g), s0 - 0.38); m.add(crash(g), s0)

# ---------------------------------------------------------------- Stile
if style == 'drama':                      # 100 BPM, 6 Schläge pro Szene
    B = 0.6; prog = MINOR2
    m.add(lp(chord(notes(prog[0]), HOOK, 0.05, 700), 700), 0)
    for k in range(4): m.add(lp(kick(), 200), 0.3 + k * B, 0.7)
    m.add(riser(2.0, 0.3), 0.6)
    for sc in range(n_scenes):
        s0 = HOOK + sc * SCENE; ch = prog[sc % 4]
        m.add(tom(70, 1.0), s0); m.add(crash(0.22), s0); m.add(whoosh(0.5, True, 0.2), s0 - 0.48)
        m.add(lp(chord(notes(ch), SCENE, 0.06, 1500), 1500), s0, 1, 0.1)
        m.add(lp(tone(notes(ch)[0] / 2, SCENE, 'saw', a=0.3, gain=0.25), 300), s0)
        for k in range(6):
            tt = s0 + k * B
            m.add(kick(), tt, 0.9 if k % 3 == 0 else 0.5)
            if k % 3 == 2: m.add(snare(0.8), tt)
            m.add(hat(g=0.12), tt + B / 2, 1, 0.2)
            m.add(lp(tone(notes(ch)[k % 3] * 2, B * 0.9, 'tri', a=0.01, d=0.4, gain=0.06), 2500), tt, 1, -0.2)
    outro(prog[0], B)

elif style == 'upbeat':                   # 133 BPM, 8 Schläge pro Szene
    B = 0.45; prog = MAJOR if seed % 2 else MAJOR2
    intro(B); m.add(lp(chord(notes(prog[0]), HOOK, 0.05), 900), 0)
    transitions()
    for sc in range(n_scenes):
        s0 = HOOK + sc * SCENE
        m.add(kick(True), s0, 0.9)
        for k in range(8):
            tt = s0 + k * B; ch = prog[(sc * 2 + k // 4) % 4]
            if k: m.add(kick(), tt, 0.95)
            if k % 2: m.add(clap(), tt, 0.9)
            m.add(hat(), tt + B / 2, 1, 0.3); m.add(hat(g=0.15), tt + B / 4, 1, -0.3); m.add(hat(g=0.15), tt + 3 * B / 4, 1, -0.3)
            if k % 4 == 0: m.add(chord(notes(ch), 4 * B, 0.05, 4000), tt, 1, 0.15)
            for h in (0, B / 2): m.add(lp(tone(notes(ch)[0] / 2, B / 2 * 0.9, 'saw', a=0.004, d=0.12, gain=0.36), 700), tt + h)
            for q in range(4): m.add(tone(notes(ch)[q % 3] * 2, 0.1, 'tri', a=0.003, d=0.08, gain=0.07), tt + q * B / 4, 1, 0.25)
    outro(prog[0], B)

elif style == 'chill':                    # 100 BPM Lo-Fi
    B = 0.6; prog = [['F3', 'A3', 'C4', 'E4'], ['E3', 'G3', 'B3', 'D4'], ['D3', 'F3', 'A3', 'C4'], ['C3', 'E3', 'G3', 'B3']]
    m.add(lp(noise(int(SR * D)), 3000) * 0.012, 0)
    t = 0.3; k = 0
    while t < D - 0.3:
        ch = prog[(k // 6) % 4]
        if k % 6 in (0, 3): m.add(kick(soft=True), t, 1.0)
        if k % 6 in (2, 5): m.add(lp(snare(), 3500), t, 0.55)
        m.add(hat(g=0.14), t + B * 0.55, 1, 0.25)
        if k % 6 == 0:
            m.add(epiano(notes(ch), 6 * B, 0.09), t, 1, 0.1)
            m.add(lp(tone(notes(ch)[0] / 2, 6 * B * 0.95, 'sine', a=0.02, d=1.6, gain=0.33), 300), t)
        t += B; k += 1
    for sc in range(n_scenes): m.add(ding(1318 * shift, 0.14), HOOK + sc * SCENE + 0.02, 1, -0.15)
    m.add(epiano(notes(prog[0]) + [notes(prog[0])[1] * 2], END, 0.1), HOOK + n_scenes * SCENE)

elif style == 'playful':                  # 100 BPM, Zupfen + Pfeifen
    B = 0.6; prog = MAJOR2
    melody = [0, 2, 1, 2, 0, 1]
    for k in range(8): m.add(pluck(notes(prog[0])[k % 3] * 2, 0.2, 0.13), 0.2 + k * B / 2, 1, 0.2 if k % 2 else -0.2)
    m.add(lp(chord(notes(prog[0]), HOOK, 0.05, 2000), 2000), 0); m.add(riser(1.6, 0.25), 1.0)
    for k in range(4): m.add(lp(kick(), 500), 0.2 + k * B, 0.6)
    for sc in range(n_scenes):
        s0 = HOOK + sc * SCENE; ch = prog[sc % 4]
        m.add(pop(900 * shift, 0.18), s0)
        for k in range(6):
            tt = s0 + k * B
            m.add(lp(kick(), 600), tt, 0.7 if k % 2 == 0 else 0.0)
            if k % 2: m.add(clap(), tt, 0.5)
            m.add(lp(tone(notes(ch)[0] / 2, B * 0.5, 'sine', a=0.005, d=0.2, gain=0.4), 300), tt)
            for q in range(2): m.add(pluck(notes(ch)[(k + q) % 3] * 2, 0.2, 0.11), tt + q * B / 2, 1, 0.2 - 0.4 * q)
        for i, d in enumerate(melody[:4]):
            m.add(whistle(notes(ch)[d] * 2, B * 1.4, 0.09), s0 + i * B * 1.5, 1, -0.1)
    outro(prog[2], B)

elif style == 'epic':                     # halbe Zeit (66,7 BPM gefühlt), große Pauken
    B = 0.45; prog = MINOR
    m.add(riser(2.4, 0.38), 0.2); m.add(lp(brass(notes(prog[0]), HOOK, 0.04), 900), 0)
    for sc in range(n_scenes):
        s0 = HOOK + sc * SCENE; ch = prog[sc % 4]
        m.add(kick(True), s0, 1.0); m.add(crash(0.3), s0); m.add(whoosh(0.5, True, 0.22), s0 - 0.48)
        m.add(brass(notes(ch), SCENE * 0.95, 0.055), s0, 1, 0.1)
        for k in range(8):
            tt = s0 + k * B
            if k % 4 == 0: m.add(tom(65, 1.0), tt)
            if k % 4 == 2: m.add(snare(0.9), tt); m.add(tom(98, 0.5), tt + B / 2)
            m.add(hat(g=0.1), tt + B / 2, 1, 0.3)
        for q in range(8): m.add(lp(tone(notes(ch)[0] / 2, B * 0.45, 'saw', a=0.004, d=0.1, gain=0.3), 500), s0 + q * B)
    outro(prog[0], B)

elif style == 'funk':                     # 100 BPM, synkopiert
    B = 0.6; prog = [['A3', 'C4', 'E4'], ['D3', 'F3', 'A3'], ['G3', 'B3', 'D4'], ['C4', 'E4', 'G4']]
    for k in range(8): m.add(hat(g=0.18), 0.2 + k * B / 2)
    m.add(riser(1.8, 0.25), 0.8)
    for pos in (0, 0.75, 1.5, 2.5, 3.25): m.add(lp(tone(f('A2'), B * 0.35, 'sq', a=0.003, d=0.12, gain=0.28), 500), 0.2 + pos * B * 0.66)
    m.add(lp(chord(notes([['A3', 'C4', 'E4']][0]), HOOK, 0.05, 1500), 1500), 0)
    bass_pat = [(0, 1.0), (0.75, 0.6), (1.5, 0.8), (2.5, 1.0), (3.25, 0.6), (4.0, 0.8), (5.0, 0.7)]
    for sc in range(n_scenes):
        s0 = HOOK + sc * SCENE; ch = prog[sc % 4]
        m.add(crash(0.18), s0)
        for k in range(6):
            tt = s0 + k * B
            if k in (0, 3): m.add(kick(), tt, 0.95)
            if k in (1.5,): pass
            if k in (1, 4): m.add(snare(0.85), tt)
            for q in range(4): m.add(hat(g=0.12 if q % 2 else 0.18), tt + q * B / 4, 1, 0.25)
        m.add(kick(), s0 + 2.5 * B, 0.7)
        for pos, g in bass_pat:
            m.add(lp(tone(notes(ch)[0] / 2 * (1.5 if pos == 2.5 else 1), B * 0.35, 'sq', a=0.003, d=0.12, gain=0.28 * g), 500), s0 + pos * B)
        for q in (0.5, 1.5, 2.75, 3.5, 4.5, 5.5):
            m.add(lp(chord(notes(ch), 0.14, 0.07, 3500), 3500), s0 + q * B, 1, 0.25)
    outro(prog[0], B)

elif style == 'ambient':                  # ruhig, schwebend
    B = 0.45; prog = [['C4', 'E4', 'G4', 'B4'], ['A3', 'C4', 'E4', 'G4'], ['F3', 'A3', 'C4', 'E4'], ['G3', 'B3', 'D4', 'F4']]
    m.add(lp(chord(notes(prog[0]), HOOK + 0.5, 0.045, 1200), 1200), 0)
    for sc in range(n_scenes):
        s0 = HOOK + sc * SCENE; ch = prog[sc % 4]
        m.add(lp(chord(notes(ch), SCENE + 0.6, 0.045, 1600), 1600), s0 - 0.2, 1, 0.1)
        m.add(lp(tone(notes(ch)[0] / 2, SCENE, 'sine', a=0.3, gain=0.3), 300), s0)
        m.add(lp(kick(soft=True), 300), s0, 0.8)
        m.add(ding(notes(ch)[2] * 4, 0.08), s0 + 0.05, 1, -0.3)
        for k in range(8):
            nn = notes(ch)[[0, 1, 2, 3, 2, 1, 2, 3][k]] * 2
            m.add(tone(nn, 0.9, 'sine', a=0.004, d=0.5, gain=0.1) + tone(nn * 2, 0.9, 'sine', a=0.004, d=0.25, gain=0.03), s0 + k * B, 1, 0.3 if k % 2 else -0.3)
            if sc >= 1 and k % 2 == 1: m.add(hat(g=0.08), s0 + k * B, 1, 0.2)
    e0 = HOOK + n_scenes * SCENE
    m.add(lp(chord(notes(prog[0]), END, 0.05, 1800), 1800), e0)
    m.add(epiano(notes(prog[0]), END, 0.08), e0)

elif style == 'tech':                     # 133 BPM, pumpender Bass
    B = 0.45; prog = MINOR2
    intro(B, rise=True)
    transitions(0.2)
    for sc in range(n_scenes):
        s0 = HOOK + sc * SCENE
        for k in range(8):
            tt = s0 + k * B; ch = prog[(sc + k // 4) % 4]
            m.add(kick(), tt, 1.0)
            m.add(hat(op=True, g=0.18), tt + B / 2, 1, 0.25)
            if k % 2: m.add(clap(), tt, 0.6)
            # Bass „pumpt“: leise auf dem Schlag, laut dazwischen
            m.add(lp(tone(notes(ch)[0] / 2, B * 0.45, 'saw', a=0.06, d=0.2, gain=0.42), 600), tt + B * 0.5)
            if k in (0, 3, 6): m.add(lp(chord(notes(ch), 0.18, 0.08, 5000), 5000), tt + (B * 0.75 if k == 3 else 0), 1, 0.2)
    outro(prog[0], B)

elif style == 'house':                    # 133 BPM, Four-on-the-floor, Offbeat-Bass
    B = 0.45; prog = MINOR
    intro(B)
    m.add(lp(chord(notes(prog[0]), HOOK, 0.04, 800), 800), 0)
    transitions(0.18)
    for sc in range(n_scenes):
        s0 = HOOK + sc * SCENE; ch = prog[sc % 4]
        for k in range(8):
            tt = s0 + k * B
            m.add(kick(), tt, 1.0)
            m.add(hat(op=True, g=0.2), tt + B / 2, 1, 0.3)
            if k % 2: m.add(clap(), tt, 0.55)
            m.add(lp(tone(notes(ch)[0] / 2, B * 0.4, 'sq', a=0.004, d=0.15, gain=0.3), 450), tt + B / 2)
            if k % 2 == 0: m.add(lp(chord(notes(ch), B * 0.35, 0.06, 2200, 'sq'), 2200), tt + B * 0.75, 1, -0.2)
    outro(prog[0], B)

elif style == 'trap':                     # halbe Zeit, 808, Hi-Hat-Rollen
    B = 0.45; prog = MINOR2
    m.add(lp(chord(notes(prog[0]), HOOK, 0.035, 900), 900), 0); m.add(riser(2.0, 0.28), 0.5)
    for sc in range(n_scenes):
        s0 = HOOK + sc * SCENE; ch = prog[sc % 4]
        m.add(whoosh(0.4, True, 0.18), s0 - 0.38)
        m.add(lp(tone(notes(ch)[0] / 4, SCENE * 0.9, 'sine', a=0.005, d=1.4, gain=0.7), 180), s0)       # 808
        m.add(lp(tone(notes(ch)[0] / 4, B * 2, 'sine', a=0.005, d=0.6, gain=0.5), 180), s0 + 5 * B)
        m.add(kick(True), s0, 0.9); m.add(kick(), s0 + 5 * B, 0.8)
        m.add(snare(0.9), s0 + 2 * B); m.add(snare(0.9), s0 + 6 * B)
        for q in range(16):
            if q in (11, 15):
                for r in range(3): m.add(hat(g=0.12), s0 + q * B / 2 + r * B / 6, 1, 0.3)
            else: m.add(hat(g=0.15), s0 + q * B / 2, 1, 0.3)
        for i, d in enumerate([0, 2, 1, 2]): m.add(ding(notes(ch)[d] * 2, 0.07), s0 + i * B * 2, 1, -0.25)
    outro(prog[0], B)

elif style == 'synthwave':                # 133 BPM, 80er
    B = 0.45; prog = [['A3', 'C4', 'E4'], ['F3', 'A3', 'C4'], ['C4', 'E4', 'G4'], ['G3', 'B3', 'D4']]
    intro(B); m.add(lp(brass(notes(prog[0]), HOOK, 0.03), 1200), 0)
    transitions(0.2)
    for sc in range(n_scenes):
        s0 = HOOK + sc * SCENE; ch = prog[sc % 4]
        m.add(lp(brass(notes(ch), SCENE * 0.95, 0.035), 1400), s0, 1, 0.1)
        for k in range(8):
            tt = s0 + k * B
            if k % 2 == 0: m.add(kick(), tt, 1.0)
            if k % 4 == 2: m.add(snare(1.0), tt); m.add(crash(0.06), tt)
            m.add(hat(g=0.14), tt + B / 2, 1, 0.3)
            for h in (0, B / 2): m.add(lp(tone(notes(ch)[0] / 2, B / 2 * 0.85, 'saw', a=0.003, d=0.1, gain=0.3), 900), tt + h)
            for q in range(2): m.add(lp(tone(notes(ch)[(k * 2 + q) % 3] * 2, B / 2 * 0.8, 'sq', a=0.003, d=0.12, gain=0.05), 3500), tt + q * B / 2, 1, -0.3 if q else 0.3)
    outro(prog[0], B)

elif style == 'piano':                    # ernst, Klavier, 100 BPM
    B = 0.6; prog = MINOR2
    def piano(nn, dur, g=0.12):
        return sum(tone(x, dur, 'sine', a=0.003, d=dur * 0.45, gain=g) + tone(x * 2, dur, 'sine', a=0.003, d=dur * 0.2, gain=g * 0.35) + tone(x * 3, dur, 'sine', a=0.003, d=dur * 0.1, gain=g * 0.12) for x in nn)
    m.add(piano(notes(prog[0]), HOOK, 0.1), 0.1)
    for sc in range(n_scenes):
        s0 = HOOK + sc * SCENE; ch = prog[sc % 4]
        m.add(piano([notes(ch)[0] / 2] + notes(ch), SCENE, 0.09), s0)
        m.add(lp(tone(notes(ch)[0] / 2, SCENE, 'sine', a=0.2, gain=0.25), 250), s0)
        for k in range(6):
            tt = s0 + k * B
            if k in (0, 3): m.add(lp(kick(soft=True), 400), tt, 0.8)
            if k in (2, 5) and sc >= 1: m.add(lp(snare(0.6), 4000), tt)
            if k: m.add(piano([notes(ch)[[2, 1, 2, 0, 1][k - 1]] * 2], B * 1.5, 0.07), tt, 1, 0.25)
    e0 = HOOK + n_scenes * SCENE
    m.add(piano([notes(prog[0])[0] / 2] + notes(prog[0]), END, 0.1), e0)

else:                                     # garage: 2-Step mit Swing
    B = 0.45; prog = [['D3', 'F3', 'A3', 'C4'], ['G3', 'B3', 'D4', 'F4'], ['C4', 'E4', 'G4', 'B4'], ['A3', 'C4', 'E4', 'G4']]
    intro(B, rise=False); m.add(riser(1.8, 0.24), 0.7)
    transitions(0.16)
    sw = B / 2 * 0.16
    for sc in range(n_scenes):
        s0 = HOOK + sc * SCENE; ch = prog[sc % 4]
        for bar in range(2):
            b0 = s0 + bar * 4 * B
            for pos in (0, 1.75, 2.5): m.add(kick(), b0 + pos * B, 0.9)
            for pos in (1, 3): m.add(snare(0.8), b0 + pos * B)
            for q in range(8): m.add(hat(g=0.13 if q % 2 else 0.17), b0 + q * B / 2 + (sw if q % 2 else 0), 1, 0.3)
            for pos in (0.5, 1.75, 3.25): m.add(lp(chord(notes(ch), 0.16, 0.07, 2600, 'sq'), 2600), b0 + pos * B, 1, -0.2)
            for pos, g in ((0, 1), (1.5, 0.7), (2.5, 0.9)): m.add(lp(tone(notes(ch)[0] / 2, B * 0.6, 'sine', a=0.004, d=0.3, gain=0.45 * g), 250), b0 + pos * B)
    outro(prog[2][:3], B)

m.save(out, fade_from=D - 1.3)
print(style, round(D, 2))
