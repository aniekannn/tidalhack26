"""
HorizonX — Alerts API Router

Real-time alert management with WebSocket support.
Based on treehack2025/main.py and treehack2025/horizonx/main.py

Endpoints:
  - POST /alerts/          Create new alert
  - GET  /alerts/          List all alerts (paginated)
  - GET  /alerts/{id}      Get specific alert
  - PATCH /alerts/{id}     Update alert (e.g., make public)
  - DELETE /alerts/{id}    Delete alert
  - WS   /ws/alerts        Real-time alert stream
  - GET  /hazard-data/     Get pre-computed hazard data
"""

from datetime import datetime, timezone
from typing import List, Optional
from fastapi import APIRouter, Depends, HTTPException, WebSocket, WebSocketDisconnect, Query
from sqlalchemy.orm import Session
from pydantic import BaseModel, Field

from app.database import get_db
from app.models.alerts import Alert, HazardData

router = APIRouter()


# ─── Pydantic Schemas ─────────────────────────────────────────────────────────

class AlertCreate(BaseModel):
    """Schema for creating a new alert."""
    latitude: float = Field(..., ge=-90, le=90)
    longitude: float = Field(..., ge=-180, le=180)
    report_type: str = Field(..., max_length=50)
    description: Optional[str] = None
    severity: int = Field(default=3, ge=1, le=5)
    confidence: float = Field(default=0.8, ge=0.0, le=1.0)
    objects_detected: List[str] = Field(default_factory=list)
    device_hash: Optional[str] = Field(default=None, max_length=64)


class AlertUpdate(BaseModel):
    """Schema for updating an alert."""
    is_public: Optional[bool] = None
    description: Optional[str] = None
    severity: Optional[int] = Field(default=None, ge=1, le=5)


class AlertResponse(BaseModel):
    """Schema for alert response."""
    id: int
    latitude: float
    longitude: float
    report_type: str
    description: Optional[str]
    is_public: bool
    severity: int
    confidence: float
    objects_detected: List[str]
    created_at: datetime
    updated_at: datetime

    class Config:
        from_attributes = True


class HazardDataResponse(BaseModel):
    """Schema for pre-computed hazard data response."""
    id: int
    issue_type: str
    location: str
    description: Optional[str]
    source: Optional[str]
    source_links: List[str]
    date: Optional[str]
    category: Optional[str]
    latitude: Optional[float]
    longitude: Optional[float]

    class Config:
        from_attributes = True


# ─── WebSocket Connection Manager ─────────────────────────────────────────────

class ConnectionManager:
    """Manages WebSocket connections for real-time alert broadcasting."""
    
    def __init__(self):
        self.active_connections: List[WebSocket] = []
    
    async def connect(self, websocket: WebSocket):
        await websocket.accept()
        self.active_connections.append(websocket)
    
    def disconnect(self, websocket: WebSocket):
        if websocket in self.active_connections:
            self.active_connections.remove(websocket)
    
    async def broadcast(self, message: dict):
        """Broadcast message to all connected clients."""
        import json
        message_str = json.dumps(message, default=str)
        disconnected = []
        for connection in self.active_connections:
            try:
                await connection.send_text(message_str)
            except Exception:
                disconnected.append(connection)
        
        # Clean up disconnected clients
        for conn in disconnected:
            self.disconnect(conn)


manager = ConnectionManager()


# ─── REST Endpoints ───────────────────────────────────────────────────────────

@router.post("/", response_model=AlertResponse)
async def create_alert(alert: AlertCreate, db: Session = Depends(get_db)):
    """
    Create a new alert.
    Broadcasts to all connected WebSocket clients.
    """
    db_alert = Alert(
        latitude=alert.latitude,
        longitude=alert.longitude,
        report_type=alert.report_type,
        description=alert.description,
        severity=alert.severity,
        confidence=alert.confidence,
        objects_detected=alert.objects_detected,
        device_hash=alert.device_hash,
        is_public=False,
    )
    db.add(db_alert)
    db.commit()
    db.refresh(db_alert)
    
    # Broadcast to WebSocket clients
    await manager.broadcast({
        "type": "new_alert",
        "alert": {
            "id": db_alert.id,
            "latitude": db_alert.latitude,
            "longitude": db_alert.longitude,
            "report_type": db_alert.report_type,
            "description": db_alert.description,
            "severity": db_alert.severity,
            "is_public": db_alert.is_public,
            "created_at": db_alert.created_at.isoformat(),
        }
    })
    
    return db_alert


@router.get("/", response_model=List[AlertResponse])
async def list_alerts(
    skip: int = Query(0, ge=0),
    limit: int = Query(100, ge=1, le=500),
    report_type: Optional[str] = None,
    is_public: Optional[bool] = None,
    min_severity: Optional[int] = Query(None, ge=1, le=5),
    db: Session = Depends(get_db),
):
    """
    List all alerts with optional filtering.
    """
    query = db.query(Alert)
    
    if report_type:
        query = query.filter(Alert.report_type == report_type)
    if is_public is not None:
        query = query.filter(Alert.is_public == is_public)
    if min_severity:
        query = query.filter(Alert.severity >= min_severity)
    
    alerts = query.order_by(Alert.created_at.desc()).offset(skip).limit(limit).all()
    return alerts


