#!/usr/local/tkni/pyvenv/clusteringVENV/bin/python
##!/app/ni/miniconda3/envs/clusteringVENV/bin/python

import argparse
import nibabel as nib
import numpy as np
import os
import time
from scipy import ndimage as ndi
from sklearn.mixture import GaussianMixture


def estimate_reference_values(intensities, num_classes, max_samples=500_000, random_state=42):
    """
    Fits a 1D Gaussian Mixture Model to estimate tissue class means and spreads.
    Subsamples large high-res volumes for speed without losing distributional accuracy.
    """
    if intensities.size > max_samples:
        rng = np.random.default_rng(random_state)
        sample_data = rng.choice(intensities, size=max_samples, replace=False).reshape(-1, 1)
    else:
        sample_data = intensities.reshape(-1, 1)

    gmm = GaussianMixture(
        n_components=num_classes,
        covariance_type="full",
        n_init=3,
        random_state=random_state,
    )
    gmm.fit(sample_data)

    means = gmm.means_.flatten()
    stds = np.sqrt(gmm.covariances_.flatten())

    # Sort from darkest to brightest tissue class so class indices are deterministic
    sort_idx = np.argsort(means)
    return means[sort_idx].astype(np.float32), stds[sort_idx].astype(np.float32)


def compute_softmax_probabilities(values, ref_values, class_sigmas):
    """Computes softmax probabilities over negative squared distances."""
    diffs = values[:, np.newaxis] - ref_values[np.newaxis, :]
    squared_dist = diffs ** 2
    scaled_scores = -squared_dist / (2.0 * (class_sigmas[np.newaxis, :] ** 2))
    exp_scores = np.exp(scaled_scores - np.max(scaled_scores, axis=1, keepdims=True))
    return exp_scores / np.sum(exp_scores, axis=1, keepdims=True)


