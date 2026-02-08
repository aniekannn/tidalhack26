"""
HorizonX — Vision Analyzer Service

MoonDream-based video frame analysis with hierarchical geospatial storage.
Based on treehack2025/moondream/main.py

Features:
  - Process video frames with geospatial coordinates
  - Hierarchical storage at multiple radius levels (0.1km, 1km, 10km)
  - Observation merging based on text similarity
  - Thread-safe parallel processing
"""

import math
import threading
import time
from typing import List, Dict, Any, Tuple, Optional
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from datetime import datetime, timezone

# Optional MoonDream import - gracefully handle if not installed
try:
    import moondream as md
    from PIL import Image
    MOONDREAM_AVAILABLE = True
except ImportError:
    MOONDREAM_AVAILABLE = False
    md = None
    Image = None


def haversine_distance(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    """
    Compute the great-circle distance between two points on Earth (in kilometers).
    """
    R = 6371.0  # Earth radius in km
    lat_rad1, lon_rad1 = math.radians(lat1), math.radians(lon1)
    lat_rad2, lon_rad2 = math.radians(lat2), math.radians(lon2)

    delta_lat = lat_rad2 - lat_rad1
    delta_lon = lon_rad2 - lon_rad1
    a = (math.sin(delta_lat / 2) ** 2 +
         math.cos(lat_rad1) * math.cos(lat_rad2) * math.sin(delta_lon / 2) ** 2)
    c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))
    return R * c


def simple_text_similarity(a: str, b: str) -> float:
    """
    A naive text similarity measure using word overlap.
    For production, consider using embeddings from a model.
    """
    set_a = set(a.lower().split())
    set_b = set(b.lower().split())
    if not set_a or not set_b:
        return 0.0
    return len(set_a.intersection(set_b)) / (max(len(set_a), len(set_b)) + 1e-9)


@dataclass
class Observation:
    """Holds a single environment observation."""
    environment: str
    urgency: int
    sources: List[Dict[str, Any]] = field(default_factory=list)
    
    def to_dict(self) -> dict:
        return {
            "environment": self.environment,
            "urgency": self.urgency,
            "sources": self.sources,
            "source_count": len(self.sources),
        }


class GeoBin:
    """
    Stores Observations in a particular geospatial bin.
    Allows merging of similar observations.
    """
    
    def __init__(self):
        self.observations: List[Observation] = []
        self.lock = threading.Lock()
    
    def merge_or_add_observation(self, new_obs: Observation, sim_threshold: float = 0.6):
        """
        Merge new_obs into existing if similarity >= sim_threshold; else add new entry.
        """
        with self.lock:
            for existing in self.observations:
                sim = simple_text_similarity(existing.environment, new_obs.environment)
                if sim >= sim_threshold:
                    # Merge: combine sources, take max urgency
                    existing.sources.extend(new_obs.sources)
                    existing.urgency = max(existing.urgency, new_obs.urgency)
                    return
            # Not merged, store as new distinct observation
            self.observations.append(new_obs)


