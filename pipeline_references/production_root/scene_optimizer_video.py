import json
import math
import os
import sys
import time
from typing import Dict, List, Any, Set, Tuple, Optional

from scene_optimizer import (
    _resolve_scene_cm_per_unit,
    _resolve_scene_rotation_radians,
    _resolve_scene_plan_pivot_cm,
    _transform_plan_point_cm,
    _is_elevation_asset,
    _repair_wall_topology,
    STRICT_IMAGE_PORTAL_ROOM_LIMIT,
    ASSET_DEPTH_LIMIT,
)

# Configuration
# Legacy payloads use metre-based camera data; 2.0.0 video paths use cm.
SCALE_METERS_TO_CM = 100.0


def _resolve_camera_cm_per_unit(payload: dict) -> float:
    """
    Resolve the camera coordinate scale in centimetres per source unit.

    Newer video payloads often store camera paths in centimetres already
    (units="cm"), while older callers emitted metres. Default to metres
    when the payload does not provide an explicit unit hint.
    """
    unit = str(payload.get("units", "")).strip().lower() if isinstance(payload, dict) else ""
    if unit in {"cm", "centimeter", "centimeters", "centimetre", "centimetres"}:
        return 1.0
    if unit in {"mm", "millimeter", "millimeters", "millimetre", "millimetres"}:
        return 0.1
    if unit in {"ft", "feet", "foot"}:
        return 30.48
    if unit in {"m", "meter", "meters", "metre", "metres"}:
        return 100.0
    return 100.0

# Culling logs folder
CULLING_LOGS_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "culling_logs")
os.makedirs(CULLING_LOGS_DIR, exist_ok=True)

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

# Floor-related items always kept
FLOOR_ITEM_KEYWORDS = ["floor", "slab", "ground", "terrain", "level"]

# Exterior-only items — kept ONLY in EXTERIOR mode, removed in INTERIOR mode
# These are identified by name/type keywords (case-insensitive substring match)
EXTERIOR_ITEM_KEYWORDS = ["roof", "grill", "balcony", "exterior", "facade", "chimney", "antenna", "gutter", "downspout"]

# Interior-only items — explicitly culled from exterior mode even if placed outside room polygons
INDOOR_ITEM_KEYWORDS = [
    "indoor", "interior", "ceiling", "sofa", "couch", "bed ", "wardrobe",
    "cupboard", "dresser", "toilet", "shower", "washbasin", "fridge",
    "washing machine", "curtain", "rug", "carpet", "bookshelf", "bookcase",
    "desk", "ottoman", "chandelier", "mirror", "cabinet", "shelf", "table",
    "stool", "frame", "rack"
]

# Item proximity rescue tolerance (cm) — catches items slightly outside polygon
ITEM_RESCUE_TOLERANCE_CM = 85.0

# Wall-mounted items can sit on or slightly outside the room boundary, so they
# get a larger rescue radius than general furniture.
WALL_MOUNT_RESCUE_TOLERANCE_CM = 300.0

# Mounting labels treated as wall-mounted in the video pipeline.
WALL_MOUNT_TYPES = {
    "wall_mount",
    "wall-mounted",
    "wall mounted",
    "wallmount",
    "wall-mount",
}

# Extra visibility slack for items.  We still keep the item-aware cone test,
# but this gives a small buffer so partially visible furniture is not dropped.
ITEM_VIEW_MARGIN_DEG = 15.0

# Tolerance for matching vertex positions between rooms (cm)
POSITION_TOLERANCE_CM = 1.0

# Interior precision-culling defaults
DEFAULT_FOV_HALF_DEG = 30.0
DEFAULT_VIEW_DISTANCE_CM = 4500.0
PORTAL_ANGLE_MARGIN_DEG = 20.0


# ─────────────────────────────────────────────────────────────────────────────
# GEOMETRY HELPERS
# ─────────────────────────────────────────────────────────────────────────────

def _point_in_polygon(x: float, y: float, polygon: List[Tuple[float, float]]) -> bool:
    """Ray-casting algorithm: returns True if (x,y) is inside the polygon."""
    inside = False
    n = len(polygon)
    p1x, p1y = polygon[0]
    for i in range(1, n + 1):
        p2x, p2y = polygon[i % n]
        if y > min(p1y, p2y):
            if y <= max(p1y, p2y):
                if x <= max(p1x, p2x):
                    if p1y != p2y:
                        xinters = (y - p1y) * (p2x - p1x) / (p2y - p1y) + p1x
                    if p1x == p2x or x <= xinters:
                        inside = not inside
        p1x, p1y = p2x, p2y
    return inside


def _point_in_any_area(x: float, y: float, areas: dict, vertices: dict) -> bool:
    """Returns True if (x,y) is inside ANY area polygon."""
    for area_id, area in areas.items():
        poly_verts = []
        for v_id in area.get("vertices", []):
            v = vertices.get(v_id)
            if v:
                poly_verts.append((v.get("x", 0), v.get("y", 0)))
        if poly_verts and _point_in_polygon(x, y, poly_verts):
            return True
    return False


def _layer_has_geometry(layer: dict) -> bool:
    """True when a layer contains any meaningful scene content."""
    if not isinstance(layer, dict):
        return False
    for key in ("lines", "vertices", "areas", "items", "holes", "structures", "customLights", "sceneLights"):
        value = layer.get(key)
        if isinstance(value, dict) and value:
            return True
        if isinstance(value, list) and value:
            return True
    return False


def _pick_primary_layer_id(layers: dict, preferred_id: Optional[str] = None) -> Optional[str]:
    """Choose the best layer to optimize when a layered export is provided."""
    geometry_layer_ids = [layer_id for layer_id, layer in layers.items() if _layer_has_geometry(layer)]

    if preferred_id and preferred_id in layers and _layer_has_geometry(layers[preferred_id]):
        return preferred_id

    # If the caller supplied a preferred layer but it does not resolve cleanly,
    # only auto-pick another layer when there is exactly one geometry-bearing
    # option.  This avoids silently rendering the wrong floor in multi-layer
    # scenes when the hint is stale or ambiguous.
    if preferred_id:
        if len(geometry_layer_ids) == 1:
            return geometry_layer_ids[0]
        return None

    if geometry_layer_ids:
        return geometry_layer_ids[0]
    return next(iter(layers), None)


def _min_dist_to_polygon(ix: float, iy: float, poly_verts: List[Tuple[float, float]]) -> float:
    """Minimum distance from point (ix, iy) to the edges of a polygon."""
    min_dist = float("inf")
    n = len(poly_verts)
    for i in range(n):
        x1, y1 = poly_verts[i]
        x2, y2 = poly_verts[(i + 1) % n]
        dx, dy = x2 - x1, y2 - y1
        if dx == 0 and dy == 0:
            dist = math.hypot(ix - x1, iy - y1)
        else:
            t = ((ix - x1) * dx + (iy - y1) * dy) / (dx * dx + dy * dy)
            t = max(0.0, min(1.0, t))
            cx, cy = x1 + t * dx, y1 + t * dy
            dist = math.hypot(ix - cx, iy - cy)
        if dist < min_dist:
            min_dist = dist
    return min_dist


def _angle_to_point(
    cam_x: float,
    cam_y: float,
    dir_x: float,
    dir_y: float,
    px: float,
    py: float,
) -> float:
    """Signed angle (radians) from camera forward direction to a point."""
    dx, dy = px - cam_x, py - cam_y
    dist = math.hypot(dx, dy)
    if dist < 1e-6:
        return 0.0
    cos_a = max(-1.0, min(1.0, (dx * dir_x + dy * dir_y) / dist))
    return math.acos(cos_a)


def _portal_visible_in_fov(
    cam_x: float,
    cam_y: float,
    dir_x: float,
    dir_y: float,
    fov_half_rad: float,
    p1x: float,
    p1y: float,
    p2x: float,
    p2y: float,
    n_samples: int = 5,
) -> bool:
    """Returns True if any sampled point on the segment falls inside the view cone."""
    for i in range(n_samples):
        t = i / max(1, n_samples - 1)
        sx = p1x + t * (p2x - p1x)
        sy = p1y + t * (p2y - p1y)
        if _angle_to_point(cam_x, cam_y, dir_x, dir_y, sx, sy) <= fov_half_rad:
            return True
    return False


def _portal_world_endpoints(
    line: dict,
    hole: dict,
    vertices: dict,
    cm_per_unit: float,
) -> Optional[Tuple[Tuple[float, float], Tuple[float, float]]]:
    """Compute the 2D plan endpoints of a hole on a wall."""
    v_ids = line.get("vertices", [])
    if len(v_ids) < 2:
        return None

    v1 = vertices.get(str(v_ids[0]), vertices.get(v_ids[0]))
    v2 = vertices.get(str(v_ids[1]), vertices.get(v_ids[1]))
    if not v1 or not v2:
        return None

    ax, ay = float(v1["x"]), float(v1["y"])
    bx, by = float(v2["x"]), float(v2["y"])
    wall_len = math.hypot(bx - ax, by - ay)
    if wall_len < 1e-6:
        return None

    ux = (bx - ax) / wall_len
    uy = (by - ay) / wall_len

    raw_offset = float(hole.get("offset", 0.5))
    # Match the image pipeline: offsets may be stored either as a wall
    # fraction (0..1) or as an absolute source-unit distance along the wall.
    if abs(raw_offset) <= 1.5:
        offset_cm = raw_offset * wall_len
    else:
        offset_cm = raw_offset * cm_per_unit
    cx = ax + offset_cm * ux
    cy = ay + offset_cm * uy

    raw_w = hole.get("properties", {}).get("width", hole.get("width", 100))
    if isinstance(raw_w, dict):
        half_w = float(raw_w.get("length", 100)) / 2.0
    else:
        half_w = float(raw_w) / 2.0

    p1x, p1y = cx - half_w * ux, cy - half_w * uy
    p2x, p2y = cx + half_w * ux, cy + half_w * uy
    return (p1x, p1y), (p2x, p2y)


def _rooms_beyond_portal(
    line: dict,
    active_area_id: str,
    areas: dict,
    vertices: dict,
) -> Set[str]:
    """Find rooms on the opposite side of a portal-bearing wall."""
    v_ids = [str(v) for v in line.get("vertices", [])[:2]]
    if len(v_ids) < 2:
        return set()

    wall_positions: Set[Tuple[float, float]] = set()
    for vid in v_ids:
        v = vertices.get(vid, vertices.get(str(vid)))
        if v:
            wall_positions.add((round(float(v["x"]), 0), round(float(v["y"]), 0)))

    beyond: Set[str] = set()
    for aid, area in areas.items():
        if aid == active_area_id:
            continue
        area_verts = [str(v) for v in area.get("vertices", [])]
        if any(av in v_ids for av in area_verts):
            beyond.add(aid)
            continue

        for av in area_verts:
            av_data = vertices.get(av, vertices.get(str(av)))
            if av_data:
                key = (round(float(av_data["x"]), 0), round(float(av_data["y"]), 0))
                if key in wall_positions:
                    beyond.add(aid)
                    break

    return beyond


def _collect_portal_visible_rooms(
    active_area_id: str,
    areas: dict,
    lines: dict,
    holes: dict,
    vertices: dict,
    cm_per_unit: float,
    cam_x: float,
    cam_y: float,
    dir_x: float,
    dir_y: float,
    fov_half_rad: float,
    max_dist_cm: float,
    log_fn,
    sample_label: str = "",
    strict_room_limit: int = 0,
) -> Set[str]:
    """Collect rooms visible through the active room's portals."""
    prefix = f"{sample_label} " if sample_label else ""
    log_fn(f"  {prefix}Portal visibility sweep from active room {active_area_id} ...")

    active_verts: Set[str] = set(str(v) for v in areas[active_area_id].get("vertices", []))
    visible_rooms: Set[str] = set()
    portal_room_scores: Dict[str, Tuple[float, float, float]] = {}
    fallback_room_scores: Dict[str, Tuple[float, float, float]] = {}
    effective_fov = fov_half_rad + math.radians(PORTAL_ANGLE_MARGIN_DEG)

    def _area_centroid(a_id: str) -> Optional[Tuple[float, float]]:
        area = areas.get(a_id)
        if not area:
            return None
        pts: List[Tuple[float, float]] = []
        for v_id in area.get("vertices", []):
            v = vertices.get(str(v_id))
            if v:
                pts.append((float(v["x"]), float(v["y"])))
        if not pts:
            return None
        return (
            sum(x for x, _ in pts) / len(pts),
            sum(y for _, y in pts) / len(pts),
        )

    active_room_centroid = _area_centroid(active_area_id)

    def _segment_side(
        ax: float,
        ay: float,
        bx: float,
        by: float,
        px: float,
        py: float,
    ) -> float:
        """Signed side test for a point relative to a wall segment."""
        return ((bx - ax) * (py - ay)) - ((by - ay) * (px - ax))

    def _is_on_opposite_side(
        room_centroid: Optional[Tuple[float, float]],
        wall_p1: Tuple[float, float],
        wall_p2: Tuple[float, float],
    ) -> bool:
        """Keep only rooms that sit on the far side of the wall from the active room."""
        if not active_room_centroid or room_centroid is None:
            return True

        ref_side = _segment_side(
            wall_p1[0], wall_p1[1], wall_p2[0], wall_p2[1],
            active_room_centroid[0], active_room_centroid[1],
        )
        room_side = _segment_side(
            wall_p1[0], wall_p1[1], wall_p2[0], wall_p2[1],
            room_centroid[0], room_centroid[1],
        )
        if abs(ref_side) < 1e-6 or abs(room_side) < 1e-6:
            return True
        return (ref_side * room_side) < 0.0

    def _register_room_candidate(
        room_id: str,
        kind_bias: float,
        room_centroid: Optional[Tuple[float, float]],
        portal_dist_cm: float,
        source: str,
    ) -> None:
        if room_id == active_area_id or room_centroid is None:
            return
        room_angle_deg = math.degrees(
            _angle_to_point(cam_x, cam_y, dir_x, dir_y, room_centroid[0], room_centroid[1])
        )
        score = (kind_bias, abs(room_angle_deg), portal_dist_cm)
        score_map = portal_room_scores if source == "portal" else fallback_room_scores
        current = score_map.get(room_id)
        if current is None or score < current:
            score_map[room_id] = score

    for lid, line in lines.items():
        v_ids = [str(v) for v in line.get("vertices", [])[:2]]
        if len(v_ids) < 2:
            continue

        if not any(vid in active_verts for vid in v_ids):
            continue

        line_holes = line.get("holes", [])
        is_hidden  = line.get("visible") is False
        
        if not line_holes and not is_hidden:
            continue

        # (a) Regular portals
        for hole_id in line_holes:
            hid = str(hole_id)
            hole = holes.get(hid, holes.get(hole_id))
            if not hole:
                continue

            endpoints = _portal_world_endpoints(line, hole, vertices, cm_per_unit)
            if not endpoints:
                continue

            (ep1x, ep1y), (ep2x, ep2y) = endpoints
            portal_cx = (ep1x + ep2x) / 2.0
            portal_cy = (ep1y + ep2y) / 2.0
            dist = math.hypot(portal_cx - cam_x, portal_cy - cam_y)

            if dist > max_dist_cm:
                continue

            if not _portal_visible_in_fov(
                cam_x, cam_y, dir_x, dir_y, effective_fov, ep1x, ep1y, ep2x, ep2y
            ):
                continue

            beyond = _rooms_beyond_portal(line, active_area_id, areas, vertices)
            if beyond:
                for aid in beyond:
                    centroid = _area_centroid(aid)
                    if centroid is not None and not _is_on_opposite_side(centroid, (ep1x, ep1y), (ep2x, ep2y)):
                        # Vertex-adjacent but centroid on same side (L-shaped / shared-boundary room).
                        # Register as fallback so it is not silently dropped.
                        log_fn(
                            f"      ⚠️  Room '{areas.get(aid, {}).get('name', aid)}' centroid same-side "
                            f"— registering as fallback candidate (vertex-adjacent)"
                        )
                        _register_room_candidate(aid, 0.05, centroid, dist, "fallback")
                        continue
                    _register_room_candidate(aid, 0.0, centroid, dist, "portal")

        # (b) Hidden walls (entire wall spans acts as a portal)
        if is_hidden:
            vd1 = vertices.get(v_ids[0], vertices.get(str(v_ids[0])))
            vd2 = vertices.get(v_ids[1], vertices.get(str(v_ids[1])))
            if vd1 and vd2:
                p1x, p1y = float(vd1.get("x", 0)), float(vd1.get("y", 0))
                p2x, p2y = float(vd2.get("x", 0)), float(vd2.get("y", 0))
                portal_cx, portal_cy = (p1x + p2x) / 2.0, (p1y + p2y) / 2.0
                dist = math.hypot(portal_cx - cam_x, portal_cy - cam_y)
                if dist <= max_dist_cm:
                    if _portal_visible_in_fov(cam_x, cam_y, dir_x, dir_y, effective_fov, p1x, p1y, p2x, p2y):
                        beyond = _rooms_beyond_portal(line, active_area_id, areas, vertices)
                        if beyond:
                            for aid in beyond:
                                centroid = _area_centroid(aid)
                                if centroid is not None and not _is_on_opposite_side(centroid, (p1x, p1y), (p2x, p2y)):
                                    log_fn(
                                        f"      ⚠️  Room '{areas.get(aid, {}).get('name', aid)}' centroid same-side "
                                        f"(hidden wall) — registering as fallback candidate"
                                    )
                                    _register_room_candidate(aid, 0.15, centroid, dist, "fallback")
                                    continue
                                _register_room_candidate(aid, 0.1, centroid, dist, "portal")

    room_limit = strict_room_limit if strict_room_limit > 0 else STRICT_IMAGE_PORTAL_ROOM_LIMIT
    if portal_room_scores or fallback_room_scores:
        ordered_rooms: List[Tuple[str, Tuple[float, float, float]]] = []
        if portal_room_scores:
            ordered_portal_rooms = sorted(portal_room_scores.items(), key=lambda kv: kv[1])
            ordered_rooms.extend(ordered_portal_rooms[:room_limit])

        remaining_slots = max(0, room_limit - len(ordered_rooms))
        if remaining_slots > 0 and fallback_room_scores:
            ordered_fallback_rooms = sorted(fallback_room_scores.items(), key=lambda kv: kv[1])
            ordered_rooms.extend(ordered_fallback_rooms[:remaining_slots])

        visible_rooms = {room_id for room_id, _ in ordered_rooms}
        combined_count = len(portal_room_scores) + len(fallback_room_scores)
        log_fn(
            f"  Portal clamp: keeping {len(visible_rooms)} neighbour room(s) "
            f"out of {combined_count} candidate(s)"
        )
        for room_id, score in ordered_rooms:
            log_fn(
                f"     • {areas.get(room_id, {}).get('name', room_id)} ({room_id}) "
                f"score={score[0]:.2f}/{score[1]:.1f}/{score[2]:.0f}"
            )

    return visible_rooms


