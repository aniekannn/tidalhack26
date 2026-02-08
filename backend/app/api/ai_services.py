"""
HorizonX — AI Services API

Cloud-enhanced AI endpoints (optional, non-blocking):
  - Gemini scene reasoning enhancement
  - Gemini Vision for real-time obstacle detection
  - ElevenLabs TTS generation
  - Hazard classification assistance
  - Training data collection for model improvement
"""

import os
import base64
import json
import time
import uuid
from datetime import datetime
from typing import Optional, List
from pathlib import Path

from fastapi import APIRouter, HTTPException
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, Field

# Gemini API
import google.generativeai as genai

# Eleven Labs API
from elevenlabs.client import ElevenLabs

router = APIRouter()

# Configure APIs from environment
GEMINI_API_KEY = os.environ.get("GEMINI_API_KEY", "")
ELEVENLABS_API_KEY = os.environ.get("ELEVENLABS_API_KEY", "")

# Training data directory
TRAINING_DATA_DIR = Path("training_data")
TRAINING_DATA_DIR.mkdir(exist_ok=True)

if GEMINI_API_KEY:
    genai.configure(api_key=GEMINI_API_KEY)

if ELEVENLABS_API_KEY:
    eleven_client = ElevenLabs(api_key=ELEVENLABS_API_KEY)
else:
    eleven_client = None


# ─── Request/Response Models ─────────────────────────────────────────────────

class SceneEnhancementRequest(BaseModel):
    """Request for Gemini-enhanced scene description."""
    base_description: str = Field(
        ..., max_length=500,
        description="On-device VLM description (text only, no images)"
    )
    activity_context: str = Field(
        default="walking",
        description="User's current activity"
    )
    time_of_day: str = Field(
        default="daytime",
        description="Ambient lighting context"
    )


class SceneEnhancementResponse(BaseModel):
    enhanced_description: str
    navigation_suggestion: str
    confidence: float
    latency_ms: int


class TTSRequest(BaseModel):
    """Request for ElevenLabs TTS generation."""
    text: str = Field(..., max_length=500)
    priority: str = Field(default="ambient", pattern="^(immediate|soon|ambient)$")
    voice_id: str = Field(default="aria")


class TTSResponse(BaseModel):
    audio_url: str
    duration_seconds: float
    latency_ms: int


class HazardClassifyRequest(BaseModel):
    """Request AI-assisted hazard classification."""
    scene_description: str = Field(..., max_length=500)
    location_context: str = Field(default="")


class HazardClassifyResponse(BaseModel):
    hazard_type: str
    severity: str
    description: str
    confidence: float
    context_tags: list[str]


class ObstacleData(BaseModel):
    """Single obstacle detected in scene."""
    type: str = Field(..., description="vehicle|person|object|terrain|construction|debris|barrier")
    description: str
    direction: int = Field(..., ge=1, le=12, description="Clock direction 1-12")
    distance_meters: float
    moving: bool
    approach_direction: str = Field(..., description="towards|away|crossing|stationary")
    urgency: str = Field(..., description="immediate|soon|ambient")


class NavigationCommand(BaseModel):
    """Navigation instruction for the user."""
    action: str = Field(..., description="walk_straight|stop|turn_left|turn_right|stay_left|stay_right|slow_down|step_over|duck")
    reason: str
    urgency: str = Field(default="ambient", description="immediate|soon|ambient")
    distance_meters: Optional[float] = None


class VisionAnalysisRequest(BaseModel):
    """Request for real-time vision analysis with navigation."""
    image_base64: str = Field(..., description="Base64-encoded JPEG image")
    context: str = Field(default="outdoor_walking", description="User activity context")
    include_navigation: bool = Field(default=True)


class VisionAnalysisResponse(BaseModel):
    """Complete scene analysis with obstacles and navigation."""
    narration: str
    obstacles: list[ObstacleData]
    navigation_command: NavigationCommand
    path_clear: bool
    confidence: float
    latency_ms: int


# ─── Vision Prompts ───────────────────────────────────────────────────────────