class HierarchicalGeoStore:
    """
    Maintains multiple radii bins for each location.
    Example radii: 0.1 km, 1 km, 10 km
    """
    
    def __init__(self, radius_levels: List[float] = None):
        self.radius_levels = radius_levels or [0.1, 1.0, 10.0]  # in km
        self.bins: Dict[Tuple[float, float, float], GeoBin] = {}
        self.lock = threading.Lock()
    
    def _get_bin_keys(self, lat: float, lon: float) -> List[Tuple[float, float, float]]:
        """
        For a given lat, lon, produce a list of bin-keys that point to
        hierarchical radius coverage.
        """
        keys = []
        for r in self.radius_levels:
            # Round to reduce collisions and group nearby points
            keys.append((round(lat, 3), round(lon, 3), r))
        return keys
    
    def add_observation(self, lat: float, lon: float, obs: Observation):
        """
        Place the observation into each relevant bin for lat/lon across radius_levels.
        """
        with self.lock:
            bin_keys = self._get_bin_keys(lat, lon)
            for bk in bin_keys:
                if bk not in self.bins:
                    self.bins[bk] = GeoBin()
                self.bins[bk].merge_or_add_observation(obs)
    
    def query_bins(self) -> Dict[Tuple[float, float, float], List[Observation]]:
        """Return a snapshot of all bin data."""
        with self.lock:
            result = {}
            for k, geo_bin in self.bins.items():
                with geo_bin.lock:
                    result[k] = list(geo_bin.observations)
            return result
    
    def query_nearby(self, lat: float, lon: float, radius_km: float = 1.0) -> List[Dict]:
        """
        Query observations near a specific location.
        Returns observations from bins that fall within the radius.
        """
        results = []
        with self.lock:
            for (bin_lat, bin_lon, bin_radius), geo_bin in self.bins.items():
                dist = haversine_distance(lat, lon, bin_lat, bin_lon)
                if dist <= radius_km:
                    with geo_bin.lock:
                        for obs in geo_bin.observations:
                            results.append({
                                "bin_center": {"lat": bin_lat, "lon": bin_lon},
                                "bin_radius_km": bin_radius,
                                "distance_km": round(dist, 3),
                                "observation": obs.to_dict(),
                            })
        return results