def compute_tissue_probabilities(
    image_path,
    label_path,
    output_path,
    values_str=None,
    num_clusters=None,
    mask_path=None,
    sigma=None,
    max_label_output=None,
    cluster_wise=False,
    clip_percentiles=(0.5, 99.5),
):
    start_time = time.time()

    if values_str is None and num_clusters is None:
        raise ValueError("Must specify either --values (-v) or --num-clusters (-k).")

    # 1. Load Data
    print(f"-> Loading Intensity Image: {image_path}")
    img = nib.load(image_path)
    image_data = img.get_fdata().astype(np.float32)

    print(f"-> Loading Cluster/Label Map: {label_path}")
    label_img = nib.load(label_path)
    label_data = label_img.get_fdata().astype(np.int32)

    # 2. Masking
    if mask_path:
        print(f"-> Loading Mask: {mask_path}")
        mask_data = nib.load(mask_path).get_fdata() > 0
    else:
        mask_data = label_data > 0

    valid_indices = mask_data & (label_data > 0)
    intensities = image_data[valid_indices]

    if intensities.size == 0:
        raise ValueError("No valid voxels found inside mask and positive labels.")

    # 3. Parse or Auto-Estimate Reference Values & Sigmas
    estimated_stds = None
    if values_str is not None:
        try:
            ref_values = np.array(
                [float(v.strip()) for v in values_str.split(",")], dtype=np.float32
            )
        except ValueError as e:
            raise ValueError(
                f"Invalid comma-delimited values format: '{values_str}'. "
                "Expected numbers separated by commas (e.g., '50,150,250')."
            ) from e
        num_classes = len(ref_values)
        print(f"-> User-specified tissue values ({num_classes} classes): {ref_values}")
    else:
        if num_clusters < 2:
            raise ValueError("--num-clusters (-k) must be at least 2.")
        print(f"-> Auto-estimating {num_clusters} reference tissue classes via 1D GMM...")
        lo, hi = np.percentile(intensities, clip_percentiles)
        clipped_intensities = np.clip(intensities, lo, hi)
        ref_values, estimated_stds = estimate_reference_values(
            clipped_intensities, num_clusters
        )
        num_classes = num_clusters
        print(f"-> Estimated tissue means (dark -> bright): {np.round(ref_values, 4)}")
        print(f"-> Estimated tissue stds:                   {np.round(estimated_stds, 4)}")

    # 4. Determine Sigma if not explicitly provided
    if sigma is not None:
        class_sigmas = np.full(num_classes, float(sigma), dtype=np.float32)
        print(f"-> Using user-specified sigma: {sigma:.4f}")
    elif estimated_stds is not None:
        min_std = max(float(np.std(intensities)) * 0.05, 1e-5)
        class_sigmas = np.maximum(estimated_stds, min_std)
        print(f"-> Using GMM per-class sigmas: {np.round(class_sigmas, 4)}")
    else:
        if num_classes > 1:
            auto_sigma = float(np.mean(np.diff(np.sort(ref_values))) / 2.0)
            if auto_sigma <= 0:
                auto_sigma = float(np.std(intensities)) * 0.25
        else:
            auto_sigma = float(np.std(intensities)) * 0.25
        class_sigmas = np.full(num_classes, auto_sigma, dtype=np.float32)
        print(f"-> Auto-calculated Gaussian spread (sigma): {auto_sigma:.4f}")

    # 5. Calculate Probabilities (Cluster-Wise or Voxel-Wise)
    shape_4d = image_data.shape + (num_classes,)
    prob_4d = np.zeros(shape_4d, dtype=np.float32)

    if cluster_wise:
        print("-> Calculating cluster-wise median intensities and tissue probabilities...")
        masked_labels = np.where(valid_indices, label_data, 0)
        unique_labels = np.unique(masked_labels[masked_labels > 0])
        print(f"-> Evaluating {len(unique_labels)} unique clusters...")

        # Compute median intensity per cluster (robust against micro-vessels/noise)
        cluster_medians = ndi.labeled_comprehension(
            image_data, masked_labels, unique_labels, np.median, np.float32, 0.0
        )

        # Score each cluster once
        cluster_probs = compute_softmax_probabilities(
            cluster_medians, ref_values, class_sigmas
        )

        # Build fast lookup tables to map cluster probabilities back to 3D volume
        max_lbl = int(unique_labels.max())
        for c in range(num_classes):
            prob_lut = np.zeros(max_lbl + 1, dtype=np.float32)
            prob_lut[unique_labels] = cluster_probs[:, c]
            prob_4d[..., c] = prob_lut[masked_labels]

        if max_label_output:
            max_dir = os.path.dirname(max_label_output)
            if max_dir:
                os.makedirs(max_dir, exist_ok=True)
            print(f"-> Computing and saving cluster-wise max probability label map to: {max_label_output}")
            class_lut = np.zeros(max_lbl + 1, dtype=np.int32)
            class_lut[unique_labels] = np.argmax(cluster_probs, axis=1) + 1
            max_label_vol = class_lut[masked_labels]

            max_label_img = nib.Nifti1Image(max_label_vol, img.affine, img.header)
            nib.save(max_label_img, max_label_output)

    else:
        print("-> Calculating voxel-wise tissue probabilities across clusters...")
        probabilities = compute_softmax_probabilities(
            intensities, ref_values, class_sigmas
        )

        for c in range(num_classes):
            class_vol = np.zeros(image_data.shape, dtype=np.float32)
            class_vol[valid_indices] = probabilities[:, c]
            prob_4d[..., c] = class_vol

        if max_label_output:
            max_dir = os.path.dirname(max_label_output)
            if max_dir:
                os.makedirs(max_dir, exist_ok=True)
            print(f"-> Computing and saving voxel-wise max probability label map to: {max_label_output}")
            argmax_indices = np.argmax(probabilities, axis=1)
            max_label_vol = np.zeros(image_data.shape, dtype=np.int32)
            max_label_vol[valid_indices] = argmax_indices + 1

            max_label_img = nib.Nifti1Image(max_label_vol, img.affine, img.header)
            nib.save(max_label_img, max_label_output)

    # 6. Save Output 4D NIfTI Probability Map
    out_dir = os.path.dirname(output_path)
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)
    print(f"-> Saving multi-volume probability map to: {output_path}")
    out_img = nib.Nifti1Image(prob_4d, img.affine, img.header)
    nib.save(out_img, output_path)

    print(f"Done! Total time: {time.time() - start_time:.2f}s")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="""
TKNI Cluster Tissue Probability Estimator
--------------------------------------------------------------------------------
Computes tissue probabilities within clusters based on either user-specified
reference intensity values (-v) OR automatic intensity estimation for a target
number of tissue classes (-k) using a 1D Gaussian Mixture Model.

Use --cluster-wise to classify each entire watershed cluster as a single unit
(based on its median intensity) rather than evaluating individual voxels.
        """,
        formatter_class=argparse.RawTextHelpFormatter,
    )
    parser.add_argument(
        "-i", "--image", required=True, help="Input intensity NIfTI volume (e.g., ex vivo SWI)."
    )
    parser.add_argument(
        "-l", "--label", required=True, help="Input label/cluster NIfTI volume."
    )

    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument(
        "-v",
        "--values",
        help="Comma-delimited reference values for tissue types (e.g., '50,150,250').",
    )
    group.add_argument(
        "-k",
        "--num-clusters",
        type=int,
        help="Number of tissue classes to automatically estimate from image intensities\n"
             "(e.g., -k 3 for dark WM, transition/vessels, and bright GM).",
    )

    parser.add_argument(
        "-m", "--mask", help="Optional binary mask NIfTI to restrict analysis."
    )
    parser.add_argument(
        "-s",
        "--sigma",
        type=float,
        help="Optional global Gaussian spread (sigma). Overrides automatic/GMM sigma.",
    )
    parser.add_argument(
        "--cluster-wise",
        action="store_true",
        help="Evaluate each watershed cluster as a whole using its median intensity,\n"
        "assigning all voxels within a cluster the same probability and label.",
    )
    parser.add_argument(
        "-o",
        "--output",
        required=True,
        help="Output path for the multi-volume 4D probability NIfTI.",
    )
    parser.add_argument(
        "--max-label-output",
        help="Optional output path for a 3D label NIfTI where each voxel/cluster is\n"
        "assigned to its maximum probability tissue type (1-indexed, dark to bright).",
    )

    args = parser.parse_args()
    compute_tissue_probabilities(
        image_path=args.image,
        label_path=args.label,
        output_path=args.output,
        values_str=args.values,
        num_clusters=args.num_clusters,
        mask_path=args.mask,
        sigma=args.sigma,
        max_label_output=args.max_label_output,
        cluster_wise=args.cluster_wise,
    )