#!/usr/bin/env python3
"""Detect an external calibration target and prepare an observation for VPX Studio."""

import argparse
from datetime import datetime, timezone
import json
from pathlib import Path

import cv2
import numpy as np


def checkerboard(image, columns, rows, origin, next_x):
    found, corners = cv2.findChessboardCornersSB(image, (columns, rows), cv2.CALIB_CB_NORMALIZE_IMAGE)
    if not found:
        raise ValueError("Full checkerboard was not detected.")
    grid = corners.reshape(rows, columns, 2)
    candidates = [grid, grid[::-1], grid[:, ::-1], grid[::-1, ::-1]]
    if columns == rows:
        candidates += [candidate.transpose(1, 0, 2) for candidate in candidates]
    # Both supplied points must be closest to their corresponding detected intersections.
    flat = grid.reshape(-1, 2)
    origin_index = np.argmin(np.linalg.norm(flat - origin, axis=1))
    next_index = np.argmin(np.linalg.norm(flat - next_x, axis=1))
    matches = [candidate for candidate in candidates
               if np.array_equal(candidate[0, 0], flat[origin_index])
               and np.array_equal(candidate[0, 1], flat[next_index])]
    if len(matches) != 1:
        raise ValueError("Specify the first inner corner and its adjacent corner in the board +X direction.")
    edge = np.linalg.norm(flat[origin_index] - flat[next_index])
    if max(np.linalg.norm(flat[origin_index] - origin),
           np.linalg.norm(flat[next_index] - next_x)) >= edge * 0.5:
        raise ValueError("Orientation landmarks are too far from the detected corners.")
    return matches[0].reshape(-1, 2)


def april_tag(image, tag_id):
    if not hasattr(getattr(cv2, "aruco", None), "ArucoDetector"):
        raise ValueError("AprilTag detection requires OpenCV Contrib 4.7 or later.")
    aruco = cv2.aruco
    dictionary = aruco.getPredefinedDictionary(aruco.DICT_APRILTAG_36h11)
    parameters = aruco.DetectorParameters()
    parameters.cornerRefinementMethod = aruco.CORNER_REFINE_SUBPIX
    corners, ids, _ = aruco.ArucoDetector(dictionary, parameters).detectMarkers(image)
    matches = [] if ids is None else [corner for corner, marker in zip(corners, ids.ravel()) if marker == tag_id]
    if len(matches) != 1:
        raise ValueError(f"Expected exactly one AprilTag 36h11 with ID {tag_id}.")
    # OpenCV uses TL, TR, BR, BL in tag coordinates. VPX expects row-major.
    return matches[0].reshape(4, 2)[[0, 1, 3, 2]]