class VideoAnalyzer:
    """
    Coordinates the ingestion of a video stream, calling MoonDream on each frame,
    extracting environment info, and updating the HierarchicalGeoStore.
    """
    
    def __init__(self, model_path: str = "moondream-0_5b-int8.mf"):
        self.model_path = model_path
        self.model = None
        self.geo_store = HierarchicalGeoStore()
        self._model_loaded = False
        
        if MOONDREAM_AVAILABLE:
            try:
                self.model = md.vl(model=model_path)
                self._model_loaded = True
            except Exception as e:
                print(f"Warning: Could not load MoonDream model: {e}")
                print("Running in fallback mode without vision analysis.")
    
    @property
    def is_available(self) -> bool:
        return self._model_loaded
    
    def process_frame(
        self,
        frame_id: int,
        image_path: str,
        lat: float,
        lon: float,
        timestamp: float = None,
    ) -> Optional[Dict]:
        """
        Process a single frame:
        1) Use MoonDream to get environment data
        2) Create an Observation
        3) Insert into geo_store
        
        Returns the observation data or None if processing failed.
        """
        if timestamp is None:
            timestamp = time.time()
        
        if not self._model_loaded:
            # Fallback: create a placeholder observation
            observation = Observation(
                environment="[Vision model not available - placeholder observation]",
                urgency=3,
                sources=[{
                    "time": timestamp,
                    "lat": lat,
                    "lon": lon,
                    "frame_id": frame_id,
                }]
            )
            self.geo_store.add_observation(lat, lon, observation)
            return observation.to_dict()
        
        try:
            # Load and encode image
            image = Image.open(image_path)
            encoded_image = self.model.encode_image(image)
            
            # Query the model for scene description
            response = self.model.query(
                encoded_image,
                "Concisely describe what hazards, obstacles, or accessibility issues you see in this image. Focus on: sidewalk conditions, obstacles, construction, flooding, poor lighting, or crowd density."
            )
            
            description = response.get("answer", str(response))
            
            # Estimate urgency based on keywords
            urgency = self._estimate_urgency(description)
            
            # Create observation
            observation = Observation(
                environment=description,
                urgency=urgency,
                sources=[{
                    "time": timestamp,
                    "lat": lat,
                    "lon": lon,
                    "frame_id": frame_id,
                }]
            )
            
            # Store in geo store
            self.geo_store.add_observation(lat, lon, observation)
            
            return observation.to_dict()
            
        except Exception as e:
            print(f"Error processing frame {frame_id}: {e}")
            return None
    
    def _estimate_urgency(self, description: str) -> int:
        """
        Estimate urgency level (1-5) based on description keywords.
        Enhanced detection for better obstacle recognition.
        """
        description_lower = description.lower()
        
        # Critical (5): Immediate life-threatening danger
        critical_keywords = [
            "fire", "flood", "collapse", "emergency", "danger", "hazardous",
            "moving vehicle", "approaching car", "oncoming", "reversing",
            "open hole", "deep pit", "cliff", "drop-off", "ledge",
            "electric", "exposed wire", "gas leak"
        ]
        if any(word in description_lower for word in critical_keywords):
            return 5
        
        # High (4): Significant hazard requiring immediate action
        high_keywords = [
            "blocked", "construction", "deep pothole", "missing ramp", "broken",
            "stairs", "steps down", "steps up", "steep", "curb",
            "glass door", "automatic door", "revolving door",
            "cyclist approaching", "scooter", "e-scooter", "bike coming",
            "running", "fast", "collision course",
            "open manhole", "trench", "excavation",
            "stop", "halt", "wait"
        ]
        if any(word in description_lower for word in high_keywords):
            return 4
        
        # Medium (3): Moderate concern requiring attention
        medium_keywords = [
            "pothole", "crack", "uneven", "crowded", "debris",
            "puddle", "wet", "slippery", "ice", "mud",
            "person ahead", "pedestrian", "walker", "group",
            "obstacle", "obstruction", "blocking",
            "pole", "sign", "bench", "planter", "bin", "trash",
            "branch", "tree", "overhang", "low hanging",
            "dog", "animal", "pet",
            "narrow", "tight", "restricted",
            "crossing", "intersection", "junction",
            "ramp", "slope", "incline"
        ]
        if any(word in description_lower for word in medium_keywords):
            return 3
        
        # Low (2): Minor issue, awareness only
        low_keywords = [
            "minor", "small", "slight", "damp", "leaves",
            "distant", "far", "parked", "stationary",
            "clear path", "open space", "wide",
            "person far", "walking away", "moving away"
        ]
        if any(word in description_lower for word in low_keywords):
            return 2
        
        # Minimal (1): General observation, no concern
        return 1
    
    def process_video(self, frames: List[Dict[str, Any]], max_workers: int = 4) -> List[Dict]:
        """
        Process multiple frames in parallel.
        
        Args:
            frames: List of dicts with keys: frame_id, path, lat, lon, time
            max_workers: Number of parallel threads
        
        Returns:
            List of observation results
        """
        results = []
        
        with ThreadPoolExecutor(max_workers=max_workers) as executor:
            futures = []
            for f in frames:
                future = executor.submit(
                    self.process_frame,
                    f["frame_id"],
                    f["path"],
                    f["lat"],
                    f["lon"],
                    f.get("time", time.time()),
                )
                futures.append(future)
            
            for future in futures:
                result = future.result()
                if result:
                    results.append(result)
        
        return results
    
    def get_geo_snapshot(self) -> Dict:
        """
        Get a snapshot of the entire hierarchical store.
        Returns dict with bin keys and their observations.
        """
        raw_data = self.geo_store.query_bins()
        
        # Convert to JSON-serializable format
        result = {}
        for (lat, lon, radius), observations in raw_data.items():
            key = f"{lat},{lon},{radius}"
            result[key] = [obs.to_dict() for obs in observations]
        
        return result
    
    def query_nearby(self, lat: float, lon: float, radius_km: float = 1.0) -> List[Dict]:
        """Query observations near a specific location."""
        return self.geo_store.query_nearby(lat, lon, radius_km)


# Global analyzer instance (lazy initialization)
_analyzer_instance: Optional[VideoAnalyzer] = None


def get_video_analyzer() -> VideoAnalyzer:
    """Get or create the global video analyzer instance."""
    global _analyzer_instance
    if _analyzer_instance is None:
        _analyzer_instance = VideoAnalyzer()
    return _analyzer_instance
