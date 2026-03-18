#!/usr/local/tkni/pyvenv/clusteringVENV/bin/python
import argparse
import nibabel as nib
import numpy as np
import time
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from scipy.interpolate import UnivariateSpline

def slab_debiasing(data, mask, plane='z', metric='median', spline_order=3, smoothness_factor=1.0, qc_path=None):
    """
    Corrects intensity gradients by treating the fitted spline as the Bias Field.
    Formula: Corrected = Data * (Global_Median / Spline_Trend)
    """
    # Map plane to axis index
    plane_map = {'x': 0, 'y': 1, 'z': 2}
    axis = plane_map.get(plane.lower(), 2)

    # Reorder data so the looping axis is always at the end (index 2)
    data_work = np.moveaxis(data, axis, -1)
    mask_work = np.moveaxis(mask, axis, -1)

    n_slices = data_work.shape[-1]
    stats = []

    # 1. Collect slice-wise statistics
    for s in range(n_slices):
        slice_voxels = data_work[..., s][mask_work[..., s] > 0]
        if slice_voxels.size > 10:
            val = np.median(slice_voxels) if metric == 'median' else np.mean(slice_voxels)
            stats.append(val)
        else:
            stats.append(np.nan)

    stats = np.array(stats)
    indices = np.arange(n_slices)
    valid = ~np.isnan(stats)

    if not np.any(valid):
        print("Warning: No valid data found in mask.")
        return data, np.ones_like(data)

    # 2. Fit Spline (The estimated Bias Field Profile)
    # s param controls residual tolerance.
    # Default 1.0 * n_slices allows flexible fitting to catch steep boundary drops.
    s_param = n_slices * smoothness_factor

    spline = UnivariateSpline(indices[valid], stats[valid], k=spline_order, s=s_param)
    trend = spline(indices)

    # Calculate Global Reference (Target Intensity)
    global_ref = np.nanmedian(stats)

    # --- EDGE PROTECTION ---
    # If the trend drops < 10% of the global median, assume we are exiting the brain.
    threshold = global_ref * 0.1

    # 3. Generate QC Plot
    if qc_path:
        plt.figure(figsize=(12, 6))
        plt.scatter(indices[valid], stats[valid], color='black', s=10, alpha=0.3, label='Slice Stats')
        plt.plot(indices, trend, color='#d62728', linewidth=2.0, label=f'Bias Model (s={s_param:.1f})')
        plt.axhline(global_ref, color='blue', linestyle='--', alpha=0.5, label='Global Target')

        plt.title(f"Bias Field Fit | Plane: {plane.upper()} | Smoothness: {smoothness_factor}")
        plt.xlabel("Slice Index")
        plt.ylabel("Intensity")
        plt.legend()
        plt.grid(True, alpha=0.3)
        plt.tight_layout()
        plt.savefig(qc_path, dpi=150)
        plt.close()
        print(f"-> QC plot saved to: {qc_path}")

    # 4. Compute Correction Field & Apply
    corrected_work = np.copy(data_work)
    field_work = np.ones_like(data_work, dtype=np.float32)

    for s in range(n_slices):
        # Only correct if we have a valid trend value above the safety threshold
        if valid[s] and trend[s] > threshold:
            # FACTOR = TARGET / OBSERVED_TREND
            # If trend dips to 80, and target is 100, factor is 1.25 (boost signal)
            scale_factor = global_ref / trend[s]

            # Clamp factor to avoid extreme amplifications at very edges
            scale_factor = np.clip(scale_factor, 0.2, 5.0)

            corrected_work[..., s] *= scale_factor
            field_work[..., s] = scale_factor
        else:
            field_work[..., s] = 1.0

    # Move axis back
    corrected_final = np.moveaxis(corrected_work, -1, axis)
    field_final = np.moveaxis(field_work, -1, axis)

    return corrected_final, field_final

def run_slab_correction(input_path, mask_path, output_path, field_path=None, plane='z', metric='median', order=3, smoothness=1.0, qc_path=None):
    start_time = time.time()

    print(f"-> Loading images...")
    img = nib.load(input_path)
    data = img.get_fdata()
    mask = nib.load(mask_path).get_fdata() > 0

    print(f"-> Computing bias field (axis: {plane}, smoothness: {smoothness})...")
    corrected_data, correction_field = slab_debiasing(
        data,
        mask,
        plane=plane,
        metric=metric,
        spline_order=order,
        smoothness_factor=smoothness,
        qc_path=qc_path
    )

    print(f"-> Saving corrected image to {output_path}...")
    # Note: Background masking removed per request.
    final_img = nib.Nifti1Image(corrected_data.astype(np.float32), img.affine, img.header)
    nib.save(final_img, output_path)

    if field_path:
        print(f"-> Saving correction field to {field_path}...")
        field_img = nib.Nifti1Image(correction_field.astype(np.float32), img.affine, img.header)
        nib.save(field_img, field_path)

    print(f"Done! Total time: {time.time() - start_time:.2f}s")

if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="""
TKNI Slab Debiasing & Gradient Correction
-----------------------------------------
Removes 1D intensity gradients (bias fields) and slab boundary artifacts
by fitting a smooth spline to slice-wise statistics.

Key Features:
- Spline-based "N4-style" correction constrained to the slice axis.
- "Stitches" slab boundaries by normalizing local trends.
- Preserves local anatomical contrast better than global equalization.
        """,
        formatter_class=argparse.RawTextHelpFormatter
    )
    parser.add_argument("-i", "--input", required=True, help="Input NIfTI volume.")
    parser.add_argument("-m", "--mask", required=True, help="Binary brain mask.")
    parser.add_argument("-o", "--output", required=True, help="Output path.")
    parser.add_argument("-f", "--field", help="Optional path to save the correction field.")
    parser.add_argument("-p", "--plane", default="z", choices=['x', 'y', 'z'], help="Slice plane (default: z).")
    parser.add_argument("--metric", default="median", choices=['median', 'mean'], help="Statistic (default: median).")
    parser.add_argument("--order", type=int, default=3, help="Spline order (default: 3).")
    parser.add_argument("--smoothness", type=float, default=1.0, help="Stiffness of fit. Lower = flexible (hits drops), Higher = smooth. Default: 1.0")
    parser.add_argument("--qc", help="Path to save QC PNG.")

    args = parser.parse_args()
    run_slab_correction(args.input, args.mask, args.output, args.field, args.plane, args.metric, args.order, args.smoothness, args.qc)
