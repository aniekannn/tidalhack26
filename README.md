# HorizonX

**Privacy-first, offline-capable AI sight partner for visually impaired users — with a civic hazard intelligence platform for governments.**

---

## The Problem

Over **2.2 billion** people globally live with vision impairments. Existing AI vision tools:
- Require constant internet connectivity
- Send raw visual data to the cloud (privacy risk)
- Fail in crowded, dynamic environments
- Are unusable offline — the environments where they're needed most

## The Solution

HorizonX is a two-part ecosystem:

### 1. HorizonX Mobile App (for visually impaired users)
A real-time AI camera companion that runs **locally-first** and works **without internet**.

| Feature | Description |
|---------|-------------|
| **Scene Narration** | "A cyclist is approaching from your left, 5 meters" |
| **Obstacle Detection** | Priority alerts with spatial audio (directional cues) |
| **Text Reading (OCR)** | Signs, menus, currency, labels — read aloud |
| **Voice Commands** | Fully voice-controlled, no visual UI dependency |
| **Hazard Reporting** | Opt-in, anonymized civic reports (potholes, blocked paths) |

### 2. HorizonX Civic Dashboard (for governments)
A centralized, anonymized hazard intelligence platform.

| Feature | Description |
|---------|-------------|
| **Live Hazard Map** | Real-time geospatial display of reported hazards |
| **Analytics Dashboard** | Severity breakdowns, trends, resolution tracking |
| **Accessibility Scores** | Per-neighborhood walkability & accessibility ratings |
| **Infrastructure Planning** | Data-driven prioritization for repairs and audits |

---

## Architecture

```
┌─────────────────────────────────┐
│    iOS DEVICE / iPhone (Offline)│
│                                 │
│  Camera → VLM (Core ML) → TTS  │
│           ↓                     │
│     Hazard Classifier           │
│     Privacy Gate (no images)    │
└────────────┬────────────────────┘
             │ (opt-in, HTTPS)
             ▼
┌─────────────────────────────────┐
│    DIGITALOCEAN BACKEND         │
│  FastAPI + PostgreSQL/PostGIS   │
│  Gemini (optional) + ElevenLabs │
└────────────┬────────────────────┘
             │
             ▼
┌─────────────────────────────────┐
│    CIVIC DASHBOARD (Web)        │
│  Leaflet Map + Analytics        │
└─────────────────────────────────┘
```

**Core principle**: The mobile app is fully functional offline. The backend enhances but never blocks.

---

## Privacy Architecture

| Data | Where it stays | Transmitted? |
|------|----------------|-------------|
| Raw camera frames | Device RAM only | **NEVER** |
| Face detection buffers | Device RAM only | **NEVER** |
| Voice recordings | Device RAM only | **NEVER** |
| Hazard type (enum) | Device + Backend | Opt-in only |
| GPS location | Fuzzed ±50m | Opt-in only |
| Timestamp | Rounded to 15min | Opt-in only |
| Device ID | Rotating weekly hash | Opt-in only |

**Zero images, zero audio, zero PII leave the device. Ever.**

---

## Tech Stack

| Component | Technology | Why |
|-----------|-----------|-----|
| Mobile App | Swift + SwiftUI | Native iOS, best ML & accessibility integration |
| On-device VLM | MobileVLM v2 (1.7B, 4-bit) | Best accuracy/size ratio, fits in 6GB RAM |
| ML Runtime | Core ML + Apple Neural Engine | Dedicated silicon, ~150ms inference on A16+ |
| OCR | Vision framework (on-device) | Native iOS, 18 languages, zero dependency |
| TTS (offline) | AVSpeechSynthesizer | Zero-latency, Siri voices, always available |
| TTS (online) | ElevenLabs Turbo v2.5 | Natural voice, <300ms latency |
| Backend | FastAPI (Python) | Async, auto-docs, hackathon-friendly |
| Database | PostgreSQL + PostGIS | Spatial queries for hazard clustering |
| Cloud AI | Google Gemini 2.0 Flash | Optional scene enhancement |
| Dashboard | HTML/JS + Leaflet | Interactive maps, no build step |
| Hosting | DigitalOcean | Simple, $17/mo total |

