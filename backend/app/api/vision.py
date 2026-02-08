"""
HorizonX — Vision API Router

Gemini Vision-based video/image analysis endpoints.
Falls back to MoonDream when Gemini is unavailable.

Endpoints:
  - POST /process-frame       Process a single image frame
  - POST /process-batch       Process multiple frames in parallel
  - GET  /observations        Get all stored observations
  - GET  /observations/nearby Get observations near a location
"""

import time
import base64
import tempfile
import os
from typing import List, Optional
from fastapi import APIRouter, HTTPException, UploadFile, File, Query, Form
from pydantic import BaseModel, Field

from app.services.vision_analyzer import get_video_analyzer, MOONDREAM_AVAILABLE, GEMINI_AVAILABLE

router = APIRouter()


# ─── Pydantic Schemas ─────────────────────────────────────────────────────────

class FrameInput(BaseModel):
    """Input for a single frame to process."""
    frame_id: int
    image_base64: str = Field(..., description="Base64-encoded image data")
    latitude: float = Field(..., ge=-90, le=90)
    longitude: float = Field(..., ge=-180, le=180)
    timestamp: Optional[float] = None


class FrameResult(BaseModel):
    """Result from processing a single frame."""
    frame_id: int
    environment: str
    urgency: int
    source_count: int


class BatchFrameInput(BaseModel):
    """Input for batch frame processing."""
    frames: List[FrameInput] = Field(..., max_length=10)
    max_workers: int = Field(default=4, ge=1, le=8)


class ObservationQuery(BaseModel):
    """Query parameters for nearby observations."""
    latitude: float = Field(..., ge=-90, le=90)
    longitude: float = Field(..., ge=-180, le=180)
    radius_km: float = Field(default=1.0, ge=0.1, le=50.0)


# ─── Endpoints ────────────────────────────────────────────────────────────────

@router.get("/status")
async def vision_status():
    """Check if the vision analysis service is available."""
    analyzer = get_video_analyzer()
    return {
        "available": analyzer.is_available,
        "primary_model": "gemini" if analyzer.using_gemini else "moondream",
        "gemini_available": GEMINI_AVAILABLE and analyzer.using_gemini,
        "moondream_available": MOONDREAM_AVAILABLE,
        "model_loaded": analyzer._model_loaded,
        "observation_count": len(analyzer.get_geo_snapshot()),
    }


@router.post("/process-frame", response_model=FrameResult)
async def process_frame(
    latitude: float = Form(...),
    longitude: float = Form(...),
    frame_id: int = Form(default=1),
    image: UploadFile = File(...),
):
    """
    Process a single image frame and extract environment observations.
    
    The image is analyzed using MoonDream VLM to detect hazards,
    obstacles, and accessibility issues.
    """
    analyzer = get_video_analyzer()
    
    # Save uploaded file temporarily
    with tempfile.NamedTemporaryFile(delete=False, suffix=".jpg") as tmp:
        content = await image.read()
        tmp.write(content)
        tmp_path = tmp.name
    
    try:
        result = analyzer.process_frame(
            frame_id=frame_id,
            image_path=tmp_path,
            lat=latitude,
            lon=longitude,
            timestamp=time.time(),
        )
        
        if result is None:
            raise HTTPException(status_code=500, detail="Failed to process frame")
        
        return FrameResult(
            frame_id=frame_id,
            environment=result["environment"],
            urgency=result["urgency"],
            source_count=result["source_count"],
        )
    finally:
        # Clean up temp file
        os.unlink(tmp_path)


@router.post("/process-frame-base64", response_model=FrameResult)
async def process_frame_base64(frame: FrameInput):
    """
    Process a single image frame from base64-encoded data.
    """
    analyzer = get_video_analyzer()
    
    # Decode base64 and save temporarily
    try:
        image_data = base64.b64decode(frame.image_base64)
    except Exception:
        raise HTTPException(status_code=400, detail="Invalid base64 image data")
    
    with tempfile.NamedTemporaryFile(delete=False, suffix=".jpg") as tmp:
        tmp.write(image_data)
        tmp_path = tmp.name
    
    try:
        result = analyzer.process_frame(
            frame_id=frame.frame_id,
            image_path=tmp_path,
            lat=frame.latitude,
            lon=frame.longitude,
            timestamp=frame.timestamp or time.time(),
        )
        
        if result is None:
            raise HTTPException(status_code=500, detail="Failed to process frame")
        
        return FrameResult(
            frame_id=frame.frame_id,
            environment=result["environment"],
            urgency=result["urgency"],
            source_count=result["source_count"],
        )
    finally:
        os.unlink(tmp_path)


@router.post("/process-batch")
async def process_batch(batch: BatchFrameInput):
    """
    Process multiple frames in parallel.
    
    Note: This endpoint accepts base64-encoded images in the request body.
    For large batches, consider using the file upload endpoint instead.
    """
    analyzer = get_video_analyzer()
    results = []
    temp_files = []
    
    try:
        # Prepare frames with temporary files
        frames_to_process = []
        for frame in batch.frames:
            try:
                image_data = base64.b64decode(frame.image_base64)
            except Exception:
                continue
            
            with tempfile.NamedTemporaryFile(delete=False, suffix=".jpg") as tmp:
                tmp.write(image_data)
                temp_files.append(tmp.name)
                frames_to_process.append({
                    "frame_id": frame.frame_id,
                    "path": tmp.name,
                    "lat": frame.latitude,
                    "lon": frame.longitude,
                    "time": frame.timestamp or time.time(),
                })
        
        # Process in parallel
        results = analyzer.process_video(frames_to_process, max_workers=batch.max_workers)
        
        return {
            "processed": len(results),
            "total": len(batch.frames),
            "results": results,
        }
    finally:
        # Clean up temp files
        for path in temp_files:
            try:
                os.unlink(path)
            except Exception:
                pass


@router.get("/observations")
async def get_observations():
    """
    Get all stored observations from the hierarchical geo store.
    
    Returns observations grouped by location bins at different radius levels.
    """
    analyzer = get_video_analyzer()
    snapshot = analyzer.get_geo_snapshot()
    
    return {
        "bins": snapshot,
        "bin_count": len(snapshot),
        "total_observations": sum(len(obs) for obs in snapshot.values()),
    }


@router.get("/observations/nearby")
async def get_nearby_observations(
    lat: float = Query(..., ge=-90, le=90),
    lng: float = Query(..., ge=-180, le=180),
    radius_km: float = Query(default=1.0, ge=0.1, le=50.0),
):
    """
    Get observations near a specific location.
    
    Returns observations within the specified radius, sorted by distance.
    """
    analyzer = get_video_analyzer()
    observations = analyzer.query_nearby(lat, lng, radius_km)
    
    # Sort by distance
    observations.sort(key=lambda x: x["distance_km"])
    
    return {
        "center": {"lat": lat, "lng": lng},
        "radius_km": radius_km,
        "count": len(observations),
        "observations": observations,
    }


@router.post("/observations/clear")
async def clear_observations():
    """
    Clear all stored observations.
    Use with caution - this cannot be undone.
    """
    global _analyzer_instance
    from app.services.vision_analyzer import _analyzer_instance, VideoAnalyzer
    
    # Reset the geo store
    analyzer = get_video_analyzer()
    analyzer.geo_store = analyzer.geo_store.__class__()
    
    return {"status": "cleared", "message": "All observations have been cleared"}
