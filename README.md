Develop Sigma SD9 / SD10 / SD14 Foveon X3F raws into DNG/TIFF -> JPEG/HEIC +

- physically modeled, graphically accelerated film sims
- auto exposure/wb/etc. methods
- primitive HDR
- ml-assisted debayering & denoising for 3rd party raw files
- ml framework for assisted editing

## iOS app

<img width="300" alt="IMG_0802" src="https://github.com/user-attachments/assets/5029eee9-fbc0-44ce-a1cb-7c76f11bd43c" />
<img width="300" alt="IMG_0801" src="https://github.com/user-attachments/assets/c1b14716-50a3-41cf-bcae-8c1389d001d6" />
<img width="300" alt="IMG_0805" src="https://github.com/user-attachments/assets/9b062456-7899-44a5-812e-8e5e66115043" />
<img width="900" alt="IMG_0773" src="https://github.com/user-attachments/assets/08965b11-17a6-4369-a97d-3060423ca87d" />

## film simulation

<img width="300" alt="IMG_0754" src="https://github.com/user-attachments/assets/8c76bede-172c-466f-abaf-2ede536a661f" />
<img width="300" alt="IMG_0807" src="https://github.com/user-attachments/assets/0f434b44-e7b1-4c38-b339-cab5a42afb4b" />
<img width="300" alt="IMG_0808" src="https://github.com/user-attachments/assets/c867436c-4cd9-42b2-9b3d-95b138a1a655" />
<img width="300" alt="IMG_0809" src="https://github.com/user-attachments/assets/7f831a87-1984-4e0c-8047-266ba6a90f45" />

## foveon profiled denoising

<img width="300" alt="IMG_0758 2" src="https://github.com/user-attachments/assets/59949d36-eba8-4f49-ab30-7a5e687d0c2a" />
<img width="300" alt="IMG_0759 2" src="https://github.com/user-attachments/assets/f4b41809-25a1-4e0e-8a9a-65438c3200cf" />

## 3rd party raw editing

<img width="150" alt="IMG_0772" src="https://github.com/user-attachments/assets/2a2dccc1-be71-4bbd-903b-ab035b142882" />

Various industry raw files are also supported, through apple's raw library, & using Raw9 on iOS/macOS 27 w/ ML assisted denoising & debayering. This is however beta software & a lower priority than the foveon path, & may be buggy! Not that the foveon path is bug-free...

```sh
./build_libs.sh
./develop/build_metallib.sh
./build_ios_libs.sh
```

```sh
./develop/.build/release/foveon <input> [options]
./develop/.build/release/foveon testx3f/ -o out --tiff --heic
```


Or open `app/` in Xcode & run it — the one target builds natively for
iPhone, iPad, and macOS (no Catalyst).

```sh
./export_app.sh                 # ad-hoc .ipa + native .app -> build/export
./export_app.sh --ios           # just the .ipa
./export_app.sh --mac           # just the .app
./export_app.sh --method developer-id   # notarizable standalone build

# Ship to TestFlight
ASC_KEY_ID=XXXXXXXXXX \
ASC_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx \
ASC_KEY_PATH=~/keys/AuthKey_XXXXXXXXXX.p8 \
./export_app.sh --upload
```

```
usage: foveon <input> [options]
  <input>          an .x3f / RAW / DNG / TIFF / image file, or a folder
  -o, --out DIR    output dir
  --dng  --tiff    decoded intermediate(s)
  --jpeg --heic    rendered image(s)  (default: --jpeg)
  -q, --quality Q  output quality 0…1 (default: 0.92)
  --wb NAME        white-balance override (default: as-shot)
  --exposure EV    exposure compensation (default: 0)
  --no-auto-tone   disable auto exposure
  --tone-key K     auto-tone target (default: 0.07)
  --contrast C     contrast #
  --sharpness S    sharpening # (default: 0.5)
  --sdr            skip HDR gain map
  --hdr-stops S    HDR highlight headroom (stops, default: 2.3)
  --film NAME      spectral film simulation with stock NAME (name/index; --film list)
  --paper NAME     RA4 print paper (default: Portra Endura)
  --film-negative  output the scanned negative/slide instead of an RA4 print
  --ev-film EV     film exposure (default: 0)
  --ev-paper EV    print exposure (default: auto neutral balance)
  --couplers AMT   DIR coupler amount, colourfulness (default: 0.25, 0 disables)
  --coupler-radius R  DIR coupler spatial diffusion, fraction of long edge (default: 0.0015)
  --halation       reddish halation glow bleeding out of the highlights
  --halation-strength S  halation glow scale (default: 0.35)
  --halation-radius R  halation radius, fraction of long edge (default: 0.0015)
  --halation-midtones M  halation highlight protection 0…1 (default: 0)
  --no-grain       disable film grain
  --grain-size S   grain size scale (default: 1)
  --denoise [MODE] denoise: wavelet (profiled à-trous, no model, default) | neural (Core ML)
  --denoise-strength S  strength: wavelet threshold scale / neural blend 0…1 (default: 1)
  --denoise-chroma C  wavelet chroma shrink multiplier (default: 2)
  --denoise-model P  neural model .mlmodelc/.mlpackage; repeat to cascade (default: auto)
  --denoise-time T  neural JiT signal level t, 0…1 (default: 0.85)
  --denoise-ensemble  neural 8-way self-ensemble (higher quality, 8× slower)
  -j, --jobs N     concurrent images (default: cores)
```