OBSTACLE_DETECTION_PROMPT = """You are a CRITICAL SAFETY navigation assistant for a BLIND person walking. Your analysis directly affects their safety. Be thorough and accurate.

=== DETECTION PRIORITY (in order) ===
1. GROUND-LEVEL HAZARDS (highest priority - can cause falls)
2. MOVING OBJECTS (collision risk)
3. PATH OBSTRUCTIONS (blocking movement)
4. OVERHEAD HAZARDS (head injury risk)
5. ENVIRONMENTAL CONTEXT (terrain changes)

=== DETAILED OBSTACLE CATEGORIES ===

🚶 PEOPLE (type: "person"):
- Single pedestrians walking/standing/sitting
- Groups of people (estimate count)
- People with mobility aids (wheelchairs, walkers, canes)
- People with strollers or carts
- Joggers/runners (faster approach)
- Children (unpredictable movement)
- People on phones (may not notice user)
- Service workers (delivery, maintenance)

🚗 VEHICLES (type: "vehicle"):
- Moving cars, trucks, buses
- Parked vehicles extending onto path
- Motorcycles and scooters
- Bicycles (pedal and electric)
- E-scooters (often silent)
- Golf carts, mobility scooters
- Delivery robots
- Reversing vehicles (CRITICAL - check brake lights)
- Vehicles with running engines near path
- Opening car doors

🕳️ GROUND HAZARDS (type: "terrain") - CRITICAL FOR FALLS:
- Potholes (estimate depth: shallow <5cm, medium 5-15cm, deep >15cm)
- Cracks in pavement (width matters)
- Raised or sunken sections
- Tree roots lifting pavement
- Loose gravel or stones
- Sand or dirt patches on hard surface
- Wet surfaces / puddles (slip hazard)
- Ice patches (if visible)
- Grates and drainage covers
- Uneven brick or cobblestone
- Transition between surfaces (concrete to grass, etc.)
- CURBS and STEPS (count steps if visible)
- Ramps and slopes (estimate grade)
- Drop-offs and edges
- Speed bumps

🚧 CONSTRUCTION/TEMPORARY (type: "construction"):
- Scaffolding
- Barriers and fencing
- Cones and pylons
- Caution tape
- Open trenches or holes
- Exposed wiring or pipes
- Wet concrete or paint
- Temporary walkway changes
- Work zone signage

🗑️ FIXED OBJECTS (type: "object"):
- Poles (light, sign, utility)
- Fire hydrants
- Bollards
- Trash bins and recycling
- Benches and seating
- Planters and flower boxes
- Bike racks
- Newspaper boxes
- Mailboxes
- Parking meters
- A-frame signs (restaurant, store)
- Outdoor dining furniture
- Vending machines

🌳 OVERHEAD HAZARDS (type: "barrier"):
- Low-hanging branches
- Awnings and canopies
- Scaffolding at head height
- Signs protruding from walls
- Open windows at head level
- Hanging banners
- Garage doors partially open

🚪 INVISIBLE/TRANSPARENT HAZARDS (CRITICAL):
- Glass doors (especially automatic)
- Glass walls and partitions
- Mirrors
- Revolving doors
- Screen doors

🐕 ANIMALS (type: "object"):
- Dogs (on leash or loose)
- Cats
- Birds on ground
- Squirrels, pigeons

📦 DEBRIS (type: "debris"):
- Fallen branches
- Litter accumulation
- Spilled items
- Broken glass
- Wet leaves (slip hazard)

=== DISTANCE ESTIMATION GUIDE ===
- Person height ≈ 1.7m (use as reference)
- Car length ≈ 4.5m
- Standard door width ≈ 0.9m
- Sidewalk width ≈ 1.5-2m
- Parking space ≈ 2.5m wide, 5m long
- Fire hydrant height ≈ 0.6m
- BE CONSERVATIVE: When uncertain, report CLOSER distance for safety

=== CLOCK POSITION RULES ===
- 12 o'clock = directly ahead
- 3 o'clock = 90° to the right
- 9 o'clock = 90° to the left  
- 6 o'clock = behind (rarely relevant)
- Use half positions for precision: 1:30, 10:30, etc. (report as nearest integer)

=== URGENCY CLASSIFICATION ===
- IMMEDIATE (red): <2 meters, requires action NOW
  Examples: moving vehicle, open hole, person about to collide
- SOON (yellow): 2-5 meters, prepare to act
  Examples: construction ahead, crowd forming, curb approaching
- AMBIENT (green): >5 meters, awareness only
  Examples: distant pedestrians, parked cars, general environment

=== NAVIGATION COMMANDS ===
- "stop" - IMMEDIATE danger, halt movement
- "walk_straight" - Path clear, proceed normally
- "slow_down" - Caution needed, reduce speed
- "stay_left" - Move to/maintain left side
- "stay_right" - Move to/maintain right side
- "turn_left" - Make left turn to avoid
- "turn_right" - Make right turn to avoid
- "step_over" - Small ground obstacle (<30cm)
- "duck" - Overhead hazard at head height

=== OUTPUT FORMAT ===
Return ONLY valid JSON (no markdown, no explanation):
{
  "narration": "15 words max. Start with path status.",
  "obstacles": [
    {
      "type": "vehicle|person|object|terrain|construction|debris|barrier",
      "description": "Specific, short description",
      "direction": 1-12,
      "distance_meters": 0.5-50.0,
      "moving": true|false,
      "approach_direction": "towards|away|crossing|stationary",
      "urgency": "immediate|soon|ambient"
    }
  ],
  "navigation_command": {
    "action": "walk_straight|stop|turn_left|turn_right|stay_left|stay_right|slow_down|step_over|duck",
    "reason": "Concise reason (max 10 words)",
    "urgency": "immediate|soon|ambient",
    "distance_meters": number
  },
  "path_clear": true|false,
  "confidence": 0.0-1.0
}

=== CRITICAL REMINDERS ===
1. When in doubt, WARN. False positives are safer than missed hazards.
2. Ground-level obstacles are MOST DANGEROUS - check pavement carefully.
3. Moving objects need EARLIER warning due to approach time.
4. Glass/transparent surfaces are often invisible - look for frames, reflections.
5. Multiple hazards: Report all, but navigation command handles the most urgent.
6. If scene is unclear/blurry, report confidence < 0.5 and suggest slowing down.
7. ALWAYS detect at least one thing - even "clear path" should be noted.
8. Check ALL areas: ground, eye level, overhead, left, right, and ahead.

=== FEW-SHOT EXAMPLES ===

Example 1 - Sidewalk with pedestrian:
Input: Image of outdoor sidewalk with person walking ahead
Output:
{"narration": "Person walking ahead on sidewalk. Path clear on right side.", "obstacles": [{"type": "person", "description": "Adult walking same direction", "direction": 12, "distance_meters": 4.0, "moving": true, "approach_direction": "away", "urgency": "ambient"}], "navigation_command": {"action": "walk_straight", "reason": "Person ahead moving away", "urgency": "ambient", "distance_meters": 4.0}, "path_clear": true, "confidence": 0.92}

Example 2 - Street crossing:
Input: Image of intersection with crosswalk
Output:
{"narration": "Intersection ahead. Car waiting at light on left.", "obstacles": [{"type": "vehicle", "description": "Car stopped at traffic light", "direction": 10, "distance_meters": 6.0, "moving": false, "approach_direction": "stationary", "urgency": "ambient"}, {"type": "terrain", "description": "Curb step down to crosswalk", "direction": 12, "distance_meters": 2.0, "moving": false, "approach_direction": "stationary", "urgency": "soon"}], "navigation_command": {"action": "slow_down", "reason": "Curb ahead, step down", "urgency": "soon", "distance_meters": 2.0}, "path_clear": false, "confidence": 0.88}

Example 3 - Indoor hallway:
Input: Image of building corridor with door
Output:
{"narration": "Indoor hallway. Glass door ahead, trash bin on right.", "obstacles": [{"type": "barrier", "description": "Glass door with metal frame", "direction": 12, "distance_meters": 5.0, "moving": false, "approach_direction": "stationary", "urgency": "soon"}, {"type": "object", "description": "Trash bin", "direction": 2, "distance_meters": 3.0, "moving": false, "approach_direction": "stationary", "urgency": "ambient"}], "navigation_command": {"action": "walk_straight", "reason": "Glass door ahead, extend hand", "urgency": "soon", "distance_meters": 5.0}, "path_clear": false, "confidence": 0.85}

Example 4 - Clear path:
Input: Image of empty sidewalk
Output:
{"narration": "Clear sidewalk ahead. Good pavement condition.", "obstacles": [], "navigation_command": {"action": "walk_straight", "reason": "Path is clear", "urgency": "ambient", "distance_meters": null}, "path_clear": true, "confidence": 0.95}

Example 5 - Immediate danger:
Input: Image with cyclist approaching fast
Output:
{"narration": "Cyclist approaching fast from left! Move right immediately.", "obstacles": [{"type": "vehicle", "description": "Cyclist approaching quickly", "direction": 9, "distance_meters": 3.0, "moving": true, "approach_direction": "towards", "urgency": "immediate"}], "navigation_command": {"action": "stay_right", "reason": "Cyclist approaching from left", "urgency": "immediate", "distance_meters": 3.0}, "path_clear": false, "confidence": 0.93}

Now analyze the provided image following these examples. Return ONLY valid JSON."""


