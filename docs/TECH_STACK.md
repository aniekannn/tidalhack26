# HorizonX — Tech Stack Justification

## Mobile App (iOS)

### Language: Swift 5.9+ / SwiftUI
- **Why**: First-class iOS support, structured concurrency (async/await), best Xcode tooling
- **Alt considered**: Flutter (rejected — native camera/ML access is clunky via plugins)
- **UI framework**: SwiftUI — minimal visual UI, voice-first, excellent accessibility support

### ML Runtime: Core ML + Apple Neural Engine (ANE)
- **Why**: Native hardware acceleration on every modern iPhone, no third-party runtime needed
- **Model**: MobileVLM v2 1.7B (4-bit palettized via `coremltools`)
- **Inference target**: <150ms per frame on iPhone 14+ (A16 Bionic ANE)
- **Advantages over TFLite**: ANE is dedicated silicon — more power-efficient, consistent latency

### Camera: AVFoundation (AVCaptureSession)
- **Why**: Full control over camera pipeline, minimal overhead
- **Preset**: `.vga640x480` — sufficient for VLM input, power-efficient
- **Frame drop strategy**: `alwaysDiscardsLateVideoFrames = true`
- **Frame budget**: 10 analyzed fps (every 3rd frame from 30fps capture)

### OCR: Vision Framework (VNRecognizeTextRequest)
- **Why**: Native on-device text recognition, 18 languages, runs on ANE
- **No extra dependency** — ships with iOS, zero download size
- **Two modes**: `.fast` for real-time (50ms), `.accurate` for "read that sign" commands

### TTS: Dual Engine
- **Primary (offline)**: `AVSpeechSynthesizer` — zero latency, works always, Siri voices available
- **Enhanced (online)**: ElevenLabs Streaming API — natural voice, calm tone
- **Voice profile**: "Aria" or custom-cloned neutral-calm voice
- **Spatial audio**: Stereo pan via `AVSpeechUtterance` for directional cues

### Local Storage: JSON file persistence (Documents directory)
- **Why**: Simple offline hazard report queue, no Core Data overhead for hackathon
- **Sync strategy**: Upload queued reports when connectivity returns via URLSession
- **Production upgrade path**: SwiftData / Core Data for full offline DB

### Navigation: MapKit (Offline Cache)
- **Why**: Native iOS maps, automatic offline tile caching, no API key needed
- **Offline tiles**: iOS caches recently viewed tiles automatically

---

## Backend

### Framework: FastAPI (Python 3.12)
- **Why**: Async-first, auto-generated OpenAPI docs, rapid development
- **Deployment**: DigitalOcean App Platform (or single $12/mo Droplet)

### Database: PostgreSQL 16 + PostGIS
- **Why**: Spatial queries (ST_DWithin, ST_ClusterDBSCAN) for hazard aggregation
- **Extension**: TimescaleDB for time-series hazard trends

### Cloud AI: Google Gemini 2.0 Flash
- **Why**: Multimodal (image+text), fast inference, generous free tier (60 RPM)
- **Use case**: Enhanced scene summaries when user is online
- **Privacy**: Only anonymized text descriptions sent, never raw images

### Cloud TTS: ElevenLabs API
- **Why**: Most natural-sounding TTS, streaming support, <300ms first-byte
- **Use case**: Premium narration quality when online

---

## Civic Dashboard

### Framework: React 18 + Vite
- **Why**: Fast dev server, component ecosystem, team familiarity

### Mapping: Leaflet + OpenStreetMap
- **Why**: Free, open-source, no API key limits for hackathon demo
- **Clustering**: Leaflet.markercluster for hazard density visualization

### Charts: Recharts
- **Why**: React-native charting, simple API, responsive

### Styling: Tailwind CSS
- **Why**: Rapid prototyping, consistent design, no CSS file management

---

## Infrastructure (DigitalOcean)

```
┌─────────────────────────────────────┐
│  DigitalOcean App Platform          │
│                                     │
│  ┌─────────────┐ ┌───────────────┐ │
│  │ FastAPI      │ │ React         │ │
│  │ Backend      │ │ Dashboard     │ │
│  │ (Web Service)│ │ (Static Site) │ │
│  └──────┬──────┘ └───────────────┘ │
│         │                           │
│  ┌──────▼──────┐                   │
│  │ PostgreSQL   │                   │
│  │ + PostGIS    │                   │
│  │ (Managed DB) │                   │
│  └─────────────┘                   │
│                                     │
│  Total cost: ~$17/mo               │
│  • App Platform: $5 (basic)        │
│  • Managed DB: $12 (1GB)           │
└─────────────────────────────────────┘
```

## Model Size & Performance Budget

| Model              | Quantization | Size    | RAM Usage | Inference  |
|--------------------|-------------|---------|-----------|------------|
| MobileVLM v2 1.7B  | FP16        | 3.4 GB  | ~4.5 GB   | ~350ms     |
| MobileVLM v2 1.7B  | 4-bit (Core ML palettized) | 850 MB | ~1.8 GB | ~150ms |
| Vision OCR          | N/A (system) | 0 MB   | ~80 MB    | ~50ms      |
| AVSpeechSynthesizer | N/A (system) | 0 MB   | ~30 MB    | ~10ms      |
| **Total on-device** |             | **~850MB** | **~1.9 GB** | **<150ms** |

Target device: iPhone 14+ (A16 Bionic, 6GB RAM) or iPhone 15 Pro (A17 Pro, 8GB RAM)
Graceful degradation: On iPhone 12/13, use smaller Florence-2 base (~450MB) or MobileNet+BLIP fallback
ANE advantage: Apple Neural Engine is dedicated silicon — no GPU contention with UI rendering
