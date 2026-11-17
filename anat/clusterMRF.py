#!/usr/local/tkni/pyvenv/clusteringVENV/bin/python
##!/app/ni/miniconda3/envs/clusteringVENV/bin/python

import argparse
import os
import time
import nibabel as nib
import numpy as np
from scipy import ndimage as ndi
from skimage import graph


def run_superpixel_mrf(
    nii_prob,
    nii_label,
    nii_out,
    nii_image=None,
    beta=1.5,
    edge_sensitivity=5.0,
    max_iter=25,
):
    start_time = time.time()

    # 1. Load Data
    print(f"-> Loading 4D probability NIfTI: {nii_prob}")
    prob_img = nib.load(nii_prob)
    prob_4d = prob_img.get_fdata().astype(np.float32)
    num_classes = prob_4d.shape[-1]

    print(f"-> Loading watershed label NIfTI: {nii_label}")
    label_data = nib.load(nii_label).get_fdata().astype(np.int32)

    valid_mask = label_data > 0
    unique_labels = np.unique(label_data[valid_mask])
    num_nodes = len(unique_labels)
    print(f"-> Found {num_nodes} clusters across {num_classes} tissue classes")

    # Map arbitrary cluster IDs to contiguous 0..N-1 indices
    max_lbl = int(unique_labels.max())
    id_to_idx = np.full(max_lbl + 1, -1, dtype=np.int32)
    id_to_idx[unique_labels] = np.arange(num_nodes, dtype=np.int32)

    # 2. Extract Unary Data Cost per Cluster: -log(P(class | cluster))
    print("-> Computing cluster-wise unary data energies...")
    unary_probs = np.zeros((num_nodes, num_classes), dtype=np.float32)
    for c in range(num_classes):
        unary_probs[:, c] = ndi.labeled_comprehension(
            prob_4d[..., c], label_data, unique_labels, np.mean, np.float32, 1e-6
        )

    unary_probs = np.clip(unary_probs, 1e-6, 1.0)
    unary_probs /= np.sum(unary_probs, axis=1, keepdims=True)
    unary_cost = -np.log(unary_probs)

    # 3. Build Boundary-Weighted Region Adjacency Graph
    print("-> Building Region Adjacency Graph (RAG)...")
    if nii_image is not None:
        print(f"-> Weighting edges using intensity gradient from: {nii_image}")
        img_data = nib.load(nii_image).get_fdata().astype(np.float32)
        lo, hi = np.percentile(img_data[valid_mask], [2.0, 98.0])
        img_norm = np.clip((img_data - lo) / (hi - lo + 1e-8), 0.0, 1.0)
        grad_mag = ndi.gaussian_gradient_magnitude(img_norm, sigma=1.0)
        rag = graph.rag_boundary(label_data, grad_mag, connectivity=1)
    else:
        dummy_edge = np.zeros_like(label_data, dtype=np.float32)
        rag = graph.rag_boundary(label_data, dummy_edge, connectivity=1)

    # Build sparse neighbor lists with contrast-modulated weights
    neighbors = [[] for _ in range(num_nodes)]
    edge_weights = [[] for _ in range(num_nodes)]

    for u, v, data in rag.edges(data=True):
        if u == 0 or v == 0:
            continue
        iu, iv = id_to_idx[u], id_to_idx[v]
        if iu < 0 or iv < 0:
            continue

        boundary_len = float(data.get("count", 1.0))
        boundary_grad = float(data.get("weight", 0.0))

        # Contrast-sensitive Potts weight: strong shared borders resist merging,
        # weak internal borders strongly encourage smoothing
        w = beta * np.log1p(boundary_len) * np.exp(-edge_sensitivity * boundary_grad)

        neighbors[iu].append(iv)
        edge_weights[iu].append(w)
        neighbors[iv].append(iu)
        edge_weights[iv].append(w)

    # 4. Run Iterated Conditional Modes (ICM) Energy Minimization
    print(f"-> Running MRF optimization (beta={beta}, max_iter={max_iter})...")
    current_labels = np.argmin(unary_cost, axis=1).astype(np.int32)

    for it in range(max_iter):
        changes = 0
        # Update nodes in deterministic pseudo-random order each sweep
        rng = np.random.default_rng(42 + it)
        order = rng.permutation(num_nodes)

        for idx in order:
            nbrs = neighbors[idx]
            if not nbrs:
                continue

            nbr_labels = current_labels[nbrs]
            nbr_w = np.array(edge_weights[idx], dtype=np.float32)

            # Total energy for assigning class c = Unary(c) + Sum_{nbr != c} w_ij
            total_energy = unary_cost[idx].copy()
            total_w = np.sum(nbr_w)
            for c in range(num_classes):
                same_class_w = np.sum(nbr_w[nbr_labels == c])
                total_energy[c] += (total_w - same_class_w)

            best_c = int(np.argmin(total_energy))
            if best_c != current_labels[idx]:
                current_labels[idx] = best_c
                changes += 1

        print(f"   Iter {it + 1:02d}: {changes} cluster(s) updated")
        if changes == 0:
            print("-> Converged!")
            break

    # 5. Map Regularized Labels Back to 3D Volume
    out_lut = np.zeros(max_lbl + 1, dtype=np.int32)
    out_lut[unique_labels] = current_labels + 1  # 1-indexed classes
    final_vol = out_lut[label_data]

    out_dir = os.path.dirname(nii_out)
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)
    print(f"-> Saving MRF-regularized label map to: {nii_out}")
    nib.save(nib.Nifti1Image(final_vol, prob_img.affine, prob_img.header), nii_out)
    print(f"Done! Total time: {time.time() - start_time:.2f}s")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="""
TKNI Superpixel MRF Spatial Regularizer
--------------------------------------------------------------------------------
Smooths noisy cluster-wise tissue classifications over a Region Adjacency Graph
using Iterated Conditional Modes (ICM) with a contrast-sensitive Potts penalty.
Absorbs isolated dark/bright micro-clusters inside homogeneous tissue while
preserving high-gradient anatomical boundaries.
        """,
        formatter_class=argparse.RawTextHelpFormatter,
    )
    parser.add_argument("-p", "--prob", required=True, help="Input 4D probability NIfTI from clusterProbability.")
    parser.add_argument("-l", "--label", required=True, help="Input watershed/superpixel label NIfTI.")
    parser.add_argument(
        "-i",
        "--image",
        help="Optional intensity NIfTI to modulate pairwise penalties by boundary gradient strength.",
    )
    parser.add_argument("-o", "--output", required=True, help="Output 3D regularized class NIfTI.")
    parser.add_argument(
        "-b",
        "--beta",
        type=float,
        default=1.5,
        help="Spatial smoothness weight (default: 1.5). Higher values absorb larger stray clusters.",
    )
    parser.add_argument(
        "-e",
        "--edge-sensitivity",
        type=float,
        default=5.0,
        help="Boundary gradient sensitivity (default: 5.0). Higher values stop smoothing at weak edges.",
    )
    parser.add_argument("--max-iter", type=int, default=25, help="Maximum ICM sweeps (default: 25).")

    args = parser.parse_args()
    run_superpixel_mrf(
        args.prob,
        args.label,
        args.output,
        args.image,
        args.beta,
        args.edge_sensitivity,
        args.max_iter,
    )