# ─── Endpoints ────────────────────────────────────────────────────────────────

@router.post("/enhance-scene", response_model=SceneEnhancementResponse)
async def enhance_scene_description(request: SceneEnhancementRequest):
    """
    Enhance an on-device scene description using Gemini.
    
    PRIVACY NOTE:
    - Only receives TEXT descriptions, never raw images
    - The on-device VLM processes images locally
    - This endpoint only refines the text output
    """
    start = time.time()
    
    if GEMINI_API_KEY:
        try:
            model = genai.GenerativeModel("gemini-2.0-flash")
            
            prompt = f"""You are a navigation assistant for visually impaired users.
            
On-device description: "{request.base_description}"
User's current activity: {request.activity_context}
Time of day: {request.time_of_day}

Enhance this description with:
1. Spatial reasoning (relative positions, layout)
2. Social context (is this a queue? restaurant? park?)
3. Optimal navigation path suggestion
4. Any hazards the basic description may have missed

Return JSON:
{{
  "enhanced_description": "Enhanced description (max 50 words)",
  "navigation_suggestion": "Clear action instruction"
}}"""
            
            response = model.generate_content(prompt)
            result_text = response.text
            
            # Parse JSON from response
            if "```json" in result_text:
                result_text = result_text.split("```json")[1].split("```")[0]
            elif "```" in result_text:
                result_text = result_text.split("```")[1].split("```")[0]
            
            result = json.loads(result_text.strip())
            latency = int((time.time() - start) * 1000)
            
            return SceneEnhancementResponse(
                enhanced_description=result.get("enhanced_description", request.base_description),
                navigation_suggestion=result.get("navigation_suggestion", "Proceed with caution"),
                confidence=0.92,
                latency_ms=latency,
            )
        except Exception as e:
            print(f"Gemini API error: {e}")
            # Fall through to mock
    
    # Fallback mock
    enhanced = _mock_enhance(request.base_description, request.activity_context)
    latency = int((time.time() - start) * 1000)
    
    return SceneEnhancementResponse(
        enhanced_description=enhanced["description"],
        navigation_suggestion=enhanced["suggestion"],
        confidence=0.89,
        latency_ms=latency,
    )