def check_pose(points, columns, rows, pitch, camera, focus):
    board = np.array([
        ((col - (columns - 1) / 2) * pitch, ((rows - 1) / 2 - row) * pitch, 0)
        for row in range(rows) for col in range(columns)
    ])
    breathing = camera.get("breathing", [])
    factor = 1
    if breathing:
        distances = [sample["focusMeters"] for sample in breathing]
        if focus is None or not distances[0] <= focus <= distances[-1]:
            raise ValueError("Focus distance must be within the profile breathing table.")
        focal_lengths = [sample["focalLengthMillimeters"] for sample in breathing]
        factor = np.interp(focus, distances, focal_lengths) / camera["referenceFocalLengthMillimeters"]
    matrix = np.array([[camera["fx"] * factor, 0, camera["cx"]],
                       [0, camera["fy"] * factor, camera["cy"]], [0, 0, 1]], dtype=float)
    distortion = np.array([camera.get(key, 0) for key in ("k1", "k2", "p1", "p2", "k3")], dtype=float)
    _, rotations, translations, _ = cv2.solvePnPGeneric(
        board, points.astype(float), matrix, distortion, flags=cv2.SOLVEPNP_IPPE
    )
    errors = []
    for rotation, translation in zip(rotations, translations):
        in_camera = board @ cv2.Rodrigues(rotation)[0].T + translation.reshape(3)
        if not np.all(np.isfinite(in_camera)) or not np.all(in_camera[:, 2] > 0.01):
            continue
        # The target normal points out of the printed face, towards the camera.
        if np.dot(cv2.Rodrigues(rotation)[0][:, 2], translation.ravel()) >= 0:
            continue
        projected, _ = cv2.projectPoints(board, rotation, translation, matrix, distortion)
        residuals = np.linalg.norm(projected.reshape(-1, 2) - points, axis=1)
        rms = float(np.sqrt(np.mean(residuals ** 2)))
        if np.isfinite(rms):
            errors.append(rms)
    errors.sort()
    if not errors or errors[0] > 2:
        raise ValueError("No front-facing target pose within the reprojection threshold.")
    if len(errors) > 1 and errors[1] - errors[0] <= 0.25:
        raise ValueError("Ambiguous planar pose. Retake the image at a more oblique angle.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", required=True, type=Path)
    parser.add_argument("--stage-from-target", required=True, type=Path,
                        help="JSON array with 16 column-major target-to-stage values")
    parser.add_argument("--measured-at", required=True, help="Acquisition time in ISO 8601 with a timezone")
    parser.add_argument("--size-meters", required=True, type=float,
                        help="Square pitch for a checkerboard, outside black-edge length for AprilTag")
    parser.add_argument("--focus-meters", type=float)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("image", type=Path)
    targets = parser.add_subparsers(dest="target", required=True)
    board = targets.add_parser("checkerboard")
    board.add_argument("--columns", type=int, required=True)
    board.add_argument("--rows", type=int, required=True)
    board.add_argument("--first-corner", type=float, nargs=2, required=True, metavar=("X", "Y"))
    board.add_argument("--next-x-corner", type=float, nargs=2, required=True, metavar=("X", "Y"))
    tag = targets.add_parser("apriltag")
    tag.add_argument("--id", type=int, required=True)
    args = parser.parse_args()

    try:
        profile = json.loads(args.profile.read_text())
        stage = json.loads(args.stage_from_target.read_text())
        transform = np.array(stage, dtype=float).reshape(4, 4, order="F")
        axes = transform[:3, :3]
        if (not isinstance(stage, list) or len(stage) != 16 or not np.isfinite(transform).all()
                or not np.allclose(transform[3], [0, 0, 0, 1], atol=1e-5)
                or not np.allclose(axes.T @ axes, np.eye(3), atol=1e-4)
                or not np.isclose(np.linalg.det(axes), 1, atol=1e-4)):
            raise ValueError("Stage transform must be a column-major rigid 4x4 matrix.")
        measured = datetime.fromisoformat(args.measured_at.replace("Z", "+00:00"))
        expires = datetime.fromisoformat(profile["expiresAt"].replace("Z", "+00:00"))
        now = datetime.now(timezone.utc)
        if measured.tzinfo is None or not measured <= now < expires:
            raise ValueError("Invalid measurement time or expired profile.")
        if not 0.001 <= args.size_meters <= 1 or (args.focus_meters is not None
                and not (np.isfinite(args.focus_meters) and args.focus_meters > 0)):
            raise ValueError("Invalid target size or focus distance.")

        image = cv2.imread(str(args.image), cv2.IMREAD_GRAYSCALE | cv2.IMREAD_IGNORE_ORIENTATION)
        camera = profile["camera"]
        if image is None or image.shape != (camera["imageHeight"], camera["imageWidth"]):
            raise ValueError("Use an unrotated raw image matching the profile dimensions.")
        if args.target == "checkerboard":
            columns, rows = args.columns, args.rows
            if (not 3 <= columns <= 20 or not 3 <= rows <= 20
                    or (max(columns, rows) - 1) * args.size_meters > 10
                    or not np.isfinite(args.first_corner + args.next_x_corner).all()):
                raise ValueError("Invalid checkerboard geometry or orientation landmarks.")
            points = checkerboard(image, columns, rows, args.first_corner, args.next_x_corner)
        else:
            if not 0 <= args.id < 587:
                raise ValueError("AprilTag 36h11 ID must be between 0 and 586.")
            columns = rows = 2
            points = april_tag(image, args.id)

        if (not np.isfinite(points).all() or np.any(points < 0)
                or np.any(points >= np.array(image.shape[::-1]))
                or np.any(np.ptp(points, axis=0) < 20)):
            raise ValueError("The full target must be inside the image and span at least 20 pixels on each axis.")
        check_pose(points, columns, rows, args.size_meters, camera, args.focus_meters)
        observation = {
            "schemaVersion": 1, "cameraID": profile["cameraID"], "lensID": profile["lensID"],
            "intrinsicsReference": {"id": profile["id"], "revision": profile["revision"]},
            "imageWidth": image.shape[1], "imageHeight": image.shape[0], "columns": columns, "rows": rows,
            "squareSizeMeters": args.size_meters, "stageFromBoard": stage,
            "imagePoints": [{"x": float(x), "y": float(y)} for x, y in points],
            "measuredAt": measured.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "expiresAt": profile["expiresAt"], "focusDistanceMeters": args.focus_meters,
        }
        if args.target == "apriltag":
            observation["aprilTag36h11ID"] = args.id
        content = json.dumps(observation, indent=2, allow_nan=False) + "\n"
        with args.output.open("x", encoding="utf-8") as output:
            output.write(content)
    except (ValueError, OSError, KeyError, TypeError, cv2.error) as error:
        parser.exit(1, f"{error}\n")
    print(f"{args.output}: {len(points)} points. Import the observation with the matching profile in VPX Studio.")


if __name__ == "__main__":
    main()
