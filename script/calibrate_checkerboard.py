#!/usr/bin/env python3
"""Generate an importable VPX Studio profile from checkerboard photographs."""

import argparse
from datetime import datetime, timedelta, timezone
import json
import math
import os
from pathlib import Path
from tempfile import NamedTemporaryFile
import uuid

import cv2
import numpy as np


def calibrate(images, columns, rows, square_size):
    if not 6 <= len(images) <= 40 or not 3 <= columns <= 20 or not 3 <= rows <= 20:
        raise ValueError("Use 6–40 distinct images and 3–20 inner corners per axis.")
    if not 0.001 <= square_size <= 1 or square_size * (max(columns, rows) - 1) > 10:
        raise ValueError("Invalid checkerboard square size or board extent.")
    if len({path.resolve() for path in images}) != len(images):
        raise ValueError("An input image was selected more than once.")

    size = None
    observations = []
    for path in images:
        image = cv2.imread(str(path), cv2.IMREAD_GRAYSCALE | cv2.IMREAD_IGNORE_ORIENTATION)
        if image is None:
            raise ValueError(f"Cannot read image: {path}")
        dimensions = (image.shape[1], image.shape[0])
        if max(dimensions) > 16384 or (size is not None and size != dimensions):
            raise ValueError(f"Inconsistent or unsupported image dimensions: {path}")
        size = dimensions
        # Detect on a bounded-resolution image, then refine in the original pixels.
        scale = min(1, 1800 / max(size))
        detection = image
        if scale < 1:
            detection = cv2.resize(image, None, fx=scale, fy=scale, interpolation=cv2.INTER_AREA)
        found, corners = cv2.findChessboardCornersSB(
            detection, (columns, rows), cv2.CALIB_CB_NORMALIZE_IMAGE
        )
        if not found:
            raise ValueError(f"Full checkerboard was not detected: {path}")
        if scale < 1:
            ratio = np.array(size, dtype=np.float32) / detection.shape[::-1]
            corners = ((corners + 0.5) * ratio - 0.5).astype(np.float32)
            criteria = (cv2.TERM_CRITERIA_EPS | cv2.TERM_CRITERIA_MAX_ITER, 30, 0.01)
            cv2.cornerSubPix(image, corners, (5, 5), (-1, -1), criteria)
        observations.append(corners)

    # A narrow set of image locations cannot constrain the distortion reliably.
    coverage = np.ptp(np.concatenate(observations).reshape(-1, 2), axis=0) / size
    if np.any(coverage < 0.55):
        raise ValueError("Spread corners across at least 55% of both image axes.")

    board = np.zeros((rows * columns, 3), np.float32)
    board[:, :2] = np.mgrid[0:columns, 0:rows].T.reshape(-1, 2) * square_size
    rmse, matrix, distortion, rotations, translations = cv2.calibrateCamera(
        [board] * len(images), observations, size, None, None
    )
    normals = np.array([cv2.Rodrigues(rotation)[0][:, 2] for rotation in rotations])
    # Align normals before measuring tilt diversity, since the board is unmarked.
    normals *= np.where(normals[:, 2:3] < 0, -1, 1)
    tilt = np.linalg.svd(normals[:, :2] - normals[:, :2].mean(axis=0), compute_uv=False)
    if tilt[-1] / math.sqrt(len(images)) < 0.06:
        raise ValueError("Tilt the checkerboard in both directions across views.")

    view_rmses = []
    maximum = 0.0
    for corners, rotation, translation in zip(observations, rotations, translations):
        projected, _ = cv2.projectPoints(board, rotation, translation, matrix, distortion)
        errors = np.linalg.norm(projected - corners, axis=2).ravel()
        view_rmses.append(float(np.sqrt(np.mean(errors ** 2))))
        maximum = max(maximum, float(np.max(errors)))
    fx, fy, cx, cy = matrix[0, 0], matrix[1, 1], matrix[0, 2], matrix[1, 2]
    k1, k2, p1, p2, k3 = distortion.ravel()
    if not (size[0] * 0.01 <= fx <= size[0] * 100 and size[1] * 0.01 <= fy <= size[1] * 100
            and 0 <= cx <= size[0] and 0 <= cy <= size[1]
            and all(abs(value) <= 10 for value in [k1, k2, k3, p1, p2])):
        raise ValueError("Estimated intrinsic parameters are outside VPX limits.")
    if not (0 <= rmse <= 2 and maximum <= 5 and all(0 <= value <= 2 for value in view_rmses)):
        raise ValueError(f"Reprojection error too high: RMS {rmse:.2f}px, max {maximum:.2f}px.")

    return {
        "imageWidth": size[0], "imageHeight": size[1],
        "fx": float(fx), "fy": float(fy), "cx": float(cx), "cy": float(cy),
        "k1": float(k1), "k2": float(k2), "k3": float(k3), "p1": float(p1), "p2": float(p2),
    }, rmse, {
        "method": "checkerboard-multiview-v1", "columns": columns, "rows": rows,
        "squareSizeMeters": square_size, "viewRMSEPixels": view_rmses,
        "maximumResidualPixels": maximum, "reprojectionRMSEPixels": rmse,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--camera-id", required=True, type=uuid.UUID)
    parser.add_argument("--lens-id", required=True)
    parser.add_argument("--columns", required=True, type=int)
    parser.add_argument("--rows", required=True, type=int)
    parser.add_argument("--square-meters", required=True, type=float)
    parser.add_argument("--focal-mm", required=True, type=float)
    parser.add_argument("--valid-days", required=True, type=int)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("images", nargs="+", type=Path)
    args = parser.parse_args()
    if not (args.lens_id.strip() and len(args.lens_id) <= 256
            and 0 < args.focal_mm <= 10000 and 1 <= args.valid_days <= 3650):
        parser.error("Specify a valid lens ID, physical focal length and validity in days.")
    try:
        if args.output.exists() or args.output.suffix.lower() != ".json":
            raise ValueError("Output must be a new .json file.")
        intrinsics, rmse, measurement = calibrate(
            args.images, args.columns, args.rows, args.square_meters
        )
        now = datetime.now(timezone.utc).replace(microsecond=0)
        profile = {
            "schemaVersion": 2, "id": str(uuid.uuid4()), "revision": 1,
            "cameraID": str(args.camera_id), "lensID": args.lens_id,
            "validatedAt": now.isoformat(), "expiresAt": (now + timedelta(days=args.valid_days)).isoformat(),
            "reprojectionRMSEPixels": rmse, "sampleCount": args.columns * args.rows * len(args.images),
            "stageConvention": "RH-m-Yup-minusZ",
            "intrinsicsMeasurement": measurement,
            "camera": {
                "schemaVersion": 1, "name": "Checkerboard intrinsics", "source": "measured",
                **intrinsics, "referenceFocalLengthMillimeters": args.focal_mm,
                "worldFromCamera": [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1],
                "breathing": [],
            },
        }
        content = json.dumps(profile, indent=2, allow_nan=False) + "\n"
        temporary = NamedTemporaryFile(dir=args.output.parent, delete=False, mode="w", encoding="utf-8")
        path = Path(temporary.name)
        try:
            with temporary:
                temporary.write(content)
            os.link(path, args.output)
        finally:
            path.unlink()
    except (ValueError, OSError, cv2.error) as error:
        parser.exit(1, f"{error}\n")
    print(f"{args.output} — {len(args.images)} views, RMS {rmse:.2f}px")


if __name__ == "__main__":
    main()
