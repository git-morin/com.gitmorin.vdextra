import math, struct, wave

SR, T = 44100, 24.0           # loop length in seconds
N = int(SR * T)

def q(f):                      # quantise to a whole number of cycles per loop
    return round(f * T) / T

# Am - F - C - G, as sustained pads that crossfade on a wrap-around window
CHORDS = [[220.0, 261.63, 329.63],
          [174.61, 220.0, 261.63],
          [196.0, 261.63, 329.63],
          [196.0, 246.94, 293.66]]
BASS = [110.0, 87.31, 98.0, 98.0]

left, right = [], []
for n in range(N):
    t = n / SR
    u = t / T
    ws = [(0.5 + 0.5 * math.cos(2 * math.pi * (u - i / 4.0))) ** 2 for i in range(4)]
    tot = sum(ws) or 1.0
    l = r = 0.0
    for i, w in enumerate(ws):
        w /= tot
        if w < 1e-4:
            continue
        for j, f in enumerate(CHORDS[i]):
            fq = q(f)
            # a couple of soft harmonics keeps it a pad rather than a bare sine
            v = (math.sin(2 * math.pi * fq * t)
                 + 0.30 * math.sin(2 * math.pi * q(fq * 2) * t)
                 + 0.12 * math.sin(2 * math.pi * q(fq * 3) * t))
            pan = 0.5 + 0.28 * (j - 1)          # spread the voices
            l += w * v * (1 - pan) * 0.30
            r += w * v * pan * 0.30
        fb = q(BASS[i])
        b = math.sin(2 * math.pi * fb * t) * 0.22
        l += w * b
        r += w * b
    left.append(l)
    right.append(r)

peak = max(max(abs(x) for x in left), max(abs(x) for x in right)) or 1.0
g = 0.80 / peak
frames = bytearray()
for a, b in zip(left, right):
    frames += struct.pack('<hh', int(a * g * 32767), int(b * g * 32767))

with wave.open('vdextra-theme.wav', 'wb') as w:
    w.setnchannels(2); w.setsampwidth(2); w.setframerate(SR)
    w.writeframes(bytes(frames))

# seam check: last sample should sit close to the first, or the loop will click
print('loop seam  L: %.4f -> %.4f   R: %.4f -> %.4f' % (left[-1], left[0], right[-1], right[0]))
print('wrote vdextra-theme.wav  %.1fs' % T)
