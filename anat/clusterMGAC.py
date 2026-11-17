#!/usr/local/tkni/pyvenv/clusteringVENV/bin/python
##!/app/ni/miniconda3/envs/clusteringVENV/bin/python

import argparse
import time
import nibabel as nib
import numpy as np
from skimage.segmentation import (
    morphological_geodesic_active_contour,
    inverse_gaussian_gradient,
)
from scipy import ndimage as ndi


def run_mgac(
    nii_image,
    nii_mask,
    nii_init,
    nii_out,
    iterations,
    smoothing,
    balloon,
    threshold,
    alpha,
    sigma,
    init_labels,
    clip_lo,
    clip_hi,
):
    start_time = time.time()

    # 1. Load Data
    print(f"-> Loading intensity NIfTI: {nii_image}")
    img = nib.load(nii_image)
    image_array = img.get_fdata().astype(np.float32)

    print(f"-> Loading mask NIfTI: {nii_mask}")
    mask_array = nib.load(nii_mask).get_fdata() > 0

    print(f"-> Loading initial label/seed NIfTI: {nii_init}")
    init_array = nib.load(nii_init).get_fdata().astype(np.int32)

    # 2. Standardize Intensity within Mask
    print("-> Standardizing intensity values")
    masked_vals = image_array[mask_array]
    lo, hi = np.percentile(masked_vals, [clip_lo, clip_hi])
    image_norm = np.clip(image_array, lo, hi)
    # Rescale to [0, 1] for inverse_gaussian_gradient stability
    image_norm = (image_norm - lo) / (hi - lo + 1e-8)
    image_norm *= mask_array

    # 3. Compute Edge-Stopping Potential g(I)
    # High values (near 1) in homogeneous regions; low values (near 0) at edges
    print(f"-> Computing inverse Gaussian gradient (alpha={alpha}, sigma={sigma})...")
    gimage = inverse_gaussian_gradient(image_norm, alpha=alpha, sigma=sigma)
    # Enforce hard stop outside brain mask
    gimage *= mask_array

    # 4. Prepare Initial Level Set
    if init_labels is not None and len(init_labels) > 0:
        print(f"-> Extracting initial level set from labels: {init_labels}")
        init_ls = np.isin(init_array, init_labels).astype(np.int8)
    else:
        print("-> Using all non-zero voxels in initial label map as seed")
        init_ls = (init_array > 0).astype(np.int8)

    if np.sum(init_ls) == 0:
        raise ValueError("Initial level set is empty. Check --init or --labels arguments.")

    # 5. Run 3D Morphological Geodesic Active Contour
    print(
        f"-> Running 3D MGAC (iterations={iterations}, smoothing={smoothing}, "
        f"balloon={balloon}, threshold={threshold})..."
    )
    evolving_ls = morphological_geodesic_active_contour(
        gimage,
        num_iter=iterations,
        init_level_set=init_ls,
        smoothing=smoothing,
        threshold=threshold,
        balloon=balloon,
    )

    # Restrict strictly to mask
    final_mask = (evolving_ls > 0) & mask_array

    # 6. Label Contiguous Components & Sort by Volume
    print("-> Labeling contiguous 3D structures and sorting by volume...")
    labeled_out, num_features = ndi.label(final_mask)

    if num_features > 0:
        unique, counts = np.unique(labeled_out[labeled_out > 0], return_counts=True)
        sorted_indices = np.argsort(-counts)
        sorted_labels = unique[sorted_indices]

        lookup = np.zeros(int(labeled_out.max()) + 1, dtype=np.int32)
        for rank, old_label in enumerate(sorted_labels):
            lookup[int(old_label)] = rank + 1
        sorted_final = lookup[labeled_out]
    else:
        sorted_final = labeled_out.astype(np.int32)

    # 7. Save
    print(f"-> Saving to: {nii_out}")
    nib.save(nib.Nifti1Image(sorted_final.astype(np.int32), img.affine), nii_out)
    print(
        f"Done! Extracted {num_features} smooth contiguous structure(s). "
        f"Total time: {time.time() - start_time:.2f}s"
    )


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="""
TKNI Morphological Geodesic Active Contours (MGAC)
--------------------------------------------------------------------------------
Refines over-segmented watershed/RAG clusters into smooth anatomical structures
(such as the cerebral cortex) in high-resolution ex vivo NIfTI volumes.
Uses curvature smoothing to bridge internal intensity drift while stopping at
strong anatomical boundaries.
        """,
        formatter_class=argparse.RawTextHelpFormatter,
    )
    parser.add_argument(
        "-i", "--image", required=True, help="Input intensity NIfTI (e.g., ex vivo SWI)."
    )
    parser.add_argument(
        "-m", "--mask", required=True, help="Binary brain/tissue mask NIfTI."
    )
    parser.add_argument(
        "-l",
        "--init",
        required=True,
        help="Initial seed/label NIfTI (e.g., sorted watershed or RAG output).",
    )
    parser.add_argument(
        "-o", "--output", required=True, help="Output NIfTI path for smoothed contours."
    )
    parser.add_argument(
        "--labels",
        nargs="+",
        type=int,
        default=None,
        help="Specific label ID(s) from --init to use as the starting contour.\n"
             "Example: --labels 1 2 3 (useful if watershed sorted largest cortical basins first).\n"
             "If omitted, uses all voxels > 0 in --init.",
    )
    parser.add_argument(
        "--iterations",
        type=int,
        default=150,
        help="Number of evolution iterations (default: 150).",
    )
    parser.add_argument(
        "--smoothing",
        type=int,
        default=3,
        help="Curvature smoothing steps per iteration (default: 3).\n"
             "Higher values (3-5) enforce smoother cortical ribbons and absorb small noise.",
    )
    parser.add_argument(
        "--balloon",
        type=float,
        default=1.0,
        help="Balloon force driving contour expansion/contraction (default: 1.0).\n"
             "Use positive values (0.5 to 2.0) to expand seeds outward into the cortex;\n"
             "use negative values (-1.0) to shrink an over-inclusive mask inward.",
    )
    parser.add_argument(
        "-t",
        "--threshold",
        default="auto",
        help="Edge-stopping threshold on g(I) (default: 'auto').\n"
             "Pass a float (e.g., 0.3 - 0.6) if 'auto' leaks across weak GM/WM borders.",
    )
    parser.add_argument(
        "--alpha",
        type=float,
        default=100.0,
        help="Steepness of edge-stopping gradient (default: 100.0).\n"
             "Increase if cortical boundaries have low contrast.",
    )
    parser.add_argument(
        "--sigma",
        type=float,
        default=1.5,
        help="Gaussian smoothing sigma for gradient calculation in voxels (default: 1.5).\n"
             "Scale up (e.g., 2.0 - 3.0) for ultra-high-res sub-millimeter ex vivo scans.",
    )
    parser.add_argument(
        "--clip-lo",
        type=float,
        default=2.5,
        help="Lower percentile for intensity clamping (default: 2.5).",
    )
    parser.add_argument(
        "--clip-hi",
        type=float,
        default=97.5,
        help="Upper percentile for intensity clamping (default: 97.5).",
    )

    args = parser.parse_args()

    # Convert threshold to float if not 'auto'
    thresh_val = args.threshold if args.threshold == "auto" else float(args.threshold)

    run_mgac(
        args.image,
        args.mask,
        args.init,
        args.output,
        args.iterations,
        args.smoothing,
        args.balloon,
        thresh_val,
        args.alpha,
        args.sigma,
        args.labels,
        args.clip_lo,
        args.clip_hi,
    )