@router.post("/tts", response_model=TTSResponse)
async def generate_speech(request: TTSRequest):
    """
    Generate natural speech audio using ElevenLabs.
    
    Used when device is online and user opts into enhanced voice.
    Falls back to device native TTS when offline.
    """
    start = time.time()
    
    if eleven_client and ELEVENLABS_API_KEY:
        try:
            # Generate audio using ElevenLabs with raw response for headers
            response = eleven_client.text_to_speech.with_raw_response.convert(
                text=request.text,
                voice_id=request.voice_id or "pFZP5JQG7iQjIQuC4Bku",  # Lily voice (calm, clear)
                model_id="eleven_turbo_v2_5",
                output_format="mp3_22050_32",
            )
            
            # Access character cost and request ID from headers
            char_cost = response.headers.get("x-character-count")
            request_id = response.headers.get("request-id")
            
            # Get audio data from response
            audio_bytes = response.data
            
            # If audio_bytes is a generator, collect it
            if hasattr(audio_bytes, '__iter__') and not isinstance(audio_bytes, bytes):
                audio_bytes = b"".join(audio_bytes)
            
            latency = int((time.time() - start) * 1000)
            
            # Log usage for tracking
            if char_cost:
                print(f"ElevenLabs TTS: {char_cost} characters used (request: {request_id})")
            
            # Store temporarily and return URL
            audio_hash = abs(hash(request.text)) % (10 ** 10)
            audio_path = f"/tmp/tts_{audio_hash}.mp3"
            
            with open(audio_path, "wb") as f:
                f.write(audio_bytes)
            
            # Estimate duration (mp3 at 22050Hz, 32kbps)
            duration = len(audio_bytes) / (32000 / 8)
            
            return TTSResponse(
                audio_url=f"/api/v1/ai/tts-audio/{audio_hash}",
                duration_seconds=duration,
                latency_ms=latency,
            )
        except Exception as e:
            print(f"ElevenLabs API error: {e}")
            # Fall through to mock
    
    latency = int((time.time() - start) * 1000)
    
    # Mock response for offline/fallback
    return TTSResponse(
        audio_url=f"/static/tts/{hash(request.text)}.mp3",
        duration_seconds=len(request.text) * 0.06,
        latency_ms=latency,
    )