# ─────────────────────────────────────────────────────────────────────────────
# BFS FLOOD-FILL  (shared helper)
# ─────────────────────────────────────────────────────────────────────────────

def _flood_fill_connected_rooms(
    seed_ids: Set[str],
    areas: dict,
    lines: dict,
    vertices: dict,
    log_fn,
) -> Set[str]:
    """
    Starting from seed_ids, expand kept rooms via:
      (a) Shared vertex positions (adjacent rooms share a wall corner)
      (b) Walls that have holes (openings) or are hidden/invisible
    Returns the full set of kept area IDs.
    """
    area_positions: Dict[str, List[Tuple[float, float]]] = {}
    for a_id, area in areas.items():
        positions = []
        for v_id in area.get("vertices", []):
            v = vertices.get(v_id)
            if v:
                positions.append((v.get("x", 0), v.get("y", 0)))
        area_positions[a_id] = positions

    def areas_are_neighbors(aid1: str, aid2: str) -> bool:
        for (x1, y1) in area_positions.get(aid1, []):
            for (x2, y2) in area_positions.get(aid2, []):
                if (
                    abs(x1 - x2) < POSITION_TOLERANCE_CM
                    and abs(y1 - y2) < POSITION_TOLERANCE_CM
                ):
                    return True
        return False

    kept: Set[str] = set(seed_ids)
    changed = True

    while changed:
        changed = False

        # (a) Position-based adjacency
        for a_id in list(areas.keys()):
            if a_id in kept:
                continue
            for kept_id in list(kept):
                if areas_are_neighbors(kept_id, a_id):
                    kept.add(a_id)
                    changed = True
                    log_fn(
                        f"  ➕ Adding Neighbour Room (Position Match): "
                        f"'{areas[a_id].get('name')}' ({a_id})"
                    )
                    break

        # (b) Hole / hidden-wall connections
        all_kept_verts: Set[str] = set()
        for aid in kept:
            all_kept_verts.update(areas[aid].get("vertices", []))

        for lid, line in lines.items():
            line_holes  = line.get("holes", [])
            line_hidden = line.get("visible") is False
            if not line_holes and not line_hidden:
                continue

            v_ids = line.get("vertices", [])
            if len(v_ids) < 2:
                continue
            v1, v2 = v_ids[0], v_ids[1]

            v1_pos = (vertices[v1].get("x", 0), vertices[v1].get("y", 0)) if v1 in vertices else None
            v2_pos = (vertices[v2].get("x", 0), vertices[v2].get("y", 0)) if v2 in vertices else None

            touches_kept = v1 in all_kept_verts or v2 in all_kept_verts
            if not touches_kept:
                for aid in kept:
                    for (px, py) in area_positions.get(aid, []):
                        if v1_pos and abs(v1_pos[0] - px) < POSITION_TOLERANCE_CM and abs(v1_pos[1] - py) < POSITION_TOLERANCE_CM:
                            touches_kept = True
                            break
                        if v2_pos and abs(v2_pos[0] - px) < POSITION_TOLERANCE_CM and abs(v2_pos[1] - py) < POSITION_TOLERANCE_CM:
                            touches_kept = True
                            break
                    if touches_kept:
                        break

            if touches_kept:
                for a_id, area in areas.items():
                    if a_id in kept:
                        continue
                    area_verts = set(area.get("vertices", []))
                    if v1 in area_verts or v2 in area_verts:
                        kept.add(a_id)
                        changed = True
                        reason = "Hole-Connected" if line_holes else "Hidden-Wall-Connected"
                        log_fn(
                            f"  ➕ Adding Neighbour Room ({reason}): "
                            f"'{area.get('name')}' ({a_id})"
                        )

    return kept


# ─────────────────────────────────────────────────────────────────────────────
# INTERIOR CULLING  (video)
# ─────────────────────────────────────────────────────────────────────────────

def _is_exterior_asset_video(item: dict) -> bool:
    """Check if an item is an exterior-only asset by its name/type keywords."""
    item_type = str(item.get("type", "")).lower()
    item_name = str(item.get("name", "")).lower()
    full_desc = item_type + " " + item_name
    return any(kw in full_desc for kw in EXTERIOR_ITEM_KEYWORDS)


def _is_interior_furniture_asset_video(item: dict) -> bool:
    """Check if an item is explicitly an interior furnishing (e.g. sofa, bed)."""
    item_type = str(item.get("type", "")).lower()
    item_name = str(item.get("name", "")).lower()
    full_desc = item_type + " " + item_name
    return any(kw in full_desc for kw in INDOOR_ITEM_KEYWORDS)


def _item_dimension_cm(
    item: dict,
    key: str,
    default_cm: float = 100.0,
    cm_per_unit: float = 1.0,
) -> float:
    """Read an item's dimension in centimetres from top-level or properties."""
    raw = item.get(key, None)
    if raw is None and isinstance(item.get("properties"), dict):
        raw = item["properties"].get(key, None)

    if isinstance(raw, dict):
        if "length" in raw:
            try:
                return float(raw.get("length", default_cm)) * cm_per_unit
            except Exception:
                return default_cm
        if "value" in raw:
            try:
                return float(raw.get("value", default_cm)) * cm_per_unit
            except Exception:
                return default_cm
    try:
        if raw is not None:
            return float(raw) * cm_per_unit
    except Exception:
        pass
    return default_cm


def _item_footprint_radius_cm(item: dict, cm_per_unit: float = 1.0) -> float:
    """
    Approximate the item footprint with a circle radius in plan view.
    Using half the diagonal keeps partially visible furniture from being
    culled when only part of it enters the camera cone.
    Item dimensions are stored in the same source units as the plan, so we
    scale them to centimetres before visibility checks.
    """
    width = max(_item_dimension_cm(item, "width", 100.0, cm_per_unit), 1.0)
    depth = max(_item_dimension_cm(item, "depth", 100.0, cm_per_unit), 1.0)
    return 0.5 * math.hypot(width, depth)


def _item_visible_from_sample(
    item: dict,
    sample: Dict[str, Any],
    item_x: float,
    item_y: float,
    max_view_dist_cm: float,
    cm_per_unit: float = 1.0,
) -> bool:
    """Return True when the item's footprint overlaps the camera view cone."""
    cam_x = float(sample["cam_x"])
    cam_y = float(sample["cam_y"])
    cam_dir_x = float(sample["cam_dir_x"])
    cam_dir_y = float(sample["cam_dir_y"])
    fov_half_deg = float(sample["fov_half_deg"])

    radius_cm = _item_footprint_radius_cm(item, cm_per_unit)
    dist_cm = math.hypot(item_x - cam_x, item_y - cam_y)
    if max(0.0, dist_cm - radius_cm) > max_view_dist_cm:
        return False

    angle_deg = math.degrees(
        _angle_to_point(cam_x, cam_y, cam_dir_x, cam_dir_y, item_x, item_y)
    )
    # Expand the FOV by the item's apparent angular radius so items that only
    # partially overlap the cone are kept.
    if dist_cm < 1e-6:
        angular_radius_deg = 90.0
    else:
        angular_radius_deg = math.degrees(
            math.asin(min(1.0, radius_cm / max(dist_cm, 1.0)))
        )

    fov_limit_deg = fov_half_deg + ITEM_VIEW_MARGIN_DEG + angular_radius_deg
    return angle_deg <= fov_limit_deg


def _cull_interior_video(
    active_area_ids: Set[str],
    portal_samples: List[Dict[str, Any]],
    vertices: dict,
    lines: dict,
    areas: dict,
    items: dict,
    holes: dict,
    cm_per_unit: float,
    rotation_radians: float,
    pivot: Tuple[float, float],
    log_fn,
    max_view_dist_cm: float = DEFAULT_VIEW_DISTANCE_CM,
    item_samples: Optional[List[Dict[str, Any]]] = None,
    strict_room_limit: int = 0,
) -> Tuple[dict, dict, dict, dict, dict]:
    """
    INTERIOR MODE — camera path passes through one or more rooms.

    Keep:
      • All active rooms + rooms reachable via openings/hidden walls (BFS)
      • Walls whose both endpoints belong to kept rooms
      • Holes (doors/windows) on kept walls
      • Items inside kept rooms (+ 85 cm rescue)
      • Floor assets always

    Remove:
      • All rooms not reachable from any active room
      • Walls, holes, items outside kept rooms
      • Exterior-only items (roof, grill, balcony, etc.) — even if geometrically inside
    """
    if item_samples is None:
        item_samples = portal_samples

    log_fn("  Interior Culling (Video Portal Mode)")

    log_fn(
        f"  Interior portal samples: {len(portal_samples)} | "
        f"item samples: {len(item_samples)} | MaxDist={max_view_dist_cm:.0f}cm"
    )

    transformed_vertices: Dict[str, dict] = {}
    for vid, vertex in vertices.items():
        if not isinstance(vertex, dict):
            continue
        tx, ty = _transform_plan_point_cm(
            float(vertex.get("x", 0.0)),
            float(vertex.get("y", 0.0)),
            cm_per_unit,
            rotation_radians,
            pivot,
        )
        v_copy = dict(vertex)
        v_copy["x"] = tx
        v_copy["y"] = ty
        transformed_vertices[vid] = v_copy

    transformed_area_polys: Dict[str, List[Tuple[float, float]]] = {}
    for aid, area in areas.items():
        poly_verts: List[Tuple[float, float]] = []
        for v_id in area.get("vertices", []):
            v = transformed_vertices.get(str(v_id), transformed_vertices.get(v_id))
            if v:
                poly_verts.append((float(v.get("x", 0.0)), float(v.get("y", 0.0))))
        if poly_verts:
            transformed_area_polys[aid] = poly_verts

    kept_area_ids: Set[str] = set(active_area_ids)
    asset_area_ids: Set[str] = set(active_area_ids)  # rooms that get assets/furniture
    for idx, sample in enumerate(portal_samples):
        active_area_id = sample.get("active_area_id")
        if not active_area_id or active_area_id not in areas:
            continue

        s_cam_x = float(sample["cam_x"])
        s_cam_y = float(sample["cam_y"])
        s_dir_x = float(sample["cam_dir_x"])
        s_dir_y = float(sample["cam_dir_y"])
        s_fov   = math.radians(float(sample["fov_half_deg"]))

        # ── Depth-1 sweep: rooms directly visible from active room ────────────
        visible_rooms = _collect_portal_visible_rooms(
            active_area_id,
            areas,
            lines,
            holes,
            transformed_vertices,
            cm_per_unit,
            s_cam_x, s_cam_y, s_dir_x, s_dir_y,
            s_fov,
            max_view_dist_cm,
            log_fn,
            sample_label=f"[sample {idx}]",
        )
        kept_area_ids.update(visible_rooms)

        # ── Depth-2 sweep: rooms visible through neighbour portals ────────────
        # Mirrors the image pipeline: sweep from each depth-1 neighbour toward
        # the camera, revealing rooms behind corridors and hallways.
        depth2_ids: Set[str] = set()
        for n_aid in visible_rooms:
            n_area = areas.get(n_aid, {})
            n_verts = [
                transformed_vertices.get(str(v))
                for v in n_area.get("vertices", [])
                if transformed_vertices.get(str(v))
            ]
            if not n_verts:
                continue
            n_cx = sum(float(v["x"]) for v in n_verts) / len(n_verts)
            n_cy = sum(float(v["y"]) for v in n_verts) / len(n_verts)
            n_dx, n_dy = n_cx - s_cam_x, n_cy - s_cam_y
            n_dist = math.hypot(n_dx, n_dy)
            if n_dist < 1e-6:
                continue
            n_dir_x = n_dx / n_dist
            n_dir_y = n_dy / n_dist

            d2 = _collect_portal_visible_rooms(
                n_aid,
                areas,
                lines,
                holes,
                transformed_vertices,
                cm_per_unit,
                s_cam_x, s_cam_y, n_dir_x, n_dir_y,
                s_fov,
                max_view_dist_cm,
                log_fn,
                sample_label=f"[sample {idx} d2 from {n_aid}]",
            )
            new_d2 = d2 - kept_area_ids - {active_area_id}
            if new_d2:
                log_fn(
                    f"  🔭 Depth-2 [sample {idx}] from '{n_area.get('name', n_aid)}' found: "
                    f"{[areas.get(a, {}).get('name', a) for a in new_d2]}"
                )
            depth2_ids.update(new_d2)

        kept_area_ids.update(depth2_ids)

        # ── Asset depth limit per sample ──────────────────────────────────────
        # depth-1 nearest rooms get assets; depth-2 are geometry-only shells.
        def _room_angle_video(aid: str) -> float:
            area = areas.get(aid, {})
            verts = [
                transformed_vertices.get(str(v)) for v in area.get("vertices", [])
                if transformed_vertices.get(str(v))
            ]
            if not verts:
                return 180.0
            cx = sum(float(v["x"]) for v in verts) / len(verts)
            cy = sum(float(v["y"]) for v in verts) / len(verts)
            dx, dy = cx - s_cam_x, cy - s_cam_y
            dist = math.hypot(dx, dy)
            if dist < 1e-6:
                return 0.0
            cos_a = max(-1.0, min(1.0, (dx * s_dir_x + dy * s_dir_y) / dist))
            return math.degrees(math.acos(cos_a))

        if visible_rooms:
            sorted_visible = sorted(visible_rooms, key=_room_angle_video)
            asset_depth = ASSET_DEPTH_LIMIT
            asset_area_ids.update(sorted_visible[:asset_depth])
            
            # Always load assets for outdoor-style portal-connected areas (like balconies)
            for nid in sorted_visible:
                n_area = areas.get(nid, {})
                n_label = str(n_area.get("properties", {}).get("label", "")).lower()
                n_name = str(n_area.get("name", "")).lower()
                if any(kw in n_label or kw in n_name for kw in ["balcony", "patio", "terrace", "deck", "outdoor", "porch", "loggia"]):
                    asset_area_ids.add(nid)
        # depth2_ids intentionally NOT added to asset_area_ids (geometry-only)

    log_fn(f"  Total kept rooms: {len(kept_area_ids)} (assets in {len(asset_area_ids)})")
    for aid in kept_area_ids:
        if aid in active_area_ids:
            room_tag = "ACTIVE"
        elif aid in asset_area_ids:
            room_tag = "PORTAL+ASSETS[D1]"
        else:
            room_tag = "PORTAL-SHELL[D2]"
        log_fn(f"     - [{room_tag}] {areas[aid].get('name', 'Unknown')} ({aid})")



    # ── Areas ────────────────────────────────────────────────────────────────
    new_areas = {aid: areas[aid] for aid in kept_area_ids}

    # ── Vertices ─────────────────────────────────────────────────────────────
    kept_vertex_ids: Set[str] = set()
    for area in new_areas.values():
        kept_vertex_ids.update(area.get("vertices", []))

    kept_positions: Set[Tuple] = set()
    for vid in kept_vertex_ids:
        v = transformed_vertices.get(vid)
        if v:
            kept_positions.add((round(v.get("x", 0), 0), round(v.get("y", 0), 0)))

    def vertex_is_near_kept(vid: str) -> bool:
        if vid in kept_vertex_ids:
            return True
        v = transformed_vertices.get(vid)
        if v:
            vx, vy = float(v.get("x", 0)), float(v.get("y", 0))
            if (round(vx, 0), round(vy, 0)) in kept_positions:
                return True
            # Also check if it's within a reasonable wall thickness tolerance (1000 units = 100cm)
            for kx, ky in kept_positions:
                if math.hypot(vx - kx, vy - ky) <= 30.0:
                    return True
        return False

    new_vertices = {vid: vertices[vid] for vid in kept_vertex_ids if vid in vertices}

    def _keep_vertices(*vertex_ids) -> None:
        """Add wall endpoints to the surviving vertex set.

        UNITS: read from `vertices` (SOURCE plan units), never from
        `transformed_vertices` — that local copy has already been multiplied by
        `cm_per_unit` and rotated about the pivot for the culling maths only.
        The optimised plan handed back to Godot must stay in source units.

        This only ever fires for vertices that are NOT area corners — corner
        vertices are already seeded into `new_vertices` above. In practice that
        means T-junction / `hostedOn` vertices, where the last wall snapped onto
        the inner face of another wall instead of sharing its corner vertex.
        Sourcing those from the transformed copy divides mm-based (version
        2.0.0) plans by 10 and sends that wall running off toward the plan
        origin — the bug fixed in scene_optimizer.py on 2026-09-02.
        """
        for vid in vertex_ids:
            if vid in new_vertices:
                continue
            src = vertices.get(vid)
            if src is None:
                continue
            new_vertices[vid] = src
            kept_vertex_ids.add(vid)

    # Keep active room shell walls even if vertex matching is imperfect.
    active_room_vertex_ids: Set[str] = set()
    active_room_positions: Set[Tuple] = set()
    active_room_edges: List[Tuple[Tuple[float, float], Tuple[float, float]]] = []

    for aid in active_area_ids:
        area = areas.get(aid)
        if not area:
            continue
        corner_pts = []
        for vid in area.get("vertices", []):
            vid = str(vid)
            active_room_vertex_ids.add(vid)
            v = transformed_vertices.get(vid)
            if v:
                pt = (round(v.get("x", 0), 0), round(v.get("y", 0), 0))
                active_room_positions.add(pt)
                corner_pts.append((float(v.get("x", 0)), float(v.get("y", 0))))
        if len(corner_pts) >= 2:
            for i in range(len(corner_pts)):
                active_room_edges.append((corner_pts[i], corner_pts[(i + 1) % len(corner_pts)]))

    # Pre-build set of hole line IDs for quick lookup
    hole_line_ids: Set[str] = set()
    for h in holes.values():
        ref = str(h.get("line", ""))
        if ref:
            hole_line_ids.add(ref)
            
    def _point_to_segment_distance_2d(px: float, py: float, ax: float, ay: float, bx: float, by: float) -> float:
        import math
        dx = bx - ax
        dy = by - ay
        seg_len_sq = (dx * dx) + (dy * dy)
        if seg_len_sq < 1e-12:
            return math.hypot(px - ax, py - ay)
        t = (((px - ax) * dx) + ((py - ay) * dy)) / seg_len_sq
        t = max(0.0, min(1.0, t))
        cx = ax + (t * dx)
        cy = ay + (t * dy)
        return math.hypot(px - cx, py - cy)

    _EDGE_SNAP_TOL = 1.0 / cm_per_unit if cm_per_unit else 1.0

    def wall_belongs_to_active_room(v1_id: str, v2_id: str) -> bool:
        """True only when BOTH endpoints are active-room vertices (or lie on
        an active-room boundary edge — handles T-junction points).
        """
        def _in_room(vid: str) -> bool:
            if str(vid) in active_room_vertex_ids:
                return True
            v = transformed_vertices.get(str(vid))
            if v:
                vx, vy = float(v.get("x", 0)), float(v.get("y", 0))
                if (round(vx, 0), round(vy, 0)) in active_room_positions:
                    return True
                for (ax, ay), (bx, by) in active_room_edges:
                    if _point_to_segment_distance_2d(vx, vy, ax, ay, bx, by) <= _EDGE_SNAP_TOL:
                        return True
                # Tolerance check for thick walls where the endpoint extends slightly past the room corner
                for rx, ry in active_room_positions:
                    if math.hypot(vx - rx, vy - ry) <= 30.0:
                        return True
            return False
        return _in_room(v1_id) and _in_room(v2_id)

    # ── Lines ─────────────────────────────────────────────────────────────────
    new_lines: Dict[str, Any] = {}
    culled_walls: List[str] = []
    for lid, line in lines.items():
        v_ids = line.get("vertices", [])
        if len(v_ids) < 2:
            continue

        v1, v2 = v_ids[0], v_ids[1]
        if wall_belongs_to_active_room(v1, v2):
            # The active room shell should remain intact in interior video
            # renders even when there are no portals to reveal neighbors.
            new_lines[lid] = line
            _keep_vertices(v1, v2)
            continue

        # Stub wall with a hole (door/window) must be kept for the doorframe
        v1_in = str(v1) in active_room_vertex_ids or (
            (round(transformed_vertices[str(v1)].get("x", 0), 0), round(transformed_vertices[str(v1)].get("y", 0), 0))
            in active_room_positions
            if transformed_vertices.get(str(v1)) else False
        )
        v2_in = str(v2) in active_room_vertex_ids or (
            (round(transformed_vertices[str(v2)].get("x", 0), 0), round(transformed_vertices[str(v2)].get("y", 0), 0))
            in active_room_positions
            if transformed_vertices.get(str(v2)) else False
        )
        if (v1_in or v2_in) and lid in hole_line_ids:
            new_lines[lid] = line
            _keep_vertices(v1, v2)
            continue

        if not (vertex_is_near_kept(v1) and vertex_is_near_kept(v2)):
            culled_walls.append(f"Wall {lid} [not touching kept rooms]")
            continue

        vd1 = vertices.get(v1)
        vd2 = vertices.get(v2)
        if not vd1 or not vd2:
            continue

        # Keep the room shell intact. Interior FOV pruning is for items and
        # adjacent rooms, not for walls that bound the active room.
        new_lines[lid] = line
        _keep_vertices(v1, v2)

    if culled_walls:
        log_fn(f"\n  Culled {len(culled_walls)} walls:")
        for cw in culled_walls:
            log_fn(f"     - {cw}")

    # ── Holes ─────────────────────────────────────────────────────────────────
    new_holes = {
        hid: hole
        for hid, hole in holes.items()
        if hole.get("line") in new_lines
    }

    # ── Items ─────────────────────────────────────────────────────────────────
    new_items: Dict[str, Any] = {}
    culled_items: List[str] = []

    for iid, item in items.items():
        item_type = str(item.get("type", "")).lower()
        item_name = str(item.get("name", "")).lower()

        if any(kw in item_type or kw in item_name for kw in FLOOR_ITEM_KEYWORDS):
            new_items[iid] = item
            log_fn(f"  🛡️ Preserving Floor Asset: '{item.get('name')}' ({iid})")
            continue

        # Remove exterior-only assets (roof, grill, balcony) in interior render
        # Exception: if the exterior asset is explicitly placed inside an active/portal room, keep it.
        if _is_exterior_asset_video(item):
            ix, iy = float(item.get("x", 0)), float(item.get("y", 0))
            assigned_room = None
            for aid in asset_area_ids:
                area = areas.get(aid, {})
                poly = []
                for v_id in area.get("vertices", []):
                    v = vertices.get(str(v_id))
                    if v:
                        poly.append((float(v["x"]), float(v["y"])))
                if len(poly) >= 3 and _point_in_polygon(ix, iy, poly):
                    assigned_room = aid
                    break
            
            if assigned_room:
                log_fn(f"  🌳 Keeping exterior asset because it is inside active/portal room: '{item.get('name')}' ({iid})")
            else:
                culled_items.append(f"{item.get('name', 'Unknown')} ({iid}) [exterior-only asset]")
                log_fn(f"  🗑️ Removing exterior-only asset in interior render: '{item.get('name', 'Unknown')}' ({iid})")
                continue

        ix, iy = _transform_plan_point_cm(
            float(item.get("x", 0)),
            float(item.get("y", 0)),
            cm_per_unit,
            rotation_radians,
            pivot,
        )

        # Determine if this is a wall-mounted item (frames, TVs, ACs, shelves...)
        mounting = str(item.get("mounting_type", "")).strip().lower()
        is_wall_mount = mounting in WALL_MOUNT_TYPES

        # Items in a room the camera path stands in are kept whatever the view
        # cone says. The renderer is a path tracer: an item that never enters
        # the shot still casts shadows and bounces light into it, and a light
        # fixture still lights the room. Blender renders every object for every
        # frame. On job 210 this test dropped 27 such items, 7 of them light
        # fixtures. Rooms seen only through an opening keep the view-cone test.
        # Strict containment, no rescue distance: even 85 cm claimed four items
        # of the room next door on job 210. An active-room item whose anchor sits
        # in the wall still reaches the rescue pass below through the normal test.
        in_active_room = any(
            _point_in_polygon(ix, iy, transformed_area_polys[aid])
            for aid in active_area_ids
            if transformed_area_polys.get(aid)
        )
        if in_active_room:
            new_items[iid] = item
            continue

        visible_from_path = False
        for sample in item_samples:
            if _item_visible_from_sample(item, sample, ix, iy, max_view_dist_cm, cm_per_unit):
                visible_from_path = True
                break

        if not visible_from_path:
            culled_items.append(
                f"{item.get('name', 'Unknown')} ({iid}) [outside all interior sample FOV/range]"
            )
            continue

        # Pass 1 – polygon inclusion
        # Use asset_area_ids so assets are only loaded for rooms within
        # ASSET_DEPTH_LIMIT portal hops. Rooms beyond get geometry but no items.
        is_kept = False
        for aid in asset_area_ids:
            poly_verts = transformed_area_polys.get(aid, [])
            if poly_verts and _point_in_polygon(ix, iy, poly_verts):
                is_kept = True
                break

        if is_kept:
            new_items[iid] = item
            continue

        # Pass 2 – proximity rescue.
        # Wall-mounted items (frames, TVs, shelves, ACs...) have their 2-D centroid
        # ON the wall line or even slightly past it (outer face).  Standard wall
        # thickness is 228.6 cm so half-thickness is ~114 cm — already beyond the
        # previous 85 cm rescue radius.  We use WALL_MOUNT_RESCUE_TOLERANCE_CM
        # (300 cm) for wall-mount items so they are never dropped just because
        # their anchor point sits outside the room polygon.
        rescue_tolerance = (
            WALL_MOUNT_RESCUE_TOLERANCE_CM if is_wall_mount else ITEM_RESCUE_TOLERANCE_CM
        )
        rescued = False
        # Pass 2 also uses asset_area_ids to maintain depth-limited asset loading.
        for aid in asset_area_ids:
            poly_verts = transformed_area_polys.get(aid, [])
            if not poly_verts:
                continue
            min_dist = _min_dist_to_polygon(ix, iy, poly_verts)
            if min_dist <= rescue_tolerance:
                log_fn(
                    f"  ✨ Rescuing {'wall-mounted ' if is_wall_mount else ''}item "
                    f"'{item.get('name', 'Unknown')}' ({iid}) "
                    f"— Dist: {min_dist:.1f} cm <= {rescue_tolerance:.0f} cm"
                )
                new_items[iid] = item
                rescued = True
                break

        if not rescued:
            culled_items.append(f"{item.get('name', 'Unknown')} ({iid})")

    if culled_items:
        log_fn(f"\n  🗑️  Culled {len(culled_items)} exterior/out-of-room items:")
        for ci in culled_items:
            log_fn(f"     - {ci}")

    return new_vertices, new_lines, new_areas, new_items, new_holes