@router.get("/{alert_id}", response_model=AlertResponse)
async def get_alert(alert_id: int, db: Session = Depends(get_db)):
    """Get a specific alert by ID."""
    alert = db.query(Alert).filter(Alert.id == alert_id).first()
    if not alert:
        raise HTTPException(status_code=404, detail="Alert not found")
    return alert


@router.patch("/{alert_id}", response_model=AlertResponse)
async def update_alert(
    alert_id: int,
    alert_update: AlertUpdate,
    db: Session = Depends(get_db),
):
    """
    Update an alert (e.g., make it public).
    Broadcasts update to WebSocket clients if made public.
    """
    alert = db.query(Alert).filter(Alert.id == alert_id).first()
    if not alert:
        raise HTTPException(status_code=404, detail="Alert not found")
    
    update_data = alert_update.model_dump(exclude_unset=True)
    for key, value in update_data.items():
        setattr(alert, key, value)
    
    alert.updated_at = datetime.now(timezone.utc)
    db.commit()
    db.refresh(alert)
    
    # Broadcast if made public
    if alert_update.is_public:
        await manager.broadcast({
            "type": "alert_public",
            "alert": {
                "id": alert.id,
                "latitude": alert.latitude,
                "longitude": alert.longitude,
                "report_type": alert.report_type,
                "description": alert.description,
                "severity": alert.severity,
                "created_at": alert.created_at.isoformat(),
            }
        })
    
    return alert


@router.delete("/{alert_id}")
async def delete_alert(alert_id: int, db: Session = Depends(get_db)):
    """Delete an alert."""
    alert = db.query(Alert).filter(Alert.id == alert_id).first()
    if not alert:
        raise HTTPException(status_code=404, detail="Alert not found")
    
    db.delete(alert)
    db.commit()
    
    return {"status": "deleted", "id": alert_id}


# ─── Hazard Data Endpoints ────────────────────────────────────────────────────

@router.get("/hazard-data/", response_model=List[HazardDataResponse])
async def list_hazard_data(
    skip: int = Query(0, ge=0),
    limit: int = Query(100, ge=1, le=500),
    category: Optional[str] = None,
    issue_type: Optional[str] = None,
    db: Session = Depends(get_db),
):
    """
    List pre-computed hazard data from public sources.
    This is seed data from treehack2025/computed.json.
    """
    query = db.query(HazardData)
    
    if category:
        query = query.filter(HazardData.category == category)
    if issue_type:
        query = query.filter(HazardData.issue_type == issue_type)
    
    hazards = query.offset(skip).limit(limit).all()
    return hazards


@router.get("/hazard-data/nearby")
async def get_nearby_hazard_data(
    lat: float = Query(..., ge=-90, le=90),
    lng: float = Query(..., ge=-180, le=180),
    radius_km: float = Query(5.0, ge=0.1, le=50.0),
    limit: int = Query(50, ge=1, le=200),
    db: Session = Depends(get_db),
):
    """
    Get pre-computed hazard data near a location.
    Uses simple bounding box filtering (for SQLite compatibility).
    """
    # Approximate degrees per km (at equator)
    deg_per_km = 0.009
    lat_delta = radius_km * deg_per_km
    lng_delta = radius_km * deg_per_km
    
    hazards = db.query(HazardData).filter(
        HazardData.latitude.isnot(None),
        HazardData.longitude.isnot(None),
        HazardData.latitude >= lat - lat_delta,
        HazardData.latitude <= lat + lat_delta,
        HazardData.longitude >= lng - lng_delta,
        HazardData.longitude <= lng + lng_delta,
    ).limit(limit).all()
    
    return [
        {
            "id": h.id,
            "issue_type": h.issue_type,
            "location": h.location,
            "description": h.description,
            "category": h.category,
            "latitude": h.latitude,
            "longitude": h.longitude,
            "source": h.source,
            "date": h.date,
        }
        for h in hazards
    ]


# ─── WebSocket Endpoint ───────────────────────────────────────────────────────

@router.websocket("/ws")
async def websocket_alerts(websocket: WebSocket):
    """
    WebSocket endpoint for real-time alert streaming.
    Clients receive notifications when new alerts are created or made public.
    """
    await manager.connect(websocket)
    try:
        # Send initial connection confirmation
        await websocket.send_json({
            "type": "connected",
            "message": "Connected to HorizonX alert stream",
            "timestamp": datetime.now(timezone.utc).isoformat(),
        })
        
        # Keep connection alive and handle incoming messages
        while True:
            data = await websocket.receive_text()
            # Echo back or handle client messages if needed
            await websocket.send_json({
                "type": "ack",
                "received": data,
            })
    except WebSocketDisconnect:
        manager.disconnect(websocket)