---

## Project Structure

```
horizonx/
├── README.md
├── docs/
│   ├── ARCHITECTURE.md          # System architecture diagrams
│   ├── TECH_STACK.md            # Technology justification
│   └── MVP_PLAN.md              # 48-hour hackathon plan
├── ios/
│   └── HorizonX/
│       ├── AI/
│       │   └── VisionPipeline.swift     # Core ML + Vision framework inference
│       ├── Camera/
│       │   └── CameraManager.swift      # AVFoundation frame capture
│       ├── Speech/
│       │   └── SpeechEngine.swift       # Dual TTS (AVSpeech + ElevenLabs)
│       ├── Hazard/
│       │   └── HazardReporter.swift     # Offline-first hazard reporting
│       └── App/
│           ├── HorizonXApp.swift        # SwiftUI app + coordinator
│           └── Info.plist               # Permissions & config
├── backend/
│   ├── requirements.txt
│   └── app/
│       ├── main.py                  # FastAPI application
│       └── api/
│           ├── health.py            # Health check
│           ├── hazards.py           # Hazard report CRUD + sync
│           ├── dashboard.py         # Civic dashboard data
│           └── ai_services.py       # Gemini + ElevenLabs proxy
├── dashboard/
│   └── index.html                   # Civic dashboard (single-page)
├── schemas/
│   └── hazard_report.py             # Shared Pydantic data models
└── prompts/
    └── vision_prompts.py            # AI prompt library
```

---

## Quick Start

### Backend API
```bash
cd backend
pip install -r requirements.txt
uvicorn app.main:app --reload --port 8000
# API docs: http://localhost:8000/docs
```

### Civic Dashboard
```bash
cd dashboard
# Open index.html in a browser (no build step needed)
python -m http.server 3000
# Dashboard: http://localhost:3000
```

### Mobile App (iOS)
```bash
# Open ios/ directory in Xcode 15+
# Build and run on iPhone 14+ (iOS 17+, 6GB+ RAM)
# Requires: Camera, Location, Microphone, Speech Recognition permissions
# For hackathon: run on physical device (Core ML needs real hardware)
```

---

## API Endpoints

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/health` | Health check |
| `POST` | `/api/v1/hazards/report` | Submit single hazard report |
| `POST` | `/api/v1/hazards/sync` | Batch sync offline reports |
| `GET` | `/api/v1/hazards/nearby` | Get hazards near location |
| `GET` | `/api/v1/dashboard/clusters` | Aggregated hazard clusters |
| `GET` | `/api/v1/dashboard/stats` | Dashboard statistics |
| `GET` | `/api/v1/dashboard/accessibility-scores` | Area accessibility ratings |
| `GET` | `/api/v1/dashboard/trends` | Time-series hazard trends |
| `POST` | `/api/v1/ai/enhance-scene` | Gemini scene enhancement |
| `POST` | `/api/v1/ai/tts` | ElevenLabs TTS generation |
| `POST` | `/api/v1/ai/classify-hazard` | AI hazard classification |

---

## Hackathon Demo Flow (2 minutes)

1. **Walk with phone** → Real-time narration of surroundings (15s)
2. **Obstacle detected** → Alert + spatial audio + hazard report queued (15s)
3. **Read a sign** → OCR extracts text, TTS reads it aloud (10s)
4. **Open dashboard** → Hazard appears on live map (15s)
5. **Show analytics** → Severity breakdown + accessibility scores (15s)
6. **Privacy story** → Zero images leave device, all data anonymized (10s)

---

## Team

Built at TidalHack 2026.

---

## License

MIT
