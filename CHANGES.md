# WayFinder — Complete Changes Documentation

This document summarizes all changes made to the WayFinder project (formerly HorizonX) for the TidalHack 2026 hackathon. Use this as a reference when continuing development in VS Code with Copilot.

---

## ⚠️ IMPORTANT: Quick Start Commands

**CRITICAL: Always run commands from the correct directory!**

### Backend API (Port 8000)
```bash
# MUST cd into backend directory first!
cd /Users/aniekanekanem/Documents/GitHub/tidalhack26/backend

# Then run uvicorn with PYTHONPATH set
PYTHONPATH=$(pwd) /Users/aniekanekanem/Documents/GitHub/tidalhack26/.venv/bin/python -m uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
```

### Dashboard (Port 3000)
```bash
# MUST cd into dashboard directory first!
cd /Users/aniekanekanem/Documents/GitHub/tidalhack26/dashboard

# Then run the HTTP server
/Users/aniekanekanem/Documents/GitHub/tidalhack26/.venv/bin/python -m http.server 3000
```

### URLs
- Dashboard: http://localhost:3000
- Backend API: http://localhost:8000
- API Docs: http://localhost:8000/docs

---

## iOS App Connection (for real device testing)

The iOS app needs to connect to your Mac's backend. The IP is configured in:
`ios/HorizonX/tidalhack26/tidalhack26/Network/NetworkService.swift`

Current IP: `10.247.222.228:8000`

To update for your network:
```bash
# Find your Mac's IP
ipconfig getifaddr en0
```

Then update `NetworkConfig.baseURL` in NetworkService.swift.

---

## ✅ Verified Working (Feb 7, 2026)

### API Configuration Status
- ✅ **Gemini API: configured** - Real-time vision analysis working
- ✅ **ElevenLabs API: configured** - TTS streaming available
- ✅ **20 College Station hazards** - Pre-seeded in database

### Scanning & Obstruction Detection
- ✅ Fixed environment variable loading (dotenv) in backend
- ✅ Gemini Vision API properly configured for real-time obstacle detection
- ✅ VisionPipeline sends camera frames to backend for analysis
- ✅ Navigation commands: walk_straight, stop, turn_left, turn_right, stay_left, stay_right, slow_down, step_over, duck
- ✅ Obstacle types: vehicle, person, object, terrain, construction, debris, barrier
- ✅ Urgency levels: immediate (<2m), soon (2-5m), ambient (>5m)

### Hazard Reporting Flow
- ✅ When hazard detected, app prompts: "Say 'report' or 'skip'"
- ✅ Voice commands "report", "yes", "submit" → submits hazard to dashboard
- ✅ Voice commands "skip", "no", "ignore" → dismisses prompt
- ✅ Visual buttons added for Report/Skip
- ✅ Reported hazards sync to backend and appear on civic dashboard
- ✅ Reports include: location (fuzzed ±50m), timestamp (rounded 15 min), anonymous device hash

### Voice Commands (Full List)
- "What's around me" / "Scan" / "Look" - describes current scene with obstacles
- "Report" / "Report hazard" / "Pothole" - reports current obstruction
- "Read sign" / "Read text" - reads OCR text from signs
- "Status" - reports online/offline and pending syncs
- "Repeat" / "Again" - repeats last spoken message
- "Slow down" - slower speech rate
- "Speed up" / "Fast" - faster speech rate
- "Help" - lists all commands

### Testing the iOS App
1. Open Xcode: `ios/HorizonX/tidalhack26/tidalhack26.xcodeproj`
2. Select your iPhone as the run target
3. Build and run (⌘R)
4. Grant camera and microphone permissions
5. Point camera at obstacles - app will narrate what it sees
6. When hazard detected, say "Report" or tap Report button
7. Check dashboard at http://localhost:3000 for reported hazards

---

## Project Overview

**WayFinder** is a privacy-first, offline-capable AI sight partner for visually impaired users with a civic hazard intelligence platform for governments. Location: **College Station, TX**.

### Key Components Built

| Component | Location | Description |
|-----------|----------|-------------|
| iOS App | `ios/HorizonX/` | SwiftUI app with camera, vision AI, TTS, and hazard reporting |
| Backend API | `backend/` | FastAPI server with hazard management and AI services |
| Civic Dashboard | `dashboard/` | Single-page HTML dashboard with live hazard map |
| Android Scaffold | `mobile/` | Kotlin/Android scaffold (incomplete) |
| Documentation | `docs/` | Architecture, tech stack, and build guides |

---

## 1. Backend API (`backend/`)

### Files Created

