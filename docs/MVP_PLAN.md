# HorizonX — 48-Hour Hackathon MVP Plan

## Timeline Overview

```
Hour  0 ─── 6 ─── 12 ─── 18 ─── 24 ─── 30 ─── 36 ─── 42 ─── 48
      │         │          │          │          │          │
      ▼         ▼          ▼          ▼          ▼          ▼
   SCAFFOLD  CORE ML    BACKEND    DASHBOARD   POLISH    PRESENT
```

---

## Phase 1: Foundation (Hours 0-6)

### Hour 0-2: Project Setup
- [ ] Git repo, branch strategy (main + dev)
- [ ] Android project scaffold (Kotlin, CameraX dependencies)
- [ ] FastAPI project scaffold (endpoints, models)
- [ ] Dashboard scaffold (HTML/JS, Leaflet setup)
- [ ] DigitalOcean Droplet provisioned

### Hour 2-4: Core Mobile Shell
- [ ] CameraX integration — live camera feed working
- [ ] Frame capture pipeline (30fps → 10fps sampling)
- [ ] Android native TTS working (basic speech output)
- [ ] Permission flow (camera, location, microphone)

### Hour 4-6: Backend Foundation
- [ ] FastAPI running on DO
- [ ] Hazard report POST endpoint (in-memory store)
- [ ] Basic CORS + health check
- [ ] Dashboard HTML served, Leaflet map rendering

**Milestone: Camera captures frames, TTS speaks, API accepts reports, map displays.**

---

## Phase 2: Core Intelligence (Hours 6-18)

### Hour 6-10: On-Device Vision (CRITICAL PATH)
- [ ] Download MobileVLM v2 quantized weights (~850MB)
- [ ] TFLite integration with GPU delegate
- [ ] First successful on-device inference
- [ ] Scene narration prompt engineering + output parsing
- [ ] Fallback: if VLM too slow, use MobileNet + BLIP-2 combo

### Hour 10-14: Speech & Interaction
- [ ] Vision → TTS pipeline (scene description → spoken output)
- [ ] Priority queue (immediate alerts interrupt ambient narration)
- [ ] Spatial audio hints (left/right pan for directional cues)
- [ ] Basic voice command recognition (STT → intent parsing)
- [ ] OCR integration (ML Kit on-device text recognition)

### Hour 14-18: Hazard Pipeline
- [ ] Hazard classification from scene descriptions
- [ ] Privacy transforms (location fuzzing, timestamp rounding, device hashing)
- [ ] Local SQLite queue for offline storage
- [ ] Background sync to backend when online
- [ ] Corroboration logic (nearby similar reports → confirmed)

**Milestone: Phone describes surroundings, detects obstacles, reads text, queues hazard reports.**

---

## Phase 3: Civic Platform (Hours 18-30)

### Hour 18-22: Backend Intelligence
- [ ] PostGIS spatial queries (nearby hazards, clustering)
- [ ] Hazard cluster aggregation (ST_ClusterDBSCAN)
- [ ] Dashboard stats endpoint (totals, breakdowns, trends)
- [ ] Gemini integration for scene enhancement (cloud optional)
- [ ] ElevenLabs TTS proxy endpoint

### Hour 22-26: Dashboard Build
- [ ] Interactive hazard map with cluster markers
- [ ] Hazard type filtering (potholes, blocked, ramps, etc.)
- [ ] Sidebar: live hazard list with severity badges
- [ ] Severity distribution chart
- [ ] Accessibility score cards per neighborhood

### Hour 26-30: Integration
- [ ] Mobile → Backend sync tested end-to-end
- [ ] Dashboard auto-refreshes with new reports
- [ ] Hazard click → map fly-to animation
- [ ] Time range filtering (24h / 7d / 30d)

**Milestone: Full loop — phone detects hazard → syncs to cloud → appears on live map.**

---

## Phase 4: Polish & Demo Prep (Hours 30-42)

### Hour 30-34: UX Polish
- [ ] Refine VLM prompts for natural narration
- [ ] Tune TTS speech rate and priority interruption
- [ ] Add haptic feedback for obstacle alerts
- [ ] Smooth camera → inference → speech latency
- [ ] Error handling: graceful degradation messaging

### Hour 34-38: Dashboard Polish
- [ ] Dark theme refinement
- [ ] Mobile-responsive layout
- [ ] Loading states and animations
- [ ] Populate with realistic demo data
- [ ] Export/PDF feature for audit reports

### Hour 38-42: Demo Script
- [ ] Record demo video (90 seconds)
- [ ] Prepare live demo flow:
  1. Walk with phone → real-time narration (15s)
  2. Encounter obstacle → alert + hazard report (15s)
  3. Read a sign with OCR → spoken output (10s)
  4. Switch to dashboard → show hazard on map (15s)
  5. Show analytics + accessibility scores (15s)
  6. Highlight privacy architecture (10s)
- [ ] Prepare backup video in case live demo fails
- [ ] Slide deck: problem → solution → architecture → demo → impact

---

## Phase 5: Presentation (Hours 42-48)

### Hour 42-44: Rehearsal
- [ ] Full run-through (time it: must be < 5 minutes)
- [ ] Q&A prep: privacy, scalability, business model
- [ ] Technical backup plans if live demo fails

### Hour 44-46: Final Fixes
- [ ] Any last-minute bugs
- [ ] Deploy final backend + dashboard
- [ ] Test on presentation device

### Hour 46-48: Present
- [ ] Live demo + slides
- [ ] Key talking points:
  - 2.2B people with vision impairments
  - First offline-first AI sight companion
  - Privacy by design (no images leave device)
  - Civic value: governments get free hazard intelligence
  - Built in 48 hours with open-source ML models

---

## Risk Mitigation

| Risk | Mitigation |
|------|-----------|
| VLM too slow on device | Fallback to MobileNet + caption model (lower quality, faster) |
| Model download fails | Pre-cache on test device before hackathon |
| Live demo network fails | Entire mobile app works offline; show offline mode |
| PostGIS setup issues | Use in-memory Python spatial queries (slower, but works) |
| TFLite GPU delegate crashes | Fall back to CPU delegate (slower but stable) |
| Gemini API rate limit | Mock responses ready; core app doesn't need Gemini |

---

## Team Allocation (3-4 person team)

| Person | Role | Hours 0-18 | Hours 18-36 | Hours 36-48 |
|--------|------|-----------|-------------|-------------|
| Dev 1 | Mobile/ML Lead | Camera + VLM integration | Hazard pipeline + polish | Demo prep |
| Dev 2 | Backend Lead | FastAPI + DB setup | Gemini/ElevenLabs + clustering | Dashboard polish |
| Dev 3 | Frontend Lead | Dashboard scaffold | Full dashboard build | Presentation |
| Dev 4 | Design/Demo | UX research + prompts | Demo data + testing | Slides + video |

---

## Judging Criteria Mapping

| Criterion | How We Score |
|-----------|-------------|
| Innovation | First offline-first AI sight companion with civic feedback loop |
| Technical Complexity | On-device VLM + spatial audio + privacy pipeline + geo-analytics |
| Impact | 2.2B potential users + municipal infrastructure intelligence |
| Privacy | Zero images transmitted, rotating hashes, fuzzed locations |
| Feasibility | Working demo in 48 hours with quantized models on consumer hardware |
| Design | Voice-first UX (no visual dependency) + professional dashboard |
