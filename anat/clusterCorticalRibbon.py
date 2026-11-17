#!/usr/local/tkni/pyvenv/clusteringVENV/bin/python
##!/app/ni/miniconda3/envs/clusteringVENV/bin/python

import argparse
import os
import time
import nibabel as nib
import numpy as np
from scipy import ndimage as ndi


def extract_cortical_ribbon(
    nii_image,
    nii_mask,
    nii_label,
    nii_out,
    min_depth_mm,
    max_depth_mm,
    core_depth_mm,
    z_thresh,
    bright_cortex=True,
    keep_cluster_ids=False,
):
    start_time = time.time()

    # 1. Load Data
    print(f"-> Loading intensity NIfTI: {nii_image}")
    img = nib.load(nii_image)
    image_data = img.get_fdata().astype(np.float32)

    print(f"-> Loading brain mask NIfTI: {nii_mask}")
    mask_data = nib.load(nii_mask).get_fdata() > 0

    print(f"-> Loading watershed label NIfTI: {nii_label}")
    label_data = nib.load(nii_label).get_fdata().astype(np.int32)

    zooms = img.header.get_zooms()[:3]
    print(f"-> Voxel spacing (mm): {zooms}")

    # 2. Compute Physical Distance Inward from Pial/Mask Surface (in mm)
    print("-> Computing inward Euclidean Distance Transform from mask surface...")
    depth_mm = ndi.distance_transform_edt(mask_data, sampling=zooms).astype(np.float32)

    # 3. Estimate Deep Core (White Matter) Reference Statistics
    core_mask = mask_data & (depth_mm >= core_depth_mm)
    if np.sum(core_mask) < 50:
        raise ValueError(
            f"Deep core mask (>= {core_depth_mm} mm) is empty or too small. "
            "Reduce --core-depth-mm for smaller brains/slabs."
        )

    core_vals = image_data[core_mask]
    core_median = float(np.median(core_vals))
    # Robust MAD-based standard deviation
    core_mad = float(np.median(np.abs(core_vals - core_median))) * 1.4826
    core_mad = max(core_mad, 1e-6)
    print(f"-> Deep core (>= {core_depth_mm} mm) median: {core_median:.4f} | robust SD: {core_mad:.4f}")

    # 4. Evaluate Each Watershed Cluster on Depth & Intensity Contrast
    valid_labels = np.where(mask_data, label_data, 0)
    unique_labels = np.unique(valid_labels[valid_labels > 0])
    print(f"-> Evaluating {len(unique_labels)} clusters for cortical ribbon membership...")

    cluster_depths = ndi.labeled_comprehension(
        depth_mm, valid_labels, unique_labels, np.median, np.float32, -1.0
    )
    cluster_intensities = ndi.labeled_comprehension(
        image_data, valid_labels, unique_labels, np.median, np.float32, 0.0
    )

    # Check depth band
    in_depth_band = (cluster_depths >= min_depth_mm) & (cluster_depths <= max_depth_mm)

    # Check intensity relative to deep white matter core
    if bright_cortex:
        # Ex vivo SWI: Gray matter is brighter than white matter
        has_cortical_contrast = cluster_intensities >= (core_median + z_thresh * core_mad)
    else:
        # Standard T1: Gray matter is darker than white matter
        has_cortical_contrast = cluster_intensities <= (core_median - z_thresh * core_mad)

    is_cortex = in_depth_band & has_cortical_contrast
    kept_labels = unique_labels[is_cortex]
    print(f"-> Retained {len(kept_labels)} / {len(unique_labels)} cortical clusters")

    # 5. Reconstruct Output Volume
    max_lbl = int(unique_labels.max()) if unique_labels.size > 0 else 0
    lut = np.zeros(max_lbl + 1, dtype=np.int32)
    if keep_cluster_ids:
        lut[kept_labels] = kept_labels
    else:
        lut[kept_labels] = 1

    ribbon_vol = lut[valid_labels]

    # 6. Save
    out_dir = os.path.dirname(nii_out)
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)
    print(f"-> Saving cortical ribbon segmentation to: {nii_out}")
    nib.save(nib.Nifti1Image(ribbon_vol, img.affine, img.header), nii_out)
    print(f"Done! Total time: {time.time() - start_time:.2f}s")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="""
TKNI Cortical Ribbon Geometry Extractor
--------------------------------------------------------------------------------
Groups watershed clusters into a continuous cerebral cortex mask using physical
depth from the outer brain surface (EDT in mm) combined with intensity contrast
against the deep subcortical white-matter core.
        """,
        formatter_class=argparse.RawTextHelpFormatter,
    )
    parser.add_argument("-i", "--image", required=True, help="Input intensity NIfTI (e.g., debiased ex vivo SWI).")
    parser.add_argument("-m", "--mask", required=True, help="Binary outer brain/pial mask NIfTI.")
    parser.add_argument("-l", "--label", required=True, help="Input watershed cluster NIfTI.")
    parser.add_argument("-o", "--output", required=True, help="Output cortical ribbon NIfTI.")
    parser.add_argument(
        "--min-depth-mm",
        type=float,
        default=0.0,
        help="Minimum cluster median depth from pial surface in mm (default: 0.0).",
    )
    parser.add_argument(
        "--max-depth-mm",
        type=float,
        default=4.5,
        help="Maximum cluster median depth from pial surface in mm (default: 4.5 for human cortex).\n"
             "Adjust for species (e.g., ~1.5-2.0 mm for rodent, ~2.5-3.5 mm for macaque).",
    )
    parser.add_argument(
        "--core-depth-mm",
        type=float,
        default=6.0,
        help="Depth threshold (mm) defining deep white matter core reference (default: 6.0).",
    )
    parser.add_argument(
        "-z",
        "--z-thresh",
        type=float,
        default=0.5,
        help="Minimum robust SD difference from deep white matter core (default: 0.5).\n"
             "Lower to 0.0 or -0.25 if high-iron cortical areas are darker.",
    )
    parser.add_argument(
        "--dark-cortex",
        action="store_true",
        help="Set if cortex is darker than white matter (e.g., in vivo T1w instead of ex vivo SWI).",
    )
    parser.add_argument(
        "--keep-cluster-ids",
        action="store_true",
        help="Preserve original watershed cluster IDs instead of merging into binary mask (1).",
    )

    args = parser.parse_args()
    extract_cortical_ribbon(
        args.image,
        args.mask,
        args.label,
        args.output,
        args.min_depth_mm,
        args.max_depth_mm,
        args.core_depth_mm,
        args.z_thresh,
        bright_cortex=not args.dark_cortex,
        keep_cluster_ids=args.keep_cluster_ids,
    )