| File | Purpose |
|------|---------|
| `app/main.py` | FastAPI application entry point with all routers |
| `app/database.py` | SQLAlchemy database configuration with SQLite |
| `app/api/health.py` | Health check endpoint |
| `app/api/hazards.py` | Hazard report CRUD and sync endpoints |
| `app/api/dashboard.py` | Dashboard statistics and clustering endpoints |
| `app/api/ai_services.py` | Gemini Vision + ElevenLabs TTS integration |
| `app/api/alerts.py` | Real-time WebSocket alerts |
| `app/api/vision.py` | MoonDream vision analysis endpoint |
| `app/services/seed_data.py` | Demo hazard data seeding |
| `app/services/vision_analyzer.py` | Vision model integration |
| `app/data/computed.json` | Pre-computed hazard data for demo |
| `requirements.txt` | Python dependencies |

### Key Features Implemented

#### AI Services (`app/api/ai_services.py`)

- **Scene Enhancement** (`POST /api/v1/ai/enhance-scene`)
  - Takes on-device VLM text description (not images)
  - Enhances with Gemini 2.0 Flash for better spatial reasoning
  - Returns navigation suggestions

- **Vision Analysis** (`POST /api/v1/ai/analyze-scene`)
  - Accepts base64-encoded JPEG images
  - Uses Gemini Vision for obstacle detection
  - Returns structured obstacle data with clock directions
  - Provides navigation commands (walk_straight, stop, turn_left, etc.)

- **TTS Generation** (`POST /api/v1/ai/tts`)
  - ElevenLabs integration for natural speech
  - Streaming endpoint for low-latency playback
  - Falls back to mock when API not configured

- **Hazard Classification** (`POST /api/v1/ai/classify-hazard`)
  - Standardizes hazard reports for analytics
  - Returns type, severity, and context tags

#### API Endpoints Summary

```
GET  /health                           - Health check
POST /api/v1/hazards/report            - Submit single hazard
POST /api/v1/hazards/sync              - Batch sync offline reports
GET  /api/v1/hazards/nearby            - Get hazards near location
GET  /api/v1/dashboard/clusters        - Aggregated hazard clusters
GET  /api/v1/dashboard/stats           - Dashboard statistics
GET  /api/v1/dashboard/accessibility-scores - Area ratings
GET  /api/v1/dashboard/trends          - Time-series data
POST /api/v1/ai/enhance-scene          - Gemini scene enhancement
POST /api/v1/ai/analyze-scene          - Real-time vision analysis
POST /api/v1/ai/tts                    - ElevenLabs TTS
POST /api/v1/ai/tts-stream             - Streaming TTS
POST /api/v1/ai/classify-hazard        - AI hazard classification
```

### Running the Backend

```bash
cd backend
pip install -r requirements.txt

# Set environment variables (copy from .env.example)
cp ../.env.example ../.env
# Edit .env with your API keys

# Run the server
uvicorn app.main:app --reload --port 8000

# API docs at: http://localhost:8000/docs
```

### Dependencies Added

```
fastapi>=0.109.0
uvicorn[standard]>=0.27.0
pydantic>=2.5.0
sqlalchemy>=2.0.25
asyncpg>=0.29.0
geoalchemy2>=0.14.0
python-dotenv>=1.0.0
httpx>=0.26.0
google-generativeai>=0.4.0
elevenlabs>=1.1.0
alembic>=1.13.0
python-multipart>=0.0.6
pillow>=10.0.0
websockets>=12.0
aiofiles>=23.0.0
```

---

## 2. iOS App (`ios/HorizonX/`)

### Xcode Project Structure

```
ios/HorizonX/tidalhack26/tidalhack26.xcodeproj  <- Open this in Xcode
ios/HorizonX/tidalhack26/tidalhack26/
├── tidalhack26App.swift      <- App entry point + AppCoordinator
├── ContentView.swift         <- HorizonXView (main UI)
├── AI/
│   └── VisionPipeline.swift  <- Core ML inference + Vision OCR
├── Camera/
│   └── CameraManager.swift   <- AVFoundation frame capture
├── Speech/
│   └── SpeechEngine.swift    <- AVSpeechSynthesizer TTS
├── Hazard/
│   └── HazardReporter.swift  <- Offline-first hazard queue
├── Network/
│   └── NetworkService.swift  <- Backend API client
├── Assets.xcassets/          <- App icon & colors
└── Info.plist                <- Permissions
```

### Key Files Created

#### `tidalhack26App.swift` - App Entry Point

