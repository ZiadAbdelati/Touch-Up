#!/usr/bin/env python3
"""Fit independent and affine touch mappings from calibrator CSV output."""

from __future__ import annotations

import csv
import math
import sys
from pathlib import Path


def solve(matrix: list[list[float]], vector: list[float]) -> list[float]:
    size = len(vector)
    augmented = [row[:] + [value] for row, value in zip(matrix, vector)]
    for column in range(size):
        pivot = max(range(column, size), key=lambda row: abs(augmented[row][column]))
        augmented[column], augmented[pivot] = augmented[pivot], augmented[column]
        divisor = augmented[column][column]
        if abs(divisor) < 1e-12:
            raise ValueError("calibration points are singular")
        augmented[column] = [value / divisor for value in augmented[column]]
        for row in range(size):
            if row == column:
                continue
            factor = augmented[row][column]
            augmented[row] = [a - factor * b for a, b in zip(augmented[row], augmented[column])]
    return [augmented[row][-1] for row in range(size)]


def least_squares(features: list[list[float]], values: list[float]) -> list[float]:
    columns = len(features[0])
    normal = [[sum(row[i] * row[j] for row in features) for j in range(columns)]
              for i in range(columns)]
    rhs = [sum(row[i] * value for row, value in zip(features, values))
           for i in range(columns)]
    return solve(normal, rhs)


def error_summary(predicted: list[tuple[float, float]], expected: list[tuple[float, float]]) -> tuple[float, float]:
    errors = [math.hypot(px - ex, py - ey)
              for (px, py), (ex, ey) in zip(predicted, expected)]
    return math.sqrt(sum(error * error for error in errors) / len(errors)), max(errors)


def main() -> int:
    path = Path(sys.argv[1] if len(sys.argv) > 1 else "/tmp/rack-touch-calibration.csv")
    with path.open(newline="", encoding="utf-8") as stream:
        rows = [{key: float(value) for key, value in row.items()}
                for row in csv.DictReader(stream)]
    if len(rows) < 6:
        raise SystemExit("not enough calibration samples")

    expected = [(row["target_x"], row["target_y"]) for row in rows]
    raw_x = [row["raw_x"] for row in rows]
    raw_y = [row["raw_y"] for row in rows]

    x_line = least_squares([[value, 1.0] for value in raw_x], [point[0] for point in expected])
    y_line = least_squares([[value, 1.0] for value in raw_y], [point[1] for point in expected])
    linear_predicted = [(x_line[0] * x + x_line[1], y_line[0] * y + y_line[1])
                        for x, y in zip(raw_x, raw_y)]
    linear_rmse, linear_max = error_summary(linear_predicted, expected)

    features = [[x, y, 1.0] for x, y in zip(raw_x, raw_y)]
    affine_x = least_squares(features, [point[0] for point in expected])
    affine_y = least_squares(features, [point[1] for point in expected])
    affine_predicted = [(sum(coefficient * value for coefficient, value in zip(affine_x, row)),
                         sum(coefficient * value for coefficient, value in zip(affine_y, row)))
                        for row in features]
    affine_rmse, affine_max = error_summary(affine_predicted, expected)

    min_x = -x_line[1] / x_line[0]
    max_x = (1280.0 - x_line[1]) / x_line[0]
    min_y = -y_line[1] / y_line[0]
    max_y = (400.0 - y_line[1]) / y_line[0]

    print(f"samples: {len(rows)}")
    print(f"independent bounds: X {min_x:.3f}..{max_x:.3f}, Y {min_y:.3f}..{max_y:.3f}")
    print(f"independent residual: RMSE {linear_rmse:.2f}px, max {linear_max:.2f}px")
    print("affine screen X = " + " + ".join(f"{value:.9f}*{name}" for value, name in zip(affine_x, ("rawX", "rawY", "1"))))
    print("affine screen Y = " + " + ".join(f"{value:.9f}*{name}" for value, name in zip(affine_y, ("rawX", "rawY", "1"))))
    print(f"affine residual: RMSE {affine_rmse:.2f}px, max {affine_max:.2f}px")
    print("\nper-point residuals:")
    for expected_point, predicted in zip(expected, affine_predicted):
        error = math.hypot(predicted[0] - expected_point[0], predicted[1] - expected_point[1])
        print(f"  target {expected_point[0]:4.0f},{expected_point[1]:3.0f} -> "
              f"{predicted[0]:7.2f},{predicted[1]:6.2f} ({error:5.2f}px)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