# ─────────────────────────────────────────────────────────────────────────────
# EXTERIOR CULLING  (video)
# ─────────────────────────────────────────────────────────────────────────────

def _cull_exterior_video(
    vertices: dict,
    lines: dict,
    areas: dict,
    items: dict,
    holes: dict,
    cm_per_unit: float,
    rotation_radians: float,
    pivot: Tuple[float, float],
    log_fn,
) -> Tuple[dict, dict, dict, dict, dict]:
    """
    EXTERIOR MODE — entire camera path is outside all rooms.

    Keep:
      • ALL walls, areas (building shell)
      • ALL holes (doors/windows) — marked with is_exterior_black=true
        so the renderer fills openings with BLACK (no interior visible)
      • Exterior-named items (roof, grill, balcony, etc.) — by keyword match
      • Items physically outside all room polygons (garden, trees, etc.)
      • Floor assets always

    Remove:
      • ALL interior items inside room polygons
        (sofas, fridges, lights, frames, pictures, mirrors, etc.)
      • Wall fittings are NOT preserved — in exterior mode, nothing inside
        the building should be visible through the black windows

    All holes (doors/windows/openings) are flagged is_exterior_black=true
    so the Godot renderer places a black blocker in the opening. This is
    purely geometry-based — no name matching is used for holes.
    """
    log_fn(f"  ── Exterior Culling (Video) ──")

    # Keep all architectural geometry intact
    new_areas    = dict(areas)
    new_lines    = dict(lines)
    new_vertices = dict(vertices)

    transformed_vertices: Dict[str, dict] = {}
    for vid, vertex in vertices.items():
        if not isinstance(vertex, dict):
            continue
        tx, ty = _transform_plan_point_cm(
            float(vertex.get("x", 0.0)),
            float(vertex.get("y", 0.0)),
            cm_per_unit,
            rotation_radians,
            pivot,
        )
        v_copy = dict(vertex)
        v_copy["x"] = tx
        v_copy["y"] = ty
        transformed_vertices[vid] = v_copy

    transformed_area_polys: Dict[str, List[Tuple[float, float]]] = {}
    for aid, area in areas.items():
        poly_verts: List[Tuple[float, float]] = []
        for v_id in area.get("vertices", []):
            v = transformed_vertices.get(str(v_id), transformed_vertices.get(v_id))
            if v:
                poly_verts.append((float(v.get("x", 0.0)), float(v.get("y", 0.0))))
        if poly_verts:
            transformed_area_polys[aid] = poly_verts

    log_fn(f"  ✓ Keeping ALL {len(new_areas)} areas  (structural mesh)")
    log_fn(f"  ✓ Keeping ALL {len(new_lines)} walls  (building shell)")

    for aid, area in new_areas.items():
        log_fn(f"     ✓ Area: {area.get('name', 'Unknown')} ({aid})")

    # ── Mark ALL holes as exterior-black ──────────────────────────────────────
    # Every door/window/opening gets is_exterior_black=true so the renderer
    # places a black plane in the opening. This uses geometry (holes dict),
    # NOT name-based matching.
    new_holes = {}
    for hid, hole in holes.items():
        hole_copy = dict(hole)
        hole_copy["is_exterior_black"] = True
        new_holes[hid] = hole_copy
        log_fn(f"     ⚫ Hole marked BLACK: ({hole.get('type','?')}) {hole.get('name', hid)}")

    log_fn(f"  ⚫ Marked ALL {len(new_holes)} holes as is_exterior_black=true")

    # ── Filter items ──────────────────────────────────────────────────────────
    # In exterior mode:
    #   - Keep: floor assets, exterior-named items (roof/grill/balcony),
    #           items physically outside all room polygons
    #   - Remove: EVERYTHING else (all interior items, wall fittings,
    #             frames, pictures, mirrors, etc.)
    new_items:           Dict[str, Any] = {}
    culled_items:        List[str]      = []
    kept_exterior_items: List[str]      = []

    for iid, item in items.items():
        item_type = str(item.get("type", "")).lower()
        item_name = str(item.get("name", "")).lower()
        ix, iy = _transform_plan_point_cm(
            float(item.get("x", 0)),
            float(item.get("y", 0)),
            cm_per_unit,
            rotation_radians,
            pivot,
        )

        # Always keep floor/slab assets
        if any(kw in item_type or kw in item_name for kw in FLOOR_ITEM_KEYWORDS):
            new_items[iid] = item
            log_fn(f"  🛡️ Preserving Floor Asset: '{item.get('name')}' ({iid})")
            continue

        # Always keep elevation assets - building shell geometry should never
        # disappear in video renders.
        if _is_elevation_asset(item):
            new_items[iid] = item
            log_fn(
                f"  🏛️ Preserving Elevation Asset (never culled): "
                f"'{item.get('name')}' ({iid})"
            )
            continue

        # Keep exterior-named assets (roof, grill, balcony, etc.) — by keyword
        if _is_exterior_asset_video(item):
            new_items[iid] = item
            kept_exterior_items.append(f"{item.get('name', 'Unknown')} ({iid}) [exterior keyword]")
            log_fn(
                f"  🏠 Keeping exterior-named asset: "
                f"'{item.get('name', 'Unknown')}' ({iid})"
            )
            continue

        # Item outside all room polygons → external → keep
        is_outside = True
        for poly_verts in transformed_area_polys.values():
            if _point_in_polygon(ix, iy, poly_verts):
                is_outside = False
                break
        if is_outside:
            # If it's explicitly an interior item (e.g. a bed placed on the grass), cull it.
            if _is_interior_furniture_asset_video(item):
                culled_items.append(f"{item.get('name', 'Unknown')} ({iid}) [interior keyword]")
                log_fn(f"  🗑️ Culling explicit interior item outside room: '{item.get('name', 'Unknown')}' ({iid})")
                continue

            new_items[iid] = item
            kept_exterior_items.append(f"{item.get('name', 'Unknown')} ({iid}) [outside rooms]")
            log_fn(
                f"  🌳 Keeping external item (outside all rooms): "
                f"'{item.get('name', 'Unknown')}' ({iid}) at ({ix:.1f}, {iy:.1f})"
            )
            continue

        # Everything else inside rooms → cull (no wall-fitting exceptions)
        culled_items.append(f"{item.get('name', 'Unknown')} ({iid})")
        log_fn(f"  🗑️ Culling interior item: '{item.get('name', 'Unknown')}' ({iid})")

    if kept_exterior_items:
        log_fn(f"\n  🌳 Kept {len(kept_exterior_items)} exterior items:")
        for ei in kept_exterior_items:
            log_fn(f"     + {ei}")

    if culled_items:
        log_fn(f"\n  🗑️  Culled {len(culled_items)} interior items:")
        for ci in culled_items:
            log_fn(f"     - {ci}")

    return new_vertices, new_lines, new_areas, new_items, new_holes


