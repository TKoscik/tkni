#!/usr/local/tkni/pyvenv/clusteringVENV/bin/python
import argparse
import nibabel as nib
import numpy as np
import time
from skimage.segmentation import watershed
from scipy import ndimage as ndi

def run_watershed(input_path, datum, output_path, mask_path=None):
    start_time = time.time()

    # 1. Load Data
    print(f"-> Loading EDT: {input_path}")
    img = nib.load(input_path)
    dist_map = img.get_fdata()

    # 2. Masking
    if mask_path:
        print(f"-> Loading Mask: {mask_path}")
        mask_data = nib.load(mask_path).get_fdata() > 0
        dist_map = dist_map * mask_data
    else:
        mask_data = dist_map > 0

    # 3. Create Basin Markers
    ## Calculate datum from spacing if not provided ---
    if datum is None:
        dx, dy, dz = img.header.get_zooms()[:3]
        # Calculate distances between (dx,0,0), (0,dy,0), and (0,0,dz)
        d_xy = np.sqrt(dx**2 + dy**2)
        d_xz = np.sqrt(dx**2 + dz**2)
        d_yz = np.sqrt(dy**2 + dz**2)
        datum = 2 * min(d_xy, d_xz, d_yz)
        print(f"-> Datum calculated (2x min pairwise distance between voxel centers): {datum:.4f}")
    print(f"-> Extracting basins (dist >= {datum})...")
    core_mask = dist_map >= datum
    markers, _ = ndi.label(core_mask)

    # 4. Run Watershed
    print("-> Running watershed...")
    labels = watershed(-dist_map, markers, mask=mask_data)

    # 5. Sort Labels by Volume (Largest to Smallest)
    print("-> Sorting clusters by volume...")
    # Get unique labels and their counts (excluding background 0)
    unique, counts = np.unique(labels[labels > 0], return_counts=True)

    # Sort counts in descending order and get the original label indices
    sorted_indices = np.argsort(-counts)
    sorted_labels = unique[sorted_indices]

    # Map old labels to new sorted ranks
    # We use a lookup table for speed on large 3D volumes
    max_label = int(labels.max())
    lookup = np.zeros(max_label + 1, dtype=labels.dtype)
    for rank, old_label in enumerate(sorted_labels):
        lookup[int(old_label)] = rank + 1

    sorted_final = lookup[labels.astype(int)]

    # 6. Save
    print(f"-> Saving to: {output_path}")
    nib.save(nib.Nifti1Image(sorted_final.astype(np.int32), img.affine), output_path)
    print(f"Done! Found {len(sorted_labels)} clusters. Total time: {time.time() - start_time:.2f}s")

if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="""
TKNI Watershed Segmentation
--------------------------------------------------------------------------------
This tool performs watershed segmentation on NIfTI distance maps (EDT).
It identifies seed points (basins) based on a distance threshold,
propagates labels, and re-ranks the resulting clusters by volume
(Label 1 = Largest Cluster).
        """,
        formatter_class=argparse.RawTextHelpFormatter
    )
    parser.add_argument("-i", "--input", required=True,
                        help="Input NIfTI distance map (e.g., Euclidean Distance Transform).")
    parser.add_argument("-d", "--datum", type=float,
                        help="Distance threshold for seed extraction.\n"
                             "If omitted, defaults to 2x min voxel spacing.\n"
                             "Increasing this value results in fewer, larger seeds.")
    parser.add_argument("-k", "--mask",
                        help="Optional binary mask NIfTI to restrict the watershed growth.\n"
                             "If omitted, the script uses all voxels > 0 in the input.")
    parser.add_argument("-o", "--output", required=True,
                        help="Output path for the sorted label NIfTI volume.")
    args = parser.parse_args()
    run_watershed(args.input, args.datum, args.output, args.mask)
