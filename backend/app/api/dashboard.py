"""
HorizonX — Civic Dashboard API

Endpoints for government dashboard:
  - Aggregated hazard clusters
  - Analytics & statistics
  - Accessibility audit data
"""

from datetime import datetime, timezone, timedelta
from typing import Optional

from fastapi import APIRouter, Query
from pydantic import BaseModel, Field

router = APIRouter()


# ─── Response Models ──────────────────────────────────────────────────────────

class HazardClusterResponse(BaseModel):
    cluster_id: str
    center_lat: float
    center_lng: float
    radius_meters: float
    hazard_type: str
    avg_severity: float
    report_count: int
    latest_report: datetime
    status: str
    description_summary: str


class DashboardStats(BaseModel):
    total_reports: int
    reports_24h: int
    reports_7d: int
    active_clusters: int
    hazard_breakdown: dict[str, int]
    severity_breakdown: dict[str, int]
    top_areas: list[dict]
    resolution_rate: float


class AccessibilityScore(BaseModel):
    area_name: str
    lat: float
    lng: float
    score: float = Field(ge=0.0, le=100.0)
    issues: list[str]
    last_updated: datetime


# ─── Mock Data for Hackathon Demo ─────────────────────────────────────────────

_mock_clusters = [
    HazardClusterResponse(
        cluster_id="clst_001",
        center_lat=40.7128,
        center_lng=-74.0060,
        radius_meters=30.0,
        hazard_type="pothole",
        avg_severity=2.5,
        report_count=7,
        latest_report=datetime.now(timezone.utc) - timedelta(hours=2),
        status="confirmed",
        description_summary="Cluster of potholes near Broadway & Wall St intersection, affecting sidewalk"
    ),
    HazardClusterResponse(
        cluster_id="clst_002",
        center_lat=40.7580,
        center_lng=-73.9855,
        radius_meters=50.0,
        hazard_type="blocked_sidewalk",
        avg_severity=3.0,
        report_count=12,
        latest_report=datetime.now(timezone.utc) - timedelta(hours=1),
        status="confirmed",
        description_summary="Construction scaffolding blocking sidewalk on 7th Ave near Times Square"
    ),
    HazardClusterResponse(
        cluster_id="clst_003",
        center_lat=40.7484,
        center_lng=-73.9857,
        radius_meters=20.0,
        hazard_type="missing_ramp",
        avg_severity=3.5,
        report_count=5,
        latest_report=datetime.now(timezone.utc) - timedelta(hours=6),
        status="investigating",
        description_summary="Missing curb ramp at 34th St & 5th Ave, wheelchair users report difficulty"
    ),
    HazardClusterResponse(
        cluster_id="clst_004",
        center_lat=40.7614,
        center_lng=-73.9776,
        radius_meters=40.0,
        hazard_type="broken_signage",
        avg_severity=1.5,
        report_count=3,
        latest_report=datetime.now(timezone.utc) - timedelta(days=1),
        status="pending",
        description_summary="Faded crosswalk markings and broken pedestrian signal near Rockefeller Center"
    ),
    HazardClusterResponse(
        cluster_id="clst_005",
        center_lat=40.7282,
        center_lng=-73.7949,
        radius_meters=60.0,
        hazard_type="poor_lighting",
        avg_severity=2.0,
        report_count=8,
        latest_report=datetime.now(timezone.utc) - timedelta(hours=8),
        status="confirmed",
        description_summary="Multiple reports of broken streetlights along Queens Blvd underpass"
    ),
]


# ─── Endpoints ────────────────────────────────────────────────────────────────

@router.get("/clusters", response_model=list[HazardClusterResponse])
async def get_hazard_clusters(
    lat: Optional[float] = Query(default=None, ge=-90, le=90),
    lng: Optional[float] = Query(default=None, ge=-180, le=180),
    radius_km: float = Query(default=10.0, ge=0.1, le=100.0),
    hazard_type: Optional[str] = None,
    min_reports: int = Query(default=1, ge=1),
):
    """
    Get aggregated hazard clusters for map display.
    
    Clusters are computed by ST_ClusterDBSCAN in production.
    For hackathon: returns mock data centered on NYC.
    """
    results = _mock_clusters
    if hazard_type:
        results = [c for c in results if c.hazard_type == hazard_type]
    results = [c for c in results if c.report_count >= min_reports]
    return results


@router.get("/stats", response_model=DashboardStats)
async def get_dashboard_stats():
    """
    Aggregate statistics for the civic dashboard overview.
    """
    return DashboardStats(
        total_reports=247,
        reports_24h=23,
        reports_7d=89,
        active_clusters=len(_mock_clusters),
        hazard_breakdown={
            "pothole": 45,
            "blocked_sidewalk": 38,
            "missing_ramp": 22,
            "broken_signage": 19,
            "poor_lighting": 31,
            "construction": 28,
            "crowd_density": 15,
            "flooding": 12,
            "uneven_surface": 21,
            "other": 16,
        },
        severity_breakdown={
            "low": 67,
            "medium": 98,
            "high": 56,
            "critical": 26,
        },
        top_areas=[
            {"area": "Times Square", "reports": 34, "primary_hazard": "blocked_sidewalk"},
            {"area": "Wall Street", "reports": 28, "primary_hazard": "pothole"},
            {"area": "34th Street", "reports": 22, "primary_hazard": "missing_ramp"},
            {"area": "Queens Blvd", "reports": 19, "primary_hazard": "poor_lighting"},
            {"area": "Rockefeller Center", "reports": 15, "primary_hazard": "broken_signage"},
        ],
        resolution_rate=0.34,
    )


@router.get("/accessibility-scores", response_model=list[AccessibilityScore])
async def get_accessibility_scores(
    lat: float = Query(default=40.7128, ge=-90, le=90),
    lng: float = Query(default=-74.0060, ge=-180, le=180),
    radius_km: float = Query(default=5.0, ge=0.1, le=50.0),
):
    """
    Computed accessibility scores for city zones.
    Based on hazard density, infrastructure quality, and complaint data.
    """
    return [
        AccessibilityScore(
            area_name="Financial District",
            lat=40.7075, lng=-74.0021,
            score=72.0,
            issues=["potholes", "uneven_surface"],
            last_updated=datetime.now(timezone.utc),
        ),
        AccessibilityScore(
            area_name="Midtown West",
            lat=40.7580, lng=-73.9855,
            score=45.0,
            issues=["blocked_sidewalk", "construction", "crowd_density"],
            last_updated=datetime.now(timezone.utc),
        ),
        AccessibilityScore(
            area_name="Murray Hill",
            lat=40.7484, lng=-73.9780,
            score=68.0,
            issues=["missing_ramp", "broken_signage"],
            last_updated=datetime.now(timezone.utc),
        ),
        AccessibilityScore(
            area_name="Rego Park",
            lat=40.7282, lng=-73.8628,
            score=55.0,
            issues=["poor_lighting", "uneven_surface"],
            last_updated=datetime.now(timezone.utc),
        ),
    ]


@router.get("/trends")
async def get_hazard_trends(
    days: int = Query(default=30, ge=1, le=365),
):
    """
    Time-series hazard trend data for dashboard charts.
    """
    from datetime import timedelta
    import random
    
    base_date = datetime.now(timezone.utc) - timedelta(days=days)
    trends = []
    for i in range(days):
        date = base_date + timedelta(days=i)
        trends.append({
            "date": date.isoformat(),
            "total_reports": random.randint(5, 30),
            "resolved": random.randint(1, 10),
            "new_clusters": random.randint(0, 3),
        })
    return trends
