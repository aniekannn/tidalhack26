"""
WayFinder Backend — FastAPI Application

Lightweight API for:
  - Hazard report ingestion from mobile app
  - Hazard aggregation & clustering
  - Civic dashboard data endpoints
  - Gemini Vision for real-time obstacle detection
  - ElevenLabs TTS proxy
  - Real-time alerts with WebSocket
  - Pre-computed hazard data for College Station, TX
"""

import os
from pathlib import Path
from dotenv import load_dotenv

# Load environment variables from .env file
env_path = Path(__file__).parent.parent.parent / ".env"
if env_path.exists():
    load_dotenv(env_path)
    print(f"Loaded environment from {env_path}")
else:
    print(f"No .env file found at {env_path}")

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.api.hazards import router as hazards_router
from app.api.dashboard import router as dashboard_router
from app.api.ai_services import router as ai_router
from app.api.health import router as health_router
from app.api.alerts import router as alerts_router
from app.api.vision import router as vision_router

from app.database import init_db
from app.services.seed_data import seed_hazard_data
from app.database import SessionLocal

app = FastAPI(
    title="WayFinder API",
    description="Privacy-first hazard intelligence platform for accessible cities - College Station, TX",
    version="0.3.0",
    docs_url="/docs",
    redoc_url="/redoc",
)

# CORS — allow dashboard and mobile app
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # Lock down in production
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Register routers
app.include_router(health_router, tags=["Health"])
app.include_router(hazards_router, prefix="/api/v1/hazards", tags=["Hazards"])
app.include_router(dashboard_router, prefix="/api/v1/dashboard", tags=["Dashboard"])
app.include_router(ai_router, prefix="/api/v1/ai", tags=["AI Services"])

# New routers from treehack2025 integration
app.include_router(alerts_router, prefix="/api/v1/alerts", tags=["Alerts"])
app.include_router(vision_router, prefix="/api/v1/vision", tags=["Vision"])


@app.on_event("startup")
async def startup():
    """Initialize database connection pool and load models."""
    print("Initializing database...")
    init_db()
    
    # Seed pre-computed hazard data
    print("Checking for seed data...")
    db = SessionLocal()
    try:
        seed_hazard_data(db)
    finally:
        db.close()
    
    # Log API key status
    gemini_key = os.environ.get("GEMINI_API_KEY", "")
    eleven_key = os.environ.get("ELEVENLABS_API_KEY", "")
    print(f"Gemini API: {'configured' if gemini_key and gemini_key != 'your-gemini-api-key' else 'NOT configured'}")
    print(f"ElevenLabs API: {'configured' if eleven_key and eleven_key != 'your-elevenlabs-api-key' else 'NOT configured'}")
    
    print("WayFinder API starting up...")


@app.on_event("shutdown")
async def shutdown():
    """Cleanup resources."""
    print("WayFinder API shutting down...")
