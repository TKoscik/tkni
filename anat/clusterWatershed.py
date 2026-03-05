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
    parser = argparse.ArgumentParser(description="NIFTI Watershed: Datum + Sorted")
    parser.add_argument("-i", "--input", required=True)
    parser.add_argument("-d", "--datum", type=float, default=2.0)
    parser.add_argument("-k", "--mask", help="Optional mask")
    parser.add_argument("-o", "--output", required=True)

    args = parser.parse_args()
    run_watershed(args.input, args.datum, args.output, args.mask)
