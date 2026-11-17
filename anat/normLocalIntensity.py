#!/usr/local/tkni/pyvenv/clusteringVENV/bin/python
##!/app/ni/miniconda3/envs/clusteringVENV/bin/python

import argparse
import os
import time
import nibabel as nib
import numpy as np
from scipy import ndimage as ndi


def run_local_norm(
    nii_image,
    nii_mask,
    nii_out,
    radius_mm,
    clip_lo,
    clip_hi,
    zscore_mode,
):
    start_time = time.time()

    # 1. Load Data
    print(f"-> Loading intensity NIfTI: {nii_image}")
    img = nib.load(nii_image)
    image_data = img.get_fdata().astype(np.float32)

    print(f"-> Loading mask NIfTI: {nii_mask}")
    mask_data = (nib.load(nii_mask).get_fdata() > 0).astype(np.float32)

    # Convert physical radius (mm) to voxel sigmas per axis
    zooms = np.array(img.header.get_zooms()[:3], dtype=np.float32)
    sigma_vox = radius_mm / zooms
    print(f"-> Voxel spacing (mm): {zooms} | Kernel sigma (voxels): {np.round(sigma_vox, 2)}")

    # 2. Clamp extreme outliers inside mask
    valid = mask_data > 0
    lo, hi = np.percentile(image_data[valid], [clip_lo, clip_hi])
    clamped = np.clip(image_data, lo, hi) * mask_data

    # 3. Masked Normalized Convolution (prevents dark background bleeding into cortex)
    print("-> Computing masked local neighborhood mean...")
    weight_sum = ndi.gaussian_filter(mask_data, sigma=sigma_vox, mode="constant", cval=0.0)
    val_sum = ndi.gaussian_filter(clamped, sigma=sigma_vox, mode="constant", cval=0.0)

    local_mean = np.zeros_like(image_data)
    safe_weights = weight_sum > 1e-5
    local_mean[safe_weights] = val_sum[safe_weights] / weight_sum[safe_weights]

    diff = (clamped - local_mean) * mask_data

    if zscore_mode:
        print("-> Computing local neighborhood standard deviation (local Z-score)...")
        sq_diff_sum = ndi.gaussian_filter(diff ** 2, sigma=sigma_vox, mode="constant", cval=0.0)
        local_var = np.zeros_like(image_data)
        local_var[safe_weights] = sq_diff_sum[safe_weights] / weight_sum[safe_weights]
        local_std = np.sqrt(np.maximum(local_var, 1e-8))

        out_data = np.zeros_like(image_data)
        out_data[valid] = diff[valid] / local_std[valid]
    else:
        out_data = diff

    # 4. Save
    out_dir = os.path.dirname(nii_out)
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)
    print(f"-> Saving locally normalized volume to: {nii_out}")
    nib.save(nib.Nifti1Image(out_data.astype(np.float32), img.affine, img.header), nii_out)
    print(f"Done! Total time: {time.time() - start_time:.2f}s")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="""
TKNI Masked Local Intensity Normalizer
--------------------------------------------------------------------------------
Removes macro-scale intensity gradients (e.g., regional iron drift or uneven
fixation in ex vivo SWI) using masked normalized Gaussian convolution.
Prevents background air/agar from creating dark edge halos around the pial surface.
        """,
        formatter_class=argparse.RawTextHelpFormatter,
    )
    parser.add_argument("-i", "--image", required=True, help="Input intensity NIfTI.")
    parser.add_argument("-m", "--mask", required=True, help="Binary brain mask NIfTI.")
    parser.add_argument("-o", "--output", required=True, help="Output normalized NIfTI.")
    parser.add_argument(
        "-r",
        "--radius-mm",
        type=float,
        default=5.0,
        help="Neighborhood smoothing radius in millimeters (default: 5.0 mm).\n"
             "Should be ~1.5x to 2x expected cortical thickness so local GM > 0 and WM < 0.",
    )
    parser.add_argument(
        "--no-zscore",
        action="store_true",
        help="Output only (Image - LocalMean) instead of dividing by LocalSD.",
    )
    parser.add_argument("--clip-lo", type=float, default=1.0, help="Lower percentile clamp (default: 1.0).")
    parser.add_argument("--clip-hi", type=float, default=99.0, help="Upper percentile clamp (default: 99.0).")

    args = parser.parse_args()
    run_local_norm(
        args.image,
        args.mask,
        args.output,
        args.radius_mm,
        args.clip_lo,
        args.clip_hi,
        zscore_mode=not args.no_zscore,
    )