@router.get("/tts-audio/{audio_hash}")
async def get_tts_audio(audio_hash: str):
    """Serve generated TTS audio file."""
    audio_path = f"/tmp/tts_{audio_hash}.mp3"
    
    if not os.path.exists(audio_path):
        raise HTTPException(status_code=404, detail="Audio not found")
    
    def iterfile():
        with open(audio_path, "rb") as f:
            yield from f
    
    return StreamingResponse(iterfile(), media_type="audio/mpeg")


@router.post("/tts-stream")
async def generate_speech_stream(request: TTSRequest):
    """
    Generate and stream speech audio using ElevenLabs.
    
    Uses streaming API for lower latency - audio chunks are sent
    as they're generated, enabling faster playback start.
    """
    if not eleven_client or not ELEVENLABS_API_KEY:
        raise HTTPException(
            status_code=503,
            detail="ElevenLabs API not configured"
        )
    
    try:
        # Use streaming endpoint for real-time audio
        audio_stream = eleven_client.text_to_speech.stream(
            text=request.text,
            voice_id=request.voice_id or "pFZP5JQG7iQjIQuC4Bku",  # Lily voice
            model_id="eleven_turbo_v2_5",
            output_format="mp3_22050_32",
        )
        
        def generate():
            for chunk in audio_stream:
                if isinstance(chunk, bytes):
                    yield chunk
        
        return StreamingResponse(
            generate(),
            media_type="audio/mpeg",
            headers={
                "Content-Disposition": "inline",
                "Cache-Control": "no-cache",
            }
        )
    except Exception as e:
        print(f"ElevenLabs streaming error: {e}")
        raise HTTPException(status_code=500, detail=f"TTS streaming failed: {str(e)}")


@router.post("/classify-hazard", response_model=HazardClassifyResponse)
async def classify_hazard(request: HazardClassifyRequest):
    """
    AI-assisted hazard classification from scene description.
    Helps standardize reports for civic analysis.
    """
    # Mock classification — in production uses Gemini
    classification = _mock_classify(request.scene_description)
    
    return HazardClassifyResponse(**classification)