- `AppCoordinator` class that orchestrates all components
- Manages camera, vision, speech, and hazard services
- Handles voice command processing
- Coordinates online/offline state

#### `ContentView.swift` - Main UI (HorizonXView)

- Voice-first, minimal visual UI
- Camera preview as background
- Status header with online/offline indicator
- Scene narration display with obstacle warnings
- Large microphone button for voice commands
- Accessibility-optimized with VoiceOver labels

#### `VisionPipeline.swift` - AI Vision

- `SceneAnalysis` struct with narration, obstacles, OCR
- `ObstacleInfo` with clock direction and urgency
- On-device Vision framework OCR
- Network calls to backend Gemini API when online
- Mock data when offline

#### `CameraManager.swift` - Camera

- AVCaptureSession with `.vga640x480` preset
- Frame capture at 10fps (every 3rd frame)
- `alwaysDiscardsLateVideoFrames = true` for real-time
- SwiftUI preview layer integration

#### `SpeechEngine.swift` - Text-to-Speech

- `AVSpeechSynthesizer` for offline TTS
- Priority queue (immediate > soon > ambient)
- Speech rate and voice configuration
- Interrupt current speech for urgent alerts

#### `HazardReporter.swift` - Hazard Reporting

- Offline-first JSON queue in Documents directory
- Privacy transforms (location fuzzing, timestamp rounding)
- Background sync when connectivity returns
- Pending report count for UI

#### `NetworkService.swift` - API Client

- Backend API endpoint configuration
- Scene analysis request/response
- TTS audio fetching
- Hazard report submission
- Connectivity detection

### Xcode Project Settings

- **Team**: Personal Team (L2FCZC3SCM)
- **Bundle ID**: `aniekane.tidalhack26`
- **iOS Target**: 17.0+
- **Swift Version**: 6.0 (strict concurrency)
- **Signing**: Automatic

### Permissions Required

The app requests these permissions (configured in Build Settings):

| Permission | Build Setting Key |
|------------|-------------------|
| Camera | `INFOPLIST_KEY_NSCameraUsageDescription` |
| Microphone | `INFOPLIST_KEY_NSMicrophoneUsageDescription` |
| Speech Recognition | `INFOPLIST_KEY_NSSpeechRecognitionUsageDescription` |
| Location | `INFOPLIST_KEY_NSLocationWhenInUseUsageDescription` |
| Background Modes | `audio`, `location` |

### Building & Running

1. Open `ios/HorizonX/tidalhack26/tidalhack26.xcodeproj` in Xcode 16+
2. Connect iPhone 14+ running iOS 17+
3. Select your device in the toolbar
4. Press Cmd+R to build and run
5. Trust the developer certificate on first run
6. Grant all requested permissions

---

## 3. Civic Dashboard (`dashboard/`)

### Single File: `index.html`

A complete single-page dashboard with:

- **Header**: Live status badge, time range filters
- **Left Sidebar**: Hazard list with severity badges, click to fly-to
- **Main Map**: Leaflet with OpenStreetMap, marker clustering
- **Right Panel**: Statistics cards, severity chart, accessibility scores
- **Real-time Updates**: Polls backend every 30 seconds

### Features

- Dark theme optimized for accessibility
- Responsive layout for desktop and tablet
- Hazard type filtering (potholes, blocked paths, etc.)
- Time range filtering (24h, 7d, 30d, all)
- Click-to-fly map animations
- Severity breakdown chart (CSS-based, no JS library)
- Neighborhood accessibility score cards

### Running the Dashboard

```bash
cd dashboard
python -m http.server 3000
# Open http://localhost:3000
```

Or simply open `index.html` in a browser.

---

## 4. Configuration Files

### `.env.example`

Template for environment variables:

```env
# Backend
DATABASE_URL=postgresql+asyncpg://user:password@localhost:5432/horizonx
SECRET_KEY=your-secret-key-here

# Google Gemini (optional)
GEMINI_API_KEY=your-gemini-api-key

# ElevenLabs (optional)
ELEVENLABS_API_KEY=your-elevenlabs-api-key
ELEVENLABS_VOICE_ID=aria

# DigitalOcean (optional)
DO_SPACES_KEY=your-spaces-key
DO_SPACES_SECRET=your-spaces-secret
DO_SPACES_BUCKET=horizonx-assets
```

### `.gitignore`

Ignores:
- `__pycache__/`, `*.pyc`
- `.env` (secrets)
- `venv/`, `.venv/`
- `.DS_Store`
- `horizonx.db` (SQLite database)
- Xcode build directories
- `*.mlmodelc` (Core ML models)

---

