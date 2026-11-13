#!/usr/local/tkni/pyvenv/clusteringVENV/bin/python
import argparse
import nibabel as nib
import numpy as np
import time

def compute_tissue_probabilities(image_path, label_path, values_str, output_path, mask_path=None, sigma=None):
    start_time = time.time()

    # 1. Parse Reference Values
    try:
        ref_values = np.array([float(v.strip()) for v in values_str.split(',')], dtype=np.float32)
    except ValueError as e:
        raise ValueError(f"Invalid comma-delimited values format: '{values_str}'. Expected numbers separated by commas (e.g., '50,150,250').") from e

    num_classes = len(ref_values)
    print(f"-> Reference tissue values ({num_classes} classes): {ref_values}")

    # 2. Load Data
    print(f"-> Loading Intensity Image: {image_path}")
    img = nib.load(image_path)
    image_data = img.get_fdata().astype(np.float32)

    print(f"-> Loading Cluster/Label Map: {label_path}")
    label_img = nib.load(label_path)
    label_data = label_img.get_fdata().astype(np.int32)

    # 3. Masking
    if mask_path:
        print(f"-> Loading Mask: {mask_path}")
        mask_data = nib.load(mask_path).get_fdata() > 0
    else:
        mask_data = label_data > 0

    # 4. Determine Sigma if not provided
    if sigma is None:
        # Default spread based on the spacing between reference values or image std
        if num_classes > 1:
            sigma = float(np.mean(np.diff(np.sort(ref_values))) / 2.0)
            if sigma <= 0:
                sigma = np.std(image_data[mask_data]) * 0.25
        else:
            sigma = np.std(image_data[mask_data]) * 0.25
        print(f"-> Auto-calculated Gaussian spread (sigma): {sigma:.4f}")

    # 5. Calculate Probabilities per Voxel (Softmax over negative squared distances)
    print("-> Calculating tissue probabilities across clusters...")

    # Initialize 4D output array: (X, Y, Z, num_classes)
    shape_4d = image_data.shape + (num_classes,)
    prob_4d = np.zeros(shape_4d, dtype=np.float32)

    # Restrict computation to valid mask region
    valid_indices = mask_data & (label_data > 0)
    intensities = image_data[valid_indices]

    # Compute squared Euclidean distances to each reference value
    # distances shape: (N_voxels, num_classes)
    diffs = intensities[:, np.newaxis] - ref_values[np.newaxis, :]
    squared_dist = diffs ** 2

    # Convert distances to probabilities using a Gaussian kernel + softmax normalization
    # Subtracting min for numerical stability in exponentiation
    scaled_scores = -squared_dist / (2.0 * (sigma ** 2))
    exp_scores = np.exp(scaled_scores - np.max(scaled_scores, axis=1, keepdims=True))
    probabilities = exp_scores / np.sum(exp_scores, axis=1, keepdims=True)

    # Populate 4D array
    for c in range(num_classes):
        class_vol = np.zeros(image_data.shape, dtype=np.float32)
        class_vol[valid_indices] = probabilities[:, c]
        prob_4d[..., c] = class_vol

    # 6. Save Output 4D NIfTI
    print(f"-> Saving multi-volume probability map to: {output_path}")
    out_img = nib.Nifti1Image(prob_4d, img.affine, img.header)
    nib.save(out_img, output_path)

    print(f"Done! Generated {num_classes} probability volumes. Total time: {time.time() - start_time:.2f}s")

if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="""
TKNI Cluster Tissue Probability Estimator
--------------------------------------------------------------------------------
This tool computes voxel-wise tissue probabilities within clusters based on
user-specified reference intensity values. It outputs a 4D NIfTI volume where
each volume corresponds to the probability of association with a specific tissue type.
        """,
        formatter_class=argparse.RawTextHelpFormatter
    )
    parser.add_argument("-i", "--image", required=True,
                        help="Input intensity NIfTI volume (e.g., T1 scan).")
    parser.add_argument("-l", "--label", required=True,
                        help="Input label/cluster NIfTI volume.")
    parser.add_argument("-v", "--values", required=True,
                        help="Comma-delimited reference values for tissue types (e.g., '50,150,250').")
    parser.add_argument("-m", "--mask",
                        help="Optional binary mask NIfTI to restrict analysis.")
    parser.add_argument("-s", "--sigma", type=float,
                        help="Gaussian kernel spread (sigma). Controls sensitivity of probability decay.\n"
                             "If omitted, estimated automatically from the reference values.")
    parser.add_argument("-o", "--output", required=True,
                        help="Output path for the multi-volume 4D probability NIfTI.")

    args = parser.parse_args()
    compute_tissue_probabilities(args.image, args.label, args.values, args.output, args.mask, args.sigma)
