import numpy as np
from scipy.io import wavfile
from scipy.signal import butter, lfilter
SR=44100
class Mix:
    def __init__(s,dur,seed=7): s.N=int(SR*dur); s.L=np.zeros(s.N); s.R=np.zeros(s.N); s.rng=np.random.default_rng(seed)
    def add(s,sig,t,gain=1.0,pan=0.0):
        i=int(t*SR)
        if i>=s.N: return
        j=min(s.N,i+len(sig)); x=sig[:j-i]*gain
        s.L[i:j]+=x*(1-max(0,pan)); s.R[i:j]+=x*(1+min(0,pan))
    def save(s,fn,fade_from=None):
        if fade_from:
            f=np.ones(s.N); a=int(fade_from*SR); f[a:]=np.linspace(1,0,s.N-a); s.L*=f; s.R*=f
        st=np.tanh(np.stack([s.L,s.R],1)*1.2); st/=np.max(np.abs(st))*1.12
        wavfile.write(fn,SR,(st*32767).astype(np.int16))
def env(n,a=0.005,d=0.2):
    t=np.arange(n)/SR; return np.minimum(1,t/a)*np.exp(-t/d)
def lp(x,fc): b,a=butter(2,fc/(SR/2)); return lfilter(b,a,x)
def hp(x,fc): b,a=butter(2,fc/(SR/2),'high'); return lfilter(b,a,x)
rng=np.random.default_rng(3)
def noise(n): return rng.standard_normal(n)
def kick(big=False,soft=False):
    n=int(SR*(0.6 if big else 0.35)); t=np.arange(n)/SR
    f=45+(160 if big else 110)*np.exp(-t*28); s=np.sin(2*np.pi*np.cumsum(f)/SR)*env(n,0.001,0.25 if big else 0.14)
    return lp(s,400)*0.8 if soft else s*(1.4 if big else 1)
def hat(op=False,g=0.35):
    n=int(SR*(0.18 if op else 0.05)); return hp(noise(n),7000)*env(n,0.001,0.06 if op else 0.015)*g
def snare(g=1.0):
    n=int(SR*0.2); t=np.arange(n)/SR; b,a=butter(2,[1500/(SR/2),6000/(SR/2)],'band')
    return (lfilter(b,a,noise(n))*0.7+np.sin(2*np.pi*190*t)*0.5)*env(n,0.001,0.07)*g
def clap():
    n=int(SR*0.25); x=np.zeros(n)
    for o in (0,0.012,0.024): i=int(o*SR); m=n-i; x[i:]+=hp(noise(m),1200)*env(m,0.001,0.05)
    return x*0.5
def tone(freq,dur,wave='saw',a=0.01,d=None,gain=0.2):
    n=int(SR*dur); t=np.arange(n)/SR
    if wave=='saw': s=2*((t*freq)%1)-1
    elif wave=='sq': s=np.sign(np.sin(2*np.pi*freq*t))
    elif wave=='tri': s=2*np.abs(2*((t*freq)%1)-1)-1
    else: s=np.sin(2*np.pi*freq*t)
    e=np.minimum(1,t/a)*(np.exp(-t/d) if d else np.minimum(1,np.maximum(0,(dur-t)/0.05)))
    return s*e*gain
def chord(notes,dur,gain=0.06,fc=2500,wave='saw'):
    return lp(sum(tone(f,dur,wave,a=0.05,gain=gain)+tone(f*1.006,dur,wave,a=0.05,gain=gain) for f in notes),fc)
def epiano(notes,dur,gain=0.12):
    return sum(tone(f,dur,'sine',a=0.005,d=0.9,gain=gain)+tone(f*2,dur,'sine',a=0.005,d=0.3,gain=gain*0.3) for f in notes)
def whoosh(dur=0.5,up=True,g=0.3):
    n=int(SR*dur); x=noise(n); y=np.zeros(n); seg=SR//40
    for i in range(0,n,seg):
        k=i/n; fc=(400+k*7000) if up else (7400-k*7000); y[i:i+seg]=lp(x[i:i+seg],max(200,fc))
    t=np.arange(n)/SR; e=np.sin(np.pi*t/dur)**2; return y*e*g
def riser(dur,g=0.3):
    n=int(SR*dur); t=np.arange(n)/SR; x=noise(n); y=np.zeros(n); seg=SR//20
    for i in range(0,n,seg): y[i:i+seg]=lp(x[i:i+seg],500+(i/n)**2*9000)
    return y*(t/dur)**2*g
def crash(g=0.3): n=int(SR*1.6); return hp(noise(n),4000)*env(n,0.001,0.5)*g
def click(g=0.25): n=int(SR*0.03); return hp(noise(n),2500)*env(n,0.0005,0.006)*g
def ding(f=1568,g=0.3): return tone(f,0.8,'sine',a=0.002,d=0.25,gain=g)+tone(f*2.01,0.8,'sine',a=0.002,d=0.12,gain=g*0.4)
def pop(f=880,g=0.25):
    n=int(SR*0.08); t=np.arange(n)/SR; fr=f*(1+2*np.exp(-t*60)); return np.sin(2*np.pi*np.cumsum(fr)/SR)*env(n,0.001,0.03)*g
N=lambda name:{'A2':110,'C3':130.81,'D3':146.83,'E3':164.81,'F3':174.61,'G3':196,'A3':220,'B3':246.94,'C4':261.63,'D4':293.66,'E4':329.63,'F4':349.23,'G4':392,'A4':440,'B4':493.88,'C5':523.25,'D5':587.33,'E5':659.26}[name]