@router.post("/analyze-scene", response_model=VisionAnalysisResponse)
async def analyze_scene(request: VisionAnalysisRequest):
    """
    Real-time vision analysis for obstacle detection and navigation.
    
    Uses Gemini Vision API to analyze camera frames and provide:
    - Obstacle detection with positions and urgency
    - Navigation commands (walk straight, stop, turn, etc.)
    - Path clearance status
    
    This is the PRIMARY endpoint for real-time navigation assistance.
    """
    start = time.time()
    
    if not GEMINI_API_KEY:
        raise HTTPException(
            status_code=503,
            detail="Gemini API not configured. Set GEMINI_API_KEY environment variable."
        )
    
    try:
        # Decode base64 image
        image_bytes = base64.b64decode(request.image_base64)
        
        # Create Gemini Vision model
        model = genai.GenerativeModel("gemini-2.0-flash")
        
        # Prepare image for Gemini
        image_part = {
            "mime_type": "image/jpeg",
            "data": image_bytes
        }
        
        # Build context-aware prompt
        context_info = ""
        context_additions = ""
        
        if request.context == "outdoor_walking":
            context_info = "User is walking outdoors on a sidewalk or path."
            context_additions = """
OUTDOOR WALKING FOCUS:
- Pay extra attention to: curbs, street crossings, vehicles, cyclists, construction
- Check for: uneven pavement, puddles, tree roots, street furniture
- Watch for: opening car doors, delivery vehicles, reversing cars"""
            
        elif request.context == "indoor":
            context_info = "User is indoors, navigating a building."
            context_additions = """
INDOOR FOCUS:
- Pay extra attention to: doors (especially glass), stairs, elevators, wet floors
- Check for: furniture, columns, people walking, carts, cleaning equipment
- Watch for: automatic doors, revolving doors, threshold changes"""
            
        elif request.context == "crossing":
            context_info = "User is at or approaching a street crossing."
            context_additions = """
CROSSING FOCUS - CRITICAL SAFETY:
- PRIORITY: Vehicle detection in all directions
- Check for: turning vehicles, cyclists running lights, pedestrian signals
- Watch for: traffic light status, walk signals, crossing button location
- Alert for: vehicles not stopping, bikes in crosswalk, right-turn-on-red vehicles"""
            
        elif request.context == "stairs":
            context_info = "User is near stairs or elevation changes."
            context_additions = """
STAIRS FOCUS:
- Count steps if visible (up or down)
- Check for: handrail location (left or right), step condition
- Watch for: uneven steps, wet surfaces, objects on stairs
- Alert for: people on stairs, end of staircase approaching"""
            
        elif request.context == "transit":
            context_info = "User is using public transit (bus stop, train station)."
            context_additions = """
TRANSIT FOCUS:
- Check for: platform edges, gaps between train and platform, arriving vehicles
- Watch for: crowds, luggage, moving vehicles (buses, trains)
- Alert for: doors opening/closing, departure announcements (if signs visible)"""
            
        elif request.context == "shopping":
            context_info = "User is in a store or shopping area."
            context_additions = """
SHOPPING FOCUS:
- Check for: shopping carts, store displays, checkout lanes
- Watch for: spills, product on floor, narrow aisles
- Alert for: other shoppers with carts, staff restocking shelves"""
        
        full_prompt = f"{OBSTACLE_DETECTION_PROMPT}\n\nContext: {context_info}{context_additions}"
        
        print(f"[VisionAnalysis] Processing image ({len(request.image_base64)} chars base64)")
        print(f"[VisionAnalysis] Context: {request.context}")
        
        # Call Gemini Vision with safety settings to ensure we get useful output
        generation_config = genai.GenerationConfig(
            temperature=0.1,  # Low temperature for consistent, reliable detection
            top_p=0.95,
            max_output_tokens=2048,
        )
        
        response = model.generate_content(
            [full_prompt, image_part],
            generation_config=generation_config
        )
        result_text = response.text
        
        print(f"[VisionAnalysis] Raw response length: {len(result_text)} chars")
        print(f"[VisionAnalysis] Response preview: {result_text[:500]}...")
        
        # Parse JSON from response
        if "```json" in result_text:
            result_text = result_text.split("```json")[1].split("```")[0]
        elif "```" in result_text:
            result_text = result_text.split("```")[1].split("```")[0]
        
        result = json.loads(result_text.strip())
        
        latency = int((time.time() - start) * 1000)
        print(f"[VisionAnalysis] Parsed successfully in {latency}ms")
        print(f"[VisionAnalysis] Found {len(result.get('obstacles', []))} obstacles")
        
        # Build response with validated data
        obstacles = []
        for obs in result.get("obstacles", []):
            try:
                obstacles.append(ObstacleData(
                    type=obs.get("type", "object"),
                    description=obs.get("description", "Unknown obstacle"),
                    direction=int(obs.get("direction", 12)),
                    distance_meters=float(obs.get("distance_meters", 5.0)),
                    moving=bool(obs.get("moving", False)),
                    approach_direction=obs.get("approach_direction", "stationary"),
                    urgency=obs.get("urgency", "ambient")
                ))
            except (ValueError, KeyError) as e:
                print(f"Skipping invalid obstacle: {e}")
                continue
        
        nav_cmd = result.get("navigation_command", {})
        navigation_command = NavigationCommand(
            action=nav_cmd.get("action", "walk_straight"),
            reason=nav_cmd.get("reason", "Path appears clear"),
            urgency=nav_cmd.get("urgency", "ambient"),
            distance_meters=nav_cmd.get("distance_meters")
        )
        
        return VisionAnalysisResponse(
            narration=result.get("narration", "Processing scene..."),
            obstacles=obstacles,
            navigation_command=navigation_command,
            path_clear=result.get("path_clear", True),
            confidence=float(result.get("confidence", 0.8)),
            latency_ms=latency
        )
        
    except json.JSONDecodeError as e:
        print(f"JSON parse error: {e}, raw response: {result_text[:1000]}")
        latency = int((time.time() - start) * 1000)
        
        # Try to extract any useful info from the raw response
        narration = "Scene analysis incomplete. Proceed with caution."
        if result_text:
            # Try to find any text description in the response
            import re
            text_match = re.search(r'["\']narration["\']\s*:\s*["\']([^"\']+)["\']', result_text)
            if text_match:
                narration = text_match.group(1)
        
        # Return safe default with generic obstacle warning
        return VisionAnalysisResponse(
            narration=narration,
            obstacles=[
                ObstacleData(
                    type="object",
                    description="Unknown obstacle - analysis incomplete",
                    direction=12,
                    distance_meters=3.0,
                    moving=False,
                    approach_direction="stationary",
                    urgency="soon"
                )
            ],
            navigation_command=NavigationCommand(
                action="slow_down",
                reason="Scene analysis incomplete, proceed carefully",
                urgency="soon",
                distance_meters=3.0
            ),
            path_clear=False,
            confidence=0.3,
            latency_ms=latency
        )
        
    except Exception as e:
        print(f"Vision analysis error: {type(e).__name__}: {e}")
        import traceback
        traceback.print_exc()
        
        latency = int((time.time() - start) * 1000)
        
        # Return a cautious fallback instead of raising an error
        return VisionAnalysisResponse(
            narration="Vision service error. Use extra caution.",
            obstacles=[
                ObstacleData(
                    type="object",
                    description="Service error - obstacles unknown",
                    direction=12,
                    distance_meters=2.0,
                    moving=False,
                    approach_direction="stationary",
                    urgency="immediate"
                )
            ],
            navigation_command=NavigationCommand(
                action="slow_down",
                reason="Vision service error",
                urgency="immediate",
                distance_meters=2.0
            ),
            path_clear=False,
            confidence=0.1,
            latency_ms=latency
        )


