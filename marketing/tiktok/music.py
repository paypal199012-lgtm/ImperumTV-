#!/usr/bin/env python3
"""Eigene Musik (lizenzfrei) passend zum Baukasten: Intro mit Aufbau, jede Szene 8 Schläge mit Becken am Anfang, Schlussakkord."""
import sys
from synth import *
out, n_scenes = sys.argv[1], int(sys.argv[2])
B, HOOK, SCENE, END = 0.45, 2.6, 3.6, 3.0
D = HOOK + n_scenes * SCENE + END
m = Mix(D)
prog = [['A3', 'C4', 'E4'], ['F3', 'A3', 'C4'], ['C4', 'E4', 'G4'], ['G3', 'B3', 'D4']]
t = 0.35
while t < HOOK - 0.05:
    m.add(lp(kick(), 300), t, 0.6); m.add(hat(g=0.2), t + B / 2, 1, 0.3); t += B
m.add(riser(2.2, 0.35), 0.4); m.add(lp(chord([N(x) for x in prog[0]], HOOK, 0.05), 900), 0.0)
for sc in range(n_scenes):
    s0 = HOOK + sc * SCENE
    m.add(crash(0.25), s0); m.add(whoosh(0.4, True, 0.25), s0 - 0.38); m.add(kick(True), s0, 0.9)
    for k in range(8):
        tt = s0 + k * B
        if k > 0: m.add(kick(), tt, 0.95)
        m.add(hat(), tt + B / 2, 1, 0.3); m.add(hat(g=0.18), tt + B / 4, 1, -0.3); m.add(hat(g=0.18), tt + 3 * B / 4, 1, -0.3)
        if k % 2 == 1: m.add(clap(), tt, 0.9)
        ch = prog[(sc * 2 + k // 4) % 4]
        if k % 4 == 0: m.add(chord([N(x) for x in ch], 4 * B, 0.055, 3500), tt, 1, 0.15)
        for h in (0, B / 2): m.add(lp(tone(N(ch[0]) / 2, B / 2 * 0.9, 'saw', a=0.004, d=0.12, gain=0.38), 700), tt + h)
        if sc % 2 == 1:
            for q in range(4): m.add(tone(N(ch[q % 3]) * 2, 0.1, 'tri', a=0.003, d=0.08, gain=0.07), tt + q * B / 4, 1, 0.25)
    m.add(ding(1760, 0.12), s0 + 0.05, 1, -0.2)
e0 = HOOK + n_scenes * SCENE
m.add(crash(0.3), e0); m.add(kick(True), e0)
m.add(chord([N('A3'), N('C4'), N('E4'), N('A4')], END, 0.06, 3000), e0); m.add(lp(tone(55, END, 'sine', a=0.01, d=1.2, gain=0.5), 200), e0)
for k in range(6): m.add(hat(g=0.25), e0 + k * B + B / 2); m.add(lp(kick(), 400), e0 + k * B, 0.5)
m.save(out, fade_from=D - 1.3)
print(round(D, 2))