physically based metal spectral film simulation, derived from vkdt, itself derived from agx & spektrafilm

```sh
foveon photo.x3f --film "portra 400"                       # print on the matched paper
foveon photo.x3f --film ektar_100 --paper "crystal archive"
foveon photo.x3f --film velvia_100                         # slide → scanned positive
foveon photo.x3f --film gold_200 --couplers 1.5 --grain-size 1.5
foveon photo.x3f --film portra_400 --halation --coupler-radius 0.02
foveon --film list                                         # list stocks
```

baked data tables are generated from spektrafilm

```sh
pip install numpy scipy
python scripts/filmsim_bake.py           # writes the .lut resources + FilmStocks.generated.swift
python scripts/filmsim_verify.py         # CPU cross-check of the pipeline + balance
```

Profiled wavelet denoise

```sh
foveon photo.x3f --denoise                              # wavelet, profiled
foveon photo.x3f --denoise --denoise-strength 1.5 --denoise-chroma 3
python scripts/noise_profile.py                         # re-measure the profile from dataset/
                                                        # → NoiseProfiles.generated.swift
```

Train the in-repo JiT denoiser #TODO

Li & He, *Back to Basics: Let Denoising Generative
Models Denoise* (arXiv:2511.13720).

```sh
pip install torch numpy pillow imageio coremltools
# Recommended: real noisy/clean X3F pairs
python scripts/jit_denoiser.py train \
  --data /path/to/foveon-denoise-pairs \
  --mode paired --variant small --size 512 --patch 32 \
  --data-range unit --out checkpoints/FoveonJiT.pt
python scripts/jit_denoiser.py export \
  --checkpoint checkpoints/FoveonJiT.pt \
  --out FoveonJiT.mlpackage --domain linear
```

```sh
./scripts/trainjit.sh                                   # DATA=./dataset by default
```

can also train on paired captures, I wouldn't recommend it though

```sh
python scripts/jit_denoiser.py train \
  --data /path/to/clean-photos --mode clean \
  --noise-model shot --chroma-noise 2 --out checkpoints/FoveonJiT.pt
python scripts/jit_denoiser.py export --checkpoint checkpoints/FoveonJiT.pt \
  --out FoveonJiT.mlpackage --domain srgb
```

Dataset layout for paired training

```text
foveon-denoise-pairs/
  noisy/scene-001/SDIM0170.X3F   # high-ISO / short-exposure frames
  noisy/scene-001/SDIM0171.X3F
  clean/scene-001/SDIM0169.X3F   # one low-ISO reference per scene
  noisy/scene-002/...
  clean/scene-002/...
```


The more photos, the better, the more subjects & variation, the better, use a tripod!

```sh
foveon photo.x3f
foveon shoot/ -o out --tiff --jpeg
foveon photo.x3f -o out --dng

./develop/.build/release/foveon testx3f/SDIM0142.X3F -o out --tiff --heic --no-auto-tone --denoise neural --denoise-model FoveonJiT.mlpackage --denoise-strength 0.82 --denoise-time 0.85
```

```sh
sd14raw <in.x3f> [out.dng | out.tif] [--wb NAME]
```

```swift
import SigmaFoveon

let dev = FoveonDeveloper()
let jpeg = try dev.render(x3f: data, to: .jpeg)
await dev.process(jobs)
```# bench2

## Credits

- [vkdt](https://jo.dreggn.org/vkdt/readme.html) + [spektrafilm](https://github.com/andreavolpato/spektrafilm) for film simulations
- [this blog too](https://yedlin.net/NerdyFilmTechStuff/DispPrepDemoFAQ/)
- [Kalpanika/x3f](https://github.com/Kalpanika/x3f) for foveon parsing
- [ART](https://artraweditor.github.io) for insight into certain algorithims in practice
- [libvips](https://www.libvips.org) for general reference
- Nafnet/NIND-denoise/restormer/various papers for restorative imaging w/ ml (denoising, deblurring, supersampling)
