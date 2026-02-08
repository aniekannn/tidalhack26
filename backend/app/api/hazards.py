"""
HorizonX — Hazard Report API

Endpoints for:
  - Submitting anonymized hazard reports from mobile
  - Batch syncing queued offline reports
  - Querying hazards by location
"""

import uuid
from datetime import datetime, timezone
from typing import Optional

from fastapi import APIRouter, HTTPException, Query, Depends
from pydantic import BaseModel, Field
from sqlalchemy.orm import Session
from app.database import get_db

# Import schemas (shared with mobile via schemas/ directory)
import sys
sys.path.insert(0, "../../schemas")

router = APIRouter()


# ─── Inline Models (mirror schemas/hazard_report.py for standalone operation) ─

class CoarseLocation(BaseModel):
    latitude: float = Field(..., ge=-90, le=90)
    longitude: float = Field(..., ge=-180, le=180)
    accuracy_meters: float = 50.0


class HazardReportCreate(BaseModel):
    hazard_type: str
    severity: str
    description: str = Field(..., max_length=500)
    location: CoarseLocation
    timestamp: datetime
    device_hash: str = Field(..., min_length=16, max_length=64)
    confidence: float = Field(default=0.8, ge=0.0, le=1.0)
    context_tags: list[str] = Field(default_factory=list)


class HazardReportResponse(HazardReportCreate):
    id: str
    status: str = "pending"
    corroboration_count: int = 1
    created_at: datetime


class BatchSyncRequest(BaseModel):
    reports: list[HazardReportCreate] = Field(..., max_length=50)


class BatchSyncResponse(BaseModel):
    accepted: int
    rejected: int
    report_ids: list[str]


# ─── In-Memory Store (replace with PostgreSQL + PostGIS in production) ────────

_hazard_store: list[HazardReportResponse] = []


# ─── Endpoints ────────────────────────────────────────────────────────────────

@router.post("/report", response_model=HazardReportResponse, status_code=201)
async def submit_hazard_report(report: HazardReportCreate):
    """
    Submit a single anonymized hazard report.
    
    Privacy guarantees:
    - No images accepted or stored
    - Location is pre-fuzzed on device (±50m)
    - Timestamp is pre-rounded on device (15-min intervals)
    - device_hash is a rotating anonymous identifier
    """
    stored = HazardReportResponse(
        **report.model_dump(),
        id=str(uuid.uuid4()),
        status="pending",
        corroboration_count=1,
        created_at=datetime.now(timezone.utc),
    )
    _hazard_store.append(stored)
    
    # Check for corroboration (nearby similar reports)
    _check_corroboration(stored)
    
    return stored


@router.post("/sync", response_model=BatchSyncResponse)
async def batch_sync_reports(batch: BatchSyncRequest, db: Session = Depends(get_db)):
    """
    Batch sync queued offline reports.
    Mobile app calls this when connectivity is restored.
    Max 50 reports per batch.
    Also creates alerts in the database for dashboard display.
    """
    from app.models.alerts import Alert
    
    accepted_ids = []
    rejected = 0
    
    for report in batch.reports:
        try:
            stored = HazardReportResponse(
                **report.model_dump(),
                id=str(uuid.uuid4()),
                status="pending",
                corroboration_count=1,
                created_at=datetime.now(timezone.utc),
            )
            _hazard_store.append(stored)
            accepted_ids.append(stored.id)
            
            # Also create an Alert record for dashboard display
            severity_map = {"low": 2, "medium": 3, "high": 4, "critical": 5}
            severity_int = severity_map.get(report.severity.lower(), 3)
            
            db_alert = Alert(
                latitude=report.location.latitude,
                longitude=report.location.longitude,
                report_type=report.hazard_type,
                description=report.description,
                severity=severity_int,
                confidence=report.confidence,
                objects_detected=report.context_tags,
                device_hash=report.device_hash,
                is_public=True,  # Make visible on dashboard
            )
            db.add(db_alert)
            
        except Exception as e:
            print(f"Error processing hazard report: {e}")
            rejected += 1
    
    # Commit all alerts at once
    try:
        db.commit()
    except Exception as e:
        print(f"Error committing alerts to database: {e}")
        db.rollback()
    
    return BatchSyncResponse(
        accepted=len(accepted_ids),
        rejected=rejected,
        report_ids=accepted_ids,
    )


@router.get("/nearby", response_model=list[HazardReportResponse])
async def get_nearby_hazards(
    lat: float = Query(..., ge=-90, le=90),
    lng: float = Query(..., ge=-180, le=180),
    radius_km: float = Query(default=2.0, ge=0.1, le=50.0),
    hazard_type: Optional[str] = None,
    limit: int = Query(default=50, ge=1, le=200),
):
    """
    Get hazard reports near a location.
    Used by mobile app for local awareness and dashboard for map display.
    
    In production: uses PostGIS ST_DWithin for efficient spatial queries.
    """
    results = []
    for h in _hazard_store:
        dist = _haversine(lat, lng, h.location.latitude, h.location.longitude)
        if dist <= radius_km:
            if hazard_type is None or h.hazard_type == hazard_type:
                results.append(h)
    
    results.sort(key=lambda x: x.created_at, reverse=True)
    return results[:limit]


@router.get("/report/{report_id}", response_model=HazardReportResponse)
async def get_hazard_report(report_id: str):
    """Get a specific hazard report by ID."""
    for h in _hazard_store:
        if h.id == report_id:
            return h
    raise HTTPException(status_code=404, detail="Report not found")


# ─── Helpers ──────────────────────────────────────────────────────────────────

def _haversine(lat1: float, lng1: float, lat2: float, lng2: float) -> float:
    """Approximate distance in km between two GPS coordinates."""
    import math
    R = 6371  # Earth radius in km
    dlat = math.radians(lat2 - lat1)
    dlng = math.radians(lng2 - lng1)
    a = (math.sin(dlat / 2) ** 2 +
         math.cos(math.radians(lat1)) * math.cos(math.radians(lat2)) *
         math.sin(dlng / 2) ** 2)
    return R * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))


def _check_corroboration(new_report: HazardReportResponse):
    """Check if similar reports exist nearby and update corroboration counts."""
    for existing in _hazard_store:
        if existing.id == new_report.id:
            continue
        if existing.hazard_type != new_report.hazard_type:
            continue
        dist = _haversine(
            new_report.location.latitude, new_report.location.longitude,
            existing.location.latitude, existing.location.longitude,
        )
        if dist <= 0.1:  # Within 100m
            existing.corroboration_count += 1
            new_report.corroboration_count += 1
            if existing.corroboration_count >= 2:
                existing.status = "confirmed"
            if new_report.corroboration_count >= 2:
                new_report.status = "confirmed"