# ─── Mock Helpers (replace with real API calls) ───────────────────────────────

def _mock_enhance(base: str, context: str) -> dict:
    """Simulate Gemini scene enhancement."""
    enhancements = {
        "walking": {
            "description": f"{base} The area appears to be a pedestrian zone. "
                          "Foot traffic is moderate with clear lanes for walking.",
            "suggestion": "Continue straight. Path is generally clear with good visibility.",
        },
        "crossing": {
            "description": f"{base} This is an intersection with marked crosswalks. "
                          "Traffic signals are visible.",
            "suggestion": "Wait for the walk signal before crossing. Listen for turning vehicles.",
        },
    }
    return enhancements.get(context, {
        "description": f"{base} Clear environment with standard urban features.",
        "suggestion": "Proceed with normal caution.",
    })


def _mock_classify(description: str) -> dict:
    """Simulate hazard classification."""
    desc_lower = description.lower()
    
    if "pothole" in desc_lower or "hole" in desc_lower:
        return {
            "hazard_type": "pothole",
            "severity": "medium",
            "description": "Surface damage on walkway requiring repair",
            "confidence": 0.87,
            "context_tags": ["pedestrian_path"],
        }
    elif "blocked" in desc_lower or "construction" in desc_lower:
        return {
            "hazard_type": "blocked_sidewalk",
            "severity": "high",
            "description": "Sidewalk obstruction forcing pedestrians into roadway",
            "confidence": 0.82,
            "context_tags": ["construction_zone"],
        }
    else:
        return {
            "hazard_type": "other",
            "severity": "low",
            "description": "Reported infrastructure issue requiring assessment",
            "confidence": 0.60,
            "context_tags": [],
        }


# ─── Training Data Collection ─────────────────────────────────────────────────

class TrainingFeedback(BaseModel):
    """User feedback on detection accuracy."""
    feedback_type: str = Field(
        ..., 
        description="correct|missed_obstacle|false_positive|wrong_type|wrong_distance"
    )
    original_detection: Optional[dict] = Field(
        default=None,
        description="The original obstacle detection that was wrong"
    )
    corrected_obstacle: Optional[dict] = Field(
        default=None,
        description="The corrected obstacle data from user"
    )
    notes: Optional[str] = Field(default=None, max_length=500)


class TrainingDataSubmission(BaseModel):
    """Submit a training sample for model improvement."""
    image_base64: str = Field(..., description="Base64-encoded image")
    detected_obstacles: List[dict] = Field(
        default=[],
        description="What the model detected"
    )
    user_feedback: TrainingFeedback
    context: str = Field(default="outdoor_walking")
    latitude: Optional[float] = None
    longitude: Optional[float] = None


