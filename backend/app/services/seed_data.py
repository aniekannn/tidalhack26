"""
HorizonX — Seed Data Service

Loads pre-computed hazard data from computed.json into the database.
Based on treehack2025/computed.json structure.
"""

import json
import os
from pathlib import Path
from sqlalchemy.orm import Session
from app.models.alerts import HazardData
from app.database import SessionLocal


def get_data_path() -> Path:
    """Get the path to the computed.json data file."""
    return Path(__file__).parent.parent / "data" / "computed.json"


def load_seed_data() -> list[dict]:
    """Load hazard data from computed.json."""
    data_path = get_data_path()
    if not data_path.exists():
        print(f"Warning: Seed data file not found at {data_path}")
        return []
    
    with open(data_path, "r") as f:
        return json.load(f)


def seed_hazard_data(db: Session) -> int:
    """
    Seed the database with pre-computed hazard data.
    Returns the number of records inserted.
    """
    # Check if data already exists
    existing_count = db.query(HazardData).count()
    if existing_count > 0:
        print(f"Database already contains {existing_count} hazard records. Skipping seed.")
        return 0
    
    data = load_seed_data()
    if not data:
        return 0
    
    records_inserted = 0
    for item in data:
        coordinates = item.get("coordinates", [None, None])
        latitude = coordinates[0] if len(coordinates) > 0 else None
        longitude = coordinates[1] if len(coordinates) > 1 else None
        
        hazard = HazardData(
            issue_type=item.get("issue_type", "Unknown"),
            location=item.get("location", "Unknown"),
            description=item.get("description"),
            source=item.get("source"),
            source_links=item.get("source_links", []),
            date=item.get("date"),
            category=item.get("category"),
            latitude=latitude,
            longitude=longitude,
        )
        db.add(hazard)
        records_inserted += 1
    
    db.commit()
    print(f"Seeded {records_inserted} hazard records into database.")
    return records_inserted


def run_seed():
    """Run the seeding process."""
    db = SessionLocal()
    try:
        return seed_hazard_data(db)
    finally:
        db.close()


if __name__ == "__main__":
    run_seed()
