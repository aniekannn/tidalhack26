"""
HorizonX — Data Schemas for Hazard Reporting

These Pydantic models define the data contracts between:
  - Mobile app → Backend API (hazard submission)
  - Backend → Civic Dashboard (aggregated data)
  - Internal storage (SQLite on device, PostgreSQL on server)
"""

from datetime import datetime
from enum import Enum
from typing import Optional
from pydantic import BaseModel, Field, field_validator


# ─── Enums ────────────────────────────────────────────────────────────────────

class HazardType(str, Enum):
    POTHOLE = "pothole"
    BROKEN_SIGNAGE = "broken_signage"
    BLOCKED_SIDEWALK = "blocked_sidewalk"
    MISSING_RAMP = "missing_ramp"
    POOR_LIGHTING = "poor_lighting"
    CROWD_DENSITY = "crowd_density"
    CONSTRUCTION = "construction"
    FLOODING = "flooding"
    BROKEN_TRAFFIC_LIGHT = "broken_traffic_light"
    UNEVEN_SURFACE = "uneven_surface"
    OTHER = "other"


class SeverityLevel(str, Enum):
    LOW = "low"          # Minor inconvenience
    MEDIUM = "medium"    # Navigable but difficult
    HIGH = "high"        # Dangerous, needs immediate attention
    CRITICAL = "critical"  # Impassable, emergency


class ReportStatus(str, Enum):
    PENDING = "pending"
    CONFIRMED = "confirmed"     # Corroborated by 2+ reports
    INVESTIGATING = "investigating"
    RESOLVED = "resolved"
    DISMISSED = "dismissed"


# ─── Mobile → Backend: Hazard Report Submission ──────────────────────────────

class CoarseLocation(BaseModel):
    """GPS coordinates fuzzed to ±50m for privacy."""
    latitude: float = Field(..., ge=-90, le=90)
    longitude: float = Field(..., ge=-180, le=180)
    accuracy_meters: float = Field(default=50.0, description="Fuzzing radius applied")

    @field_validator("latitude", "longitude")
    @classmethod
    def round_coordinates(cls, v: float) -> float:
        """Round to ~50m precision (3 decimal places ≈ 111m)."""
        return round(v, 3)


class HazardReportCreate(BaseModel):
    """
    Submitted by the mobile app.
    No images. No audio. No PII. Only structured data.
    """
    hazard_type: HazardType
    severity: SeverityLevel
    description: str = Field(
        ...,
        max_length=500,
        description="AI-generated structured description of the hazard"
    )
    location: CoarseLocation
    timestamp: datetime = Field(
        description="Rounded to nearest 15 minutes for privacy"
    )
    device_hash: str = Field(
        ...,
        min_length=16,
        max_length=64,
        description="Rotating anonymous device identifier (SHA-256, rotates weekly)"
    )
    confidence: float = Field(
        default=0.8,
        ge=0.0,
        le=1.0,
        description="AI model's confidence in hazard classification"
    )
    context_tags: list[str] = Field(
        default_factory=list,
        description="Additional context: ['near_crosswalk', 'school_zone', 'bus_stop']"
    )

    class Config:
        json_schema_extra = {
            "example": {
                "hazard_type": "pothole",
                "severity": "medium",
                "description": "Large pothole approximately 30cm wide on sidewalk, near intersection",
                "location": {"latitude": 40.712, "longitude": -74.006, "accuracy_meters": 50.0},
                "timestamp": "2026-02-07T14:30:00Z",
                "device_hash": "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4",
                "confidence": 0.87,
                "context_tags": ["near_crosswalk", "school_zone"]
            }
        }


# ─── Backend: Stored Hazard Report ───────────────────────────────────────────

class HazardReport(HazardReportCreate):
    """Full hazard report as stored in PostgreSQL."""
    id: str = Field(..., description="UUID v4")
    status: ReportStatus = ReportStatus.PENDING
    corroboration_count: int = Field(default=1, description="Number of similar reports nearby")
    cluster_id: Optional[str] = Field(default=None, description="Spatial cluster assignment")
    created_at: datetime
    updated_at: datetime


# ─── Backend → Dashboard: Aggregated Hazard Cluster ──────────────────────────

class HazardCluster(BaseModel):
    """Aggregated cluster of nearby hazard reports for dashboard display."""
    cluster_id: str
    center_lat: float
    center_lng: float
    radius_meters: float
    hazard_type: HazardType
    avg_severity: float = Field(ge=1.0, le=4.0)
    report_count: int
    latest_report: datetime
    status: ReportStatus
    description_summary: str = Field(
        description="AI-summarized description of the hazard cluster"
    )

    class Config:
        json_schema_extra = {
            "example": {
                "cluster_id": "clst_abc123",
                "center_lat": 40.712,
                "center_lng": -74.006,
                "radius_meters": 25.0,
                "hazard_type": "pothole",
                "avg_severity": 2.5,
                "report_count": 7,
                "latest_report": "2026-02-07T14:30:00Z",
                "status": "confirmed",
                "description_summary": "Multiple reports of a large pothole cluster near Main St & 5th Ave intersection, affecting sidewalk accessibility"
            }
        }


# ─── Dashboard: Analytics Query Params ───────────────────────────────────────

class HazardQueryParams(BaseModel):
    """Query parameters for the civic dashboard API."""
    lat: Optional[float] = None
    lng: Optional[float] = None
    radius_km: float = Field(default=5.0, ge=0.1, le=50.0)
    hazard_types: Optional[list[HazardType]] = None
    min_severity: Optional[SeverityLevel] = None
    status: Optional[ReportStatus] = None
    since: Optional[datetime] = None
    limit: int = Field(default=100, ge=1, le=1000)
    offset: int = Field(default=0, ge=0)


# ─── Mobile: Local Queue Entry ───────────────────────────────────────────────

class QueuedReport(BaseModel):
    """Hazard report queued locally on device when offline."""
    local_id: int = Field(description="Auto-increment SQLite ID")
    report: HazardReportCreate
    queued_at: datetime
    retry_count: int = Field(default=0)
    synced: bool = Field(default=False)
    synced_at: Optional[datetime] = None