class TrainingDataResponse(BaseModel):
    """Response after submitting training data."""
    sample_id: str
    message: str
    total_samples: int


@router.post("/training/submit", response_model=TrainingDataResponse)
async def submit_training_data(submission: TrainingDataSubmission):
    """
    Submit a training sample to improve obstacle detection.
    
    Users can report:
    - "correct": Detection was accurate (positive sample)
    - "missed_obstacle": Model didn't detect something (add ground truth)
    - "false_positive": Model detected something that wasn't there
    - "wrong_type": Obstacle type was incorrect
    - "wrong_distance": Distance estimation was wrong
    
    This data is stored for periodic model fine-tuning.
    """
    sample_id = str(uuid.uuid4())[:8]
    timestamp = datetime.utcnow().isoformat()
    
    # Create sample directory
    sample_dir = TRAINING_DATA_DIR / sample_id
    sample_dir.mkdir(exist_ok=True)
    
    # Save image
    try:
        image_data = base64.b64decode(submission.image_base64)
        image_path = sample_dir / "image.jpg"
        with open(image_path, "wb") as f:
            f.write(image_data)
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"Invalid image data: {e}")
    
    # Save metadata
    metadata = {
        "sample_id": sample_id,
        "timestamp": timestamp,
        "context": submission.context,
        "detected_obstacles": submission.detected_obstacles,
        "user_feedback": submission.user_feedback.dict(),
        "location": {
            "latitude": submission.latitude,
            "longitude": submission.longitude
        } if submission.latitude and submission.longitude else None
    }
    
    metadata_path = sample_dir / "metadata.json"
    with open(metadata_path, "w") as f:
        json.dump(metadata, f, indent=2)
    
    # Count total samples
    total_samples = len(list(TRAINING_DATA_DIR.glob("*/metadata.json")))
    
    print(f"[Training] New sample {sample_id}: {submission.user_feedback.feedback_type}")
    
    return TrainingDataResponse(
        sample_id=sample_id,
        message=f"Training sample saved. Thank you for improving accessibility!",
        total_samples=total_samples
    )


@router.get("/training/stats")
async def get_training_stats():
    """Get statistics about collected training data."""
    samples = list(TRAINING_DATA_DIR.glob("*/metadata.json"))
    
    stats = {
        "total_samples": len(samples),
        "by_feedback_type": {},
        "by_context": {},
    }
    
    for sample_path in samples:
        try:
            with open(sample_path) as f:
                metadata = json.load(f)
            
            feedback_type = metadata.get("user_feedback", {}).get("feedback_type", "unknown")
            context = metadata.get("context", "unknown")
            
            stats["by_feedback_type"][feedback_type] = stats["by_feedback_type"].get(feedback_type, 0) + 1
            stats["by_context"][context] = stats["by_context"].get(context, 0) + 1
        except Exception:
            continue
    
    return stats


@router.post("/test-detection")
async def test_detection(request: VisionAnalysisRequest):
    """
    Test endpoint for debugging obstacle detection.
    Returns additional debug information.
    """
    start = time.time()
    
    if not GEMINI_API_KEY:
        return {
            "error": "Gemini API not configured",
            "gemini_key_set": False,
            "suggestion": "Set GEMINI_API_KEY environment variable"
        }
    
    try:
        image_bytes = base64.b64decode(request.image_base64)
        
        model = genai.GenerativeModel("gemini-2.0-flash")
        
        image_part = {
            "mime_type": "image/jpeg",
            "data": image_bytes
        }
        
        # Simple test prompt
        test_prompt = """Describe what you see in this image in 2-3 sentences. 
        Focus on: objects, people, obstacles, terrain, and potential hazards.
        Be specific about positions and distances."""
        
        response = model.generate_content([test_prompt, image_part])
        
        latency = int((time.time() - start) * 1000)
        
        return {
            "status": "success",
            "gemini_key_set": True,
            "image_size_bytes": len(image_bytes),
            "raw_response": response.text,
            "latency_ms": latency,
            "model": "gemini-2.0-flash",
            "context": request.context
        }
        
    except Exception as e:
        return {
            "status": "error",
            "gemini_key_set": True,
            "error_type": type(e).__name__,
            "error_message": str(e),
            "latency_ms": int((time.time() - start) * 1000)
        }