# ─────────────────────────────────────────────────────────────────────────────
# MAIN CLASS
# ─────────────────────────────────────────────────────────────────────────────

class VideoSceneOptimizer:
    def __init__(self, log_path: Optional[str] = None):
        """
        Initialize VideoSceneOptimizer.

        Args:
            log_path: Full path for the culling log file. If None, uses default.
        """
        if log_path is None:
            log_path = os.path.join(CULLING_LOGS_DIR, "video_culling_log.txt")

        self.log_path = log_path
        os.makedirs(os.path.dirname(self.log_path), exist_ok=True)

        try:
            with open(self.log_path, "w", encoding="utf-8") as f:
                f.write("--- Video Scene Culling Log ---\n")
        except Exception:
            pass

    def log(self, msg: str) -> None:
        print(f"[VideoSceneOptimizer] {msg}")
        try:
            with open(self.log_path, "a", encoding="utf-8") as f:
                f.write(f"{msg}\n")
        except Exception:
            pass

    def _apply_floor_visibility(
        self,
        fp_data: Dict[str, Any],
    ) -> None:
        """
        Force area floors to stay renderable.

        If a source floor is marked hidden, we still keep it visible so the
        layer above can be rendered as an occluding surface.
        """
        self.log("🏠 _apply_floor_visibility -> forcing floor visibility on ...")
        for layer_id, layer in fp_data.get("layers", {}).items():
            for area_id, area in layer.get("areas", {}).items():
                area_name = area.get("name", area_id)
                floor_props = area.get("floor_properties")
                if not isinstance(floor_props, dict):
                    floor_props = {}
                    area["floor_properties"] = floor_props

                source_visible = None
                if "visible" in floor_props:
                    source_visible = bool(floor_props.get("visible"))
                elif "isvisible" in floor_props:
                    source_visible = bool(floor_props.get("isvisible"))
                elif "isVisible" in floor_props:
                    source_visible = bool(floor_props.get("isVisible"))

                floor_props["visible"] = True
                floor_props["isvisible"] = True
                floor_props["isVisible"] = True

                self.log(
                    f"  ✅ Area '{area_name}' ({layer_id}) - floor forced visible "
                    f"(source was {source_visible})"
                )

    def cull_scene(self, payload: Dict[str, Any]) -> Dict[str, Any]:
        """
        Optimise the video render payload using two-mode culling.

        INTERIOR (any keyframe camera point is inside a room)
        ───────────────────────────────────────────────────────
        • Keep all rooms the camera enters + connected rooms via openings/hidden walls
        • Remove all exterior walls, areas, and out-of-room items
        • Textures: interior materials applied normally

        EXTERIOR (ALL keyframe camera points are outside all rooms)
        ─────────────────────────────────────────────────────────────
        • Keep all walls, areas, and holes (building shell)
        • Window/door openings render BLACK — no interior backdrop generated
        • Remove ALL interior furniture (sofa, fridge, decorations, etc.)
        • Keep: items outside room polygons + architectural wall fittings only
        • Textures: exterior-facing materials (handled by renderer)

        Returns a new payload with optimised floor_plan_data.
        """
        try:
            # ── 1. Parse floor_plan_data ──────────────────────────────────────
            fp_str = payload.get("floor_plan_data")
            if not fp_str:
                self.log("⚠️ No floor_plan_data found.")
                return payload

            if isinstance(fp_str, dict):
                fp_data = fp_str
            else:
                try:
                    fp_data = json.loads(fp_str)
                except Exception as e:
                    self.log(f"⚠️ Failed to parse floor_plan_data: {e}")
                    return payload

            self._apply_floor_visibility(fp_data)

            # ── 1a. Repair wall topology BEFORE anything reads the walls ──────
            # Shared with the image optimizer.  Welds wall endpoints that dangle
            # on a hosted/T-junction vertex onto the real room corner, so the
            # room polygon is closed for every camera sample on the path, for
            # the mitre rebuild, and for Godot's wall boxes.  A wall left
            # dangling renders short, so on video it opens and closes the room
            # as the camera moves — worse than the stills, not better.
            if isinstance(fp_data, dict):
                _welded = _repair_wall_topology(fp_data, self.log)
                if _welded:
                    self.log(
                        f"🔧 Wall topology repair: welded {_welded} dangling "
                        f"wall endpoint(s) onto room corners."
                    )

            fp_version = str(fp_data.get("version", "")).strip() if isinstance(fp_data, dict) else ""
            cm_per_unit = _resolve_scene_cm_per_unit(fp_data)
            plan_rotation_radians = _resolve_scene_rotation_radians(fp_data)
            plan_pivot_cm = _resolve_scene_plan_pivot_cm(fp_data, cm_per_unit)
            camera_cm_per_unit = _resolve_camera_cm_per_unit(payload)
            self.log(
                f"   Plan units: {cm_per_unit:.2f} cm/source unit | "
                f"camera units: {camera_cm_per_unit:.2f} cm/source unit | "
                f"rotation: {math.degrees(plan_rotation_radians):.1f}° | "
                f"pivot: ({plan_pivot_cm[0]:.1f}, {plan_pivot_cm[1]:.1f})"
            )

            # ── 2. Collect camera visibility samples from the animation path ──
            camera_samples: List[Dict[str, Any]] = []
            payload_fov_half_deg: Optional[float] = None
            if "interior_fov_half_deg" in payload:
                payload_fov_half_deg = float(payload["interior_fov_half_deg"])
            max_view_dist_cm = float(
                payload.get("interior_view_dist_cm", DEFAULT_VIEW_DISTANCE_CM)
            )

            if "video_animation" in payload and payload["video_animation"] is not None:
                anim      = payload["video_animation"]
                keyframes = anim.get("keyframes", []) if isinstance(anim, dict) else []

                if keyframes:
                    self.log("🎬 Video Animation detected. Analysing full camera path...")
                    for kf in keyframes:
                        tjs = kf.get("threejs_camera_data")
                        if tjs and isinstance(tjs, dict) and "position" in tjs:
                            pos = tjs["position"]
                            cam_x, cam_y = _transform_plan_point_cm(
                                float(pos.get("x", 0.0)),
                                float(pos.get("z", 0.0)),
                                camera_cm_per_unit,
                                plan_rotation_radians,
                                plan_pivot_cm,
                            )
                            dir_x, dir_y = 1.0, 0.0
                            look_at = tjs.get("lookAt")
                            if isinstance(look_at, dict):
                                look_x, look_y = _transform_plan_point_cm(
                                    float(look_at.get("x", pos.get("x", 0.0))),
                                    float(look_at.get("z", pos.get("z", 0.0))),
                                    camera_cm_per_unit,
                                    plan_rotation_radians,
                                    plan_pivot_cm,
                                )
                                dx = look_x - cam_x
                                dy = look_y - cam_y
                                mag = math.hypot(dx, dy)
                                if mag > 1e-6:
                                    dir_x, dir_y = dx / mag, dy / mag
                            fov_half_deg = payload_fov_half_deg
                            if fov_half_deg is None:
                                fov_half_deg = float(
                                    tjs.get("fov", DEFAULT_FOV_HALF_DEG * 2.0)
                                ) / 2.0
                            camera_samples.append({
                                "cam_x": cam_x,
                                "cam_y": cam_y,
                                "cam_dir_x": dir_x,
                                "cam_dir_y": dir_y,
                                "fov_half_deg": fov_half_deg,
                            })
                        elif "position" in kf:
                            pos = kf["position"]
                            cam_x, cam_y = _transform_plan_point_cm(
                                float(pos.get("x", 0.0)),
                                float(pos.get("z", 0.0)),
                                camera_cm_per_unit,
                                plan_rotation_radians,
                                plan_pivot_cm,
                            )
                            dir_x, dir_y = 1.0, 0.0
                            target = kf.get("target")
                            if isinstance(target, dict):
                                target_x, target_y = _transform_plan_point_cm(
                                    float(target.get("x", pos.get("x", 0.0))),
                                    float(target.get("z", pos.get("z", 0.0))),
                                    camera_cm_per_unit,
                                    plan_rotation_radians,
                                    plan_pivot_cm,
                                )
                                dx = target_x - cam_x
                                dy = target_y - cam_y
                                mag = math.hypot(dx, dy)
                                if mag > 1e-6:
                                    dir_x, dir_y = dx / mag, dy / mag
                            fov_half_deg = payload_fov_half_deg
                            if fov_half_deg is None:
                                fov_half_deg = float(
                                    kf.get("fov", DEFAULT_FOV_HALF_DEG * 2.0)
                                ) / 2.0
                            camera_samples.append({
                                "cam_x": cam_x,
                                "cam_y": cam_y,
                                "cam_dir_x": dir_x,
                                "cam_dir_y": dir_y,
                                "fov_half_deg": fov_half_deg,
                            })
                    self.log(f"   Collected {len(camera_samples)} samples from video path.")
                else:
                    self.log("ℹ️ video_animation has no keyframes. Checking static camera ...")

            # Fallback: static camera position
            if not camera_samples:
                if "threejs_camera" in payload and payload["threejs_camera"] is not None:
                    camera = payload["threejs_camera"]
                    pos = camera.get("position", {})
                    cam_x, cam_y = _transform_plan_point_cm(
                        float(pos.get("x", 0.0)),
                        float(pos.get("z", 0.0)),
                        camera_cm_per_unit,
                        plan_rotation_radians,
                        plan_pivot_cm,
                    )
                    dir_x, dir_y = 1.0, 0.0
                    target = camera.get("target")
                    if isinstance(target, dict):
                        target_x, target_y = _transform_plan_point_cm(
                            float(target.get("x", pos.get("x", 0.0))),
                            float(target.get("z", pos.get("z", 0.0))),
                            camera_cm_per_unit,
                            plan_rotation_radians,
                            plan_pivot_cm,
                        )
                        dx = target_x - cam_x
                        dy = target_y - cam_y
                        mag = math.hypot(dx, dy)
                        if mag > 1e-6:
                            dir_x, dir_y = dx / mag, dy / mag
                    fov_half_deg = payload_fov_half_deg
                    if fov_half_deg is None:
                        fov_half_deg = float(
                            camera.get("fov", DEFAULT_FOV_HALF_DEG * 2.0)
                        ) / 2.0
                    camera_samples.append({
                        "cam_x": cam_x,
                        "cam_y": cam_y,
                        "cam_dir_x": dir_x,
                        "cam_dir_y": dir_y,
                        "fov_half_deg": fov_half_deg,
                    })
                    self.log(f"📍 Using static ThreeJS camera: ({cam_x:.1f}, {cam_y:.1f})")
                else:
                    self.log("⚠️ No camera data found. Skipping optimization.")
                    return payload

            # ── 3. Resolve layer/flat structure ───────────────────────────────
            layers           = fp_data.get("layers", {})
            is_flat          = False
            show_all_floors  = bool(fp_data.get("showAllFloors", True))

            if layers:
                selected_layer_id = fp_data.get("selectedLayer", "layer-1")
                target_layer_id = _pick_primary_layer_id(layers, selected_layer_id)

                self.log(f"🏗️ showAllFloors = {show_all_floors}")
                
                totals = dict(
                    areas_before=0, areas_after=0,
                    items_before=0, items_after=0,
                    lines_before=0, lines_after=0,
                    holes_before=0, holes_after=0,
                )
                final_render_mode = "UNKNOWN"
                total_active_rooms = 0
                
                for layer_id, layer in layers.items():
                    if not show_all_floors and layer_id != target_layer_id:
                        self.log(f"  ⏭️ SKIPPED — layer '{layer_id}' is not the selected layer.")
                        layer["vertices"] = {}
                        layer["lines"]    = {}
                        layer["areas"]    = {}
                        layer["items"]    = {}
                        layer["holes"]    = {}
                        layer["render_mode"] = "SKIPPED"
                        continue

                    self.log(f"\n{'─'*60}")
                    self.log(f"🔍 Inspecting Layer: {layer_id}")
                    self.log(f"{'─'*60}")

                    if not show_all_floors and layer_id == target_layer_id:
                        original_altitude = layer.get("altitude", 0)
                        if isinstance(original_altitude, dict):
                            original_altitude = original_altitude.get("length", 0)
                        try:
                            original_altitude_value = float(original_altitude)
                        except Exception:
                            original_altitude_value = 0.0
                        if abs(original_altitude_value) > 1e-6:
                            self.log(
                                f"ℹ️ Flattening selected layer '{layer.get('name', target_layer_id)}' "
                                f"altitude {original_altitude_value} to 0 for video render."
                            )
                        layer["altitude"] = 0

                    vertices = layer.get("vertices", {})
                    lines    = layer.get("lines",    {})
                    areas    = layer.get("areas",    {})
                    items    = layer.get("items",    {})
                    holes    = layer.get("holes",    {})
                    
                    cull_vertices = {
                        vid: _transform_plan_point_cm(
                            float(v.get("x", 0.0)),
                            float(v.get("y", 0.0)),
                            cm_per_unit,
                            plan_rotation_radians,
                            plan_pivot_cm,
                        )
                        for vid, v in vertices.items()
                        if isinstance(v, dict)
                    }

                    # Pre-compute room bounding boxes
                    area_bboxes = {}
                    for area_id, area in areas.items():
                        poly_verts = []
                        for v_id in area.get("vertices", []):
                            v = cull_vertices.get(str(v_id), cull_vertices.get(v_id))
                            if v:
                                poly_verts.append((float(v[0]), float(v[1])) if isinstance(v, tuple) else (float(v.get("x", 0)), float(v.get("y", 0))))
                        if poly_verts:
                            xs = [p[0] for p in poly_verts]
                            ys = [p[1] for p in poly_verts]
                            area_bboxes[area_id] = (min(xs), max(xs), min(ys), max(ys), poly_verts)

                    # Determine active rooms
                    active_area_ids = set()
                    active_samples = []
                    for i, sample in enumerate(camera_samples):
                        cx = float(sample["cam_x"])
                        cy = float(sample["cam_y"])
                        for area_id, (min_x, max_x, min_y, max_y, poly_verts) in area_bboxes.items():
                            if min_x <= cx <= max_x and min_y <= cy <= max_y:
                                if _point_in_polygon(cx, cy, poly_verts):
                                    sample_copy = sample.copy()
                                    sample_copy["active_area_id"] = area_id
                                    active_samples.append(sample_copy)
                                    active_area_ids.add(area_id)
                                    break

                    if active_area_ids:
                        render_mode = "INTERIOR"
                        self.log(f"  🏠 MODE: INTERIOR VIDEO RENDER (Camera enters {len(active_area_ids)} room(s) along path in layer {layer_id})")
                        portal_samples = active_samples
                        if len(active_area_ids) == 1 and len(active_samples) > 1:
                            portal_samples = [active_samples[0]]
                        new_vertices, new_lines, new_areas, new_items, new_holes = _cull_interior_video(
                            active_area_ids, portal_samples, vertices, lines, areas, items, holes,
                            cm_per_unit, plan_rotation_radians, plan_pivot_cm, self.log,
                            max_view_dist_cm=max_view_dist_cm, item_samples=active_samples,
                            strict_room_limit=STRICT_IMAGE_PORTAL_ROOM_LIMIT
                        )
                    else:
                        render_mode = "EXTERIOR"
                        self.log(f"  🌍 MODE: EXTERIOR VIDEO RENDER (Layer {layer_id})")
                        new_vertices, new_lines, new_areas, new_items, new_holes = _cull_exterior_video(
                            vertices, lines, areas, items, holes,
                            cm_per_unit, plan_rotation_radians, plan_pivot_cm, self.log
                        )

                    layer["vertices"] = new_vertices
                    layer["lines"]    = new_lines
                    layer["areas"]    = new_areas
                    layer["items"]    = new_items
                    layer["holes"]    = new_holes
                    if "structures" in layer:
                        layer["structures"] = dict(layer.get("structures", {}))
                    if "customLights" in layer:
                        layer["customLights"] = dict(layer.get("customLights", {}))
                    if "sceneLights" in layer:
                        layer["sceneLights"] = dict(layer.get("sceneLights", {}))
                    layer["render_mode"] = render_mode

                    totals["areas_before"] += len(areas)
                    totals["areas_after"]  += len(new_areas)
                    totals["items_before"] += len(items)
                    totals["items_after"]  += len(new_items)
                    totals["lines_before"] += len(lines)
                    totals["lines_after"]  += len(new_lines)
                    totals["holes_before"] += len(holes)
                    totals["holes_after"]  += len(new_holes)
                    total_active_rooms += len(active_area_ids) if render_mode == "INTERIOR" else 0
                    if render_mode != "SKIPPED":
                        final_render_mode = render_mode

            else:
                is_flat = True
                self.log("ℹ️ No 'layers' key found. Trying flat structure...")
                
                totals = dict(
                    areas_before=0, areas_after=0,
                    items_before=0, items_after=0,
                    lines_before=0, lines_after=0,
                    holes_before=0, holes_after=0,
                )
                final_render_mode = "UNKNOWN"
                total_active_rooms = 0

                def list_to_dict(obj):
                    if isinstance(obj, list):
                        return {i.get("id"): i for i in obj if isinstance(i, dict) and i.get("id")}
                    return obj if isinstance(obj, dict) else {}

                vertices = list_to_dict(fp_data.get("vertices", {}))
                lines    = list_to_dict(fp_data.get("lines",    {}))
                areas    = list_to_dict(fp_data.get("areas",    {}))
                items    = list_to_dict(fp_data.get("items",    {}))
                holes    = list_to_dict(fp_data.get("holes",    {}))
                cull_vertices = {
                    vid: _transform_plan_point_cm(
                        float(v.get("x", 0.0)),
                        float(v.get("y", 0.0)),
                        cm_per_unit,
                        plan_rotation_radians,
                        plan_pivot_cm,
                    )
                    for vid, v in vertices.items()
                    if isinstance(v, dict)
                }

                if not vertices and not areas:
                    self.log("⚠️ No vertices or areas found. Skipping.")
                else:
                    # Pre-compute room bounding boxes
                    area_bboxes = {}
                    for area_id, area in areas.items():
                        poly_verts = []
                        for v_id in area.get("vertices", []):
                            v = cull_vertices.get(str(v_id), cull_vertices.get(v_id))
                            if v:
                                poly_verts.append((float(v[0]), float(v[1])) if isinstance(v, tuple) else (float(v.get("x", 0)), float(v.get("y", 0))))
                        if poly_verts:
                            xs = [p[0] for p in poly_verts]
                            ys = [p[1] for p in poly_verts]
                            area_bboxes[area_id] = (min(xs), max(xs), min(ys), max(ys), poly_verts)

                    # Determine active rooms
                    active_area_ids = set()
                    active_samples = []
                    for i, sample in enumerate(camera_samples):
                        cx = float(sample["cam_x"])
                        cy = float(sample["cam_y"])
                        for area_id, (min_x, max_x, min_y, max_y, poly_verts) in area_bboxes.items():
                            if min_x <= cx <= max_x and min_y <= cy <= max_y:
                                if _point_in_polygon(cx, cy, poly_verts):
                                    sample_copy = sample.copy()
                                    sample_copy["active_area_id"] = area_id
                                    active_samples.append(sample_copy)
                                    active_area_ids.add(area_id)
                                    break

                    if active_area_ids:
                        render_mode = "INTERIOR"
                        portal_samples = active_samples
                        if len(active_area_ids) == 1 and len(active_samples) > 1:
                            portal_samples = [active_samples[0]]
                        new_vertices, new_lines, new_areas, new_items, new_holes = _cull_interior_video(
                            active_area_ids, portal_samples, vertices, lines, areas, items, holes,
                            cm_per_unit, plan_rotation_radians, plan_pivot_cm, self.log,
                            max_view_dist_cm=max_view_dist_cm, item_samples=active_samples,
                            strict_room_limit=STRICT_IMAGE_PORTAL_ROOM_LIMIT
                        )
                    else:
                        render_mode = "EXTERIOR"
                        new_vertices, new_lines, new_areas, new_items, new_holes = _cull_exterior_video(
                            vertices, lines, areas, items, holes,
                            cm_per_unit, plan_rotation_radians, plan_pivot_cm, self.log
                        )

                    def dict_to_list_if_was_list(key, new_dict):
                        return list(new_dict.values()) if isinstance(fp_data.get(key), list) else new_dict
                        
                    fp_data["vertices"] = dict_to_list_if_was_list("vertices", new_vertices)
                    fp_data["lines"]    = dict_to_list_if_was_list("lines",    new_lines)
                    fp_data["areas"]    = dict_to_list_if_was_list("areas",    new_areas)
                    fp_data["items"]    = dict_to_list_if_was_list("items",    new_items)
                    fp_data["holes"]    = dict_to_list_if_was_list("holes",    new_holes)
                    fp_data["render_mode"] = render_mode
                    
                    totals["areas_before"] = len(areas)
                    totals["areas_after"]  = len(new_areas)
                    totals["items_before"] = len(items)
                    totals["items_after"]  = len(new_items)
                    totals["lines_before"] = len(lines)
                    totals["lines_after"]  = len(new_lines)
                    totals["holes_before"] = len(holes)
                    totals["holes_after"]  = len(new_holes)
                    total_active_rooms = len(active_area_ids) if render_mode == "INTERIOR" else 0
                    final_render_mode = render_mode

            self.log(f"\n{'='*60}")
            self.log(f"📊 VIDEO CULLING SUMMARY  [{final_render_mode}]")
            self.log(f"{'='*60}")
            self.log(f"  Render Mode: {final_render_mode}")
            self.log(f"  Camera path samples analysed: {len(camera_samples)}")
            if final_render_mode == "INTERIOR":
                self.log(f"  Active rooms (camera enters): {total_active_rooms}")
            self.log(f"  Areas:  {totals['areas_before']} → {totals['areas_after']}  (removed {totals['areas_before'] - totals['areas_after']})")
            self.log(f"  Items:  {totals['items_before']} → {totals['items_after']}  (removed {totals['items_before'] - totals['items_after']})")
            self.log(f"  Lines:  {totals['lines_before']} → {totals['lines_after']}  (removed {totals['lines_before'] - totals['lines_after']})")
            self.log(f"  Holes:  {totals['holes_before']} → {totals['holes_after']}  (removed {totals['holes_before'] - totals['holes_after']})")
            self.log(f"{'='*60}")

            # ── 9. Return new payload ─────────────────────────────────────────
            new_payload = payload.copy()
            new_payload["floor_plan_data"] = (
                fp_data if isinstance(fp_str, dict) else json.dumps(fp_data)
            )
            return new_payload

        except Exception as exc:
            self.log(f"❌ Error during video scene culling: {exc}")
            import traceback
            traceback.print_exc()
            return payload  # Fail-safe: return original