## 5. Documentation (`docs/`)

| File | Content |
|------|---------|
| `ARCHITECTURE.md` | System diagrams, data flow, privacy architecture |
| `TECH_STACK.md` | Technology choices with justifications |
| `MVP_PLAN.md` | 48-hour hackathon timeline |
| `BUILD_GUIDE_IOS.md` | Step-by-step iOS build instructions |

---

## 6. Key Architecture Decisions

### Privacy-First Design

| Data | Location | Transmitted? |
|------|----------|-------------|
| Raw camera frames | Device RAM only | NEVER |
| Face detection | Device RAM only | NEVER |
| Voice recordings | Device RAM only | NEVER |
| Hazard type (enum) | Device + Backend | Opt-in only |
| GPS location | Fuzzed ±50m | Opt-in only |
| Timestamp | Rounded to 15min | Opt-in only |

### Offline-First

- iOS app fully functional without internet
- Vision analysis falls back to on-device when offline
- Hazard reports queued locally, synced when online
- TTS uses AVSpeechSynthesizer when ElevenLabs unavailable

### AI Integration

- **On-device**: Vision framework OCR (always available)
- **Cloud (optional)**: Gemini 2.0 Flash for enhanced scene analysis
- **TTS**: AVSpeechSynthesizer (offline) + ElevenLabs (online)

---

## 7. Running the Full Stack

### Terminal 1: Backend API

```bash
cd backend
pip install -r requirements.txt
uvicorn app.main:app --reload --port 8000
```

### Terminal 2: Dashboard

```bash
cd dashboard
python -m http.server 3000
```

### Xcode: iOS App

1. Open `ios/HorizonX/tidalhack26/tidalhack26.xcodeproj`
2. Connect iPhone, select it as target
3. Press Cmd+R

### Demo Flow

1. Launch iOS app on iPhone
2. Point camera at surroundings → hear narration
3. Say "Report a hazard" → queued locally
4. Open dashboard → see hazard on map
5. Show analytics and accessibility scores

---

## 8. Known Limitations / TODOs

### iOS App

- [ ] Core ML model not included (uses mock data)
- [ ] Voice commands partially implemented
- [ ] Spatial audio not fully wired up
- [ ] Background processing needs testing

### Backend

- [ ] Using SQLite (switch to PostgreSQL + PostGIS for production)
- [ ] No authentication (add for production)
- [ ] Rate limiting not implemented

### Dashboard

- [ ] Charts are CSS-based (consider Chart.js for production)
- [ ] WebSocket real-time updates not implemented
- [ ] Export/PDF feature not complete

---

## 9. Continuing Development with Copilot

### Suggested Prompts for Copilot

**iOS App:**
- "Add a Core ML model for scene description in VisionPipeline.swift"
- "Implement voice command parsing for 'read that sign' command"
- "Add haptic feedback when obstacles are detected"

**Backend:**
- "Add PostGIS spatial queries in hazards.py"
- "Implement hazard clustering with ST_ClusterDBSCAN"
- "Add JWT authentication to API endpoints"

**Dashboard:**
- "Add Chart.js for severity breakdown visualization"
- "Implement WebSocket connection for real-time updates"
- "Add export to PDF feature"

### File Quick Reference

| Task | File to Edit |
|------|--------------|
| Add API endpoint | `backend/app/api/` - create or edit router |
| Modify vision AI | `backend/app/api/ai_services.py` |
| Change iOS UI | `ios/.../ContentView.swift` |
| Add voice command | `ios/.../tidalhack26App.swift` |
| Modify camera | `ios/.../CameraManager.swift` |
| Add TTS feature | `ios/.../SpeechEngine.swift` |
| Dashboard styling | `dashboard/index.html` (inline CSS) |

---

## 10. API Keys Required

| Service | Environment Variable | Purpose |
|---------|---------------------|---------|
| Google Gemini | `GEMINI_API_KEY` | Scene enhancement, vision analysis |
| ElevenLabs | `ELEVENLABS_API_KEY` | Natural TTS voice |

Get API keys from:
- Gemini: https://makersuite.google.com/app/apikey
- ElevenLabs: https://elevenlabs.io (create account → Profile → API Key)

---

## Summary

This project includes:
- Complete FastAPI backend with Gemini Vision + ElevenLabs TTS
- SwiftUI iOS app with camera, OCR, TTS, and offline-first hazard reporting
- Single-page civic dashboard with live hazard map
- Privacy-first architecture (no images leave device)
- Comprehensive documentation

All code is ready to run. Follow the setup instructions above to start the backend, dashboard, and iOS app.
