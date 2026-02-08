# HorizonX — System Architecture

## High-Level Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                     USER'S iOS DEVICE (iPhone)                      │
│                                                                     │
│  ┌───────────┐   ┌──────────────┐   ┌──────────────┐              │
│  │  Camera    │──▶│ On-Device    │──▶│  TTS Engine  │──▶ 🔊 Audio │
│  │ (AVFound.) │   │ VLM (CoreML) │   │(AVSpeechSyn.)│              │
│  └───────────┘   └──────┬───────┘   └──────────────┘              │
│                          │                                          │
│  ┌───────────┐   ┌──────▼───────┐   ┌──────────────┐              │
│  │  Voice     │──▶│  Scene       │──▶│  Hazard      │              │
│  │(SFSpeech)  │   │  Reasoner    │   │  Classifier  │              │
│  └───────────┘   └──────────────┘   └──────┬───────┘              │
│                                             │ (opt-in, anonymized)  │
│  ┌──────────────────────────────────────────▼───────┐              │
│  │              Privacy Gate                         │              │
│  │  • Strip all PII    • No raw images              │              │
│  │  • Hash location    • Structured text only       │              │
│  └──────────────────────────────────┬───────────────┘              │
└─────────────────────────────────────┼───────────────────────────────┘
                                      │ HTTPS (when online)
                                      ▼
┌─────────────────────────────────────────────────────────────────────┐
│                     DIGITALOCEAN BACKEND                            │
│                                                                     │
│  ┌──────────────┐   ┌──────────────┐   ┌───────────────────┐      │
│  │  FastAPI      │   │  Hazard      │   │  Gemini API       │      │
│  │  Gateway      │──▶│  Aggregator  │   │  (Cloud Enhance)  │      │
│  └──────┬───────┘   └──────┬───────┘   └───────────────────┘      │
│         │                   │                                       │
│  ┌──────▼───────┐   ┌──────▼───────┐                               │
│  │  PostgreSQL   │   │  PostGIS     │                               │
│  │  + TimescaleDB│   │  Geo Index   │                               │
│  └──────────────┘   └──────┬───────┘                               │
│                             │                                       │
└─────────────────────────────┼───────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│                     CIVIC DASHBOARD (Web)                           │
│                                                                     │
│  ┌──────────────┐   ┌──────────────┐   ┌──────────────┐           │
│  │  Live Hazard  │   │  Analytics   │   │  Accessibility│           │
│  │  Map (Leaflet)│   │  Charts      │   │  Audit View  │           │
│  └──────────────┘   └──────────────┘   └──────────────┘           │
└─────────────────────────────────────────────────────────────────────┘
```

## Mobile Inference Flow

```
Camera Frame (30fps)
       │
       ▼
┌─────────────────┐
│ Frame Sampler    │  ← Sample every 3rd frame (10fps effective)
│ + Downscaler    │  ← Resize to 384×384
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ MobileVLM v2    │  ← 4-bit quantized, ~1.7B params
│ (Core ML)       │  ← Runs on Apple Neural Engine (ANE)
│                  │  ← KV cache: sliding window (512 tokens)
└────────┬────────┘
         │
         ├──▶ Scene Description (text)
         ├──▶ Obstacle Alert (structured JSON)
         └──▶ Text/OCR Content (extracted strings)
                │
                ▼
┌─────────────────┐
│ Priority Router  │  ← Obstacles > Navigation > OCR > Ambient
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ TTS Engine       │  ← AVSpeechSynthesizer (offline)
│                  │  ← ElevenLabs streaming (online, opt-in)
└────────┬────────┘
         │
         ▼
      🔊 Spatial Audio Output (bone conduction / earbuds)
```

## Offline vs Online Logic Split

| Feature                  | Offline (Default)           | Online (Enhanced)              |
|--------------------------|-----------------------------|---------------------------------|
| Scene narration          | On-device VLM (Core ML)    | VLM + Gemini refinement        |
| Obstacle detection       | On-device VLM (Core ML)    | Same (latency-critical)        |
| OCR / text reading       | Vision framework (on-device)| Same + translation via cloud  |
| TTS voice                | AVSpeechSynthesizer        | ElevenLabs streaming           |
| Hazard reporting         | Queued locally (JSON file) | Synced to backend              |
| Navigation               | Cached map + dead reckoning| Full routing + live transit     |

**Core principle**: The app is fully functional offline. Network enhances but never blocks.

## Privacy Architecture

```
┌─────────────────────────────────────┐
│         ON-DEVICE ONLY              │
│                                     │
│  • Raw camera frames                │
│  • Face detection buffers           │
│  • Voice recordings (STT input)     │
│  • Biometric sensor data            │
│                                     │
│  NEVER leaves device. Purged from   │
│  RAM after processing. No disk.     │
└─────────────────────────────────────┘

┌─────────────────────────────────────┐
│       TRANSMITTED (opt-in only)     │
│                                     │
│  • Hazard type (enum)               │
│  • Coarse GPS (±50m fuzzing)        │
│  • Structured text description      │
│  • Timestamp (rounded to 15 min)    │
│  • Anonymous device hash (rotating) │
│                                     │
│  NO images, NO audio, NO PII       │
└─────────────────────────────────────┘
```

## Key Technology Decisions

| Component          | Choice                | Rationale                                          |
|--------------------|-----------------------|----------------------------------------------------|
| On-device VLM      | MobileVLM v2 (1.7B)  | Best accuracy/size ratio; fits in 4GB RAM          |
| Quantization       | Core ML palettized 4-bit | Native ANE support, optimized by coremltools    |
| Runtime            | Core ML (Neural Engine) | Apple-native, best perf on iPhone 14+            |
| OCR                | Vision framework       | Native, 18 languages, runs on ANE                 |
| Cloud VLM          | Google Gemini 2.0     | Multimodal reasoning, generous free tier           |
| TTS (online)       | ElevenLabs Turbo v2.5 | <300ms latency, natural prosody                    |
| TTS (offline)      | AVSpeechSynthesizer    | Zero-latency fallback, all languages               |
| Backend            | FastAPI + PostgreSQL   | Async, lightweight, hackathon-friendly             |
| Geo indexing       | PostGIS                | Spatial queries for hazard clustering              |
| Hosting            | DigitalOcean App Plat  | Simple deploy, $5/mo droplet sufficient            |
| Dashboard          | HTML/JS + Leaflet      | Interactive maps, rapid prototyping                |
| Maps (offline)     | MapKit (offline cache)  | Native iOS, pre-cached tiles for navigation       |
