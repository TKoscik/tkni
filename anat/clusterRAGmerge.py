#!/usr/local/tkni/pyvenv/clusteringVENV/bin/python
import argparse
import nibabel as nib
import numpy as np
from skimage import segmentation
from skimage import graph
from skimage import data, color
from skimage.segmentation import relabel_sequential

def _weight_mean_color(graph, src, dst, n):
    diff = graph.nodes[dst]['mean color'] - graph.nodes[n]['mean color']
    diff = np.linalg.norm(diff)
    return {'weight': diff}

def merge_mean_color(graph, src, dst):
    graph.nodes[dst]['total color'] += graph.nodes[src]['total color']
    graph.nodes[dst]['pixel count'] += graph.nodes[src]['pixel count']
    graph.nodes[dst]['mean color'] = (
        graph.nodes[dst]['total color'] / graph.nodes[dst]['pixel count']
    )

def merge_clusters(nii_image, nii_mask, nii_label, threshold, connectivity, clip_lo, clip_hi, nii_out):
    # load NIfTIs --------------------------------------------------------------
    print("-> Loading 3D NIfTI volumes")
    image = nib.load(nii_image)
    mask = nib.load(nii_mask)
    label = nib.load(nii_label)

    # convert to numeric arrays ------------------------------------------------
    print("-> converting inputs to numeric arrays")
    image_array = image.get_fdata()
    mask_array = mask.get_fdata()
    label_array = label.get_fdata()

    # make masks and labels explicitly integers --------------------------------
    mask_array = mask_array.astype(np.int32)
    label_array = label_array.astype(np.int32)

    # normalize values to start at 0 and 1 = SD --------------------------------
    print(f"-> clamping image values at {clip_lo} to {clip_hi} percentiles")
    print("   and standardizing to SD units.")
    image_mask = image_array[mask_array > 0]
    lo = np.percentile(image_mask, clip_lo)
    hi = np.percentile(image_mask, clip_hi)
    sd = np.std(np.clip(image_mask, lo, hi))
    image_array = (np.clip(image_array, lo, hi) - lo) / sd

    # apply mask ---------------------------------------------------------------
    print("-> applying mask to image")
    image_array = image_array * mask_array
    label_array = label_array * mask_array

    # calculate regional adjacency graph ---------------------------------------
    print("-> calculating regional adjacency graph")
    rag = graph.rag_mean_color(image_array, label_array, connectivity=connectivity)

    # hierarchical merge -------------------------------------------------------
    print("-> hiearchical cluster merging")
    new_label = graph.merge_hierarchical(
        label_array,
        rag,
        thresh=threshold,
        rag_copy=False,
        in_place_merge=True,
        merge_func=merge_mean_color,
        weight_func=_weight_mean_color,
    )

    print("-> relabel merged labels sequentially")
    final_label, _, _ = relabel_sequential(new_label.astype(np.int32))

    # save output --------------------------------------------------------------
    image_out = nib.Nifti1Image(final_label.astype(np.int32), image.affine)
    nib.save(image_out, nii_out)

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="3D NIfTI Label Merger")
    parser.add_argument("-i", "--image", dest="nii_image", required=True)
    parser.add_argument("-m", "--mask", dest="nii_mask", required=True)
    parser.add_argument("-l", "--label", dest="nii_label", required=True)
    parser.add_argument("-o", "--output", dest="nii_out", required=True)
    parser.add_argument("-t", "--threshold", dest="threshold", type=float, default=0.25)
    parser.add_argument("-c", "--connectivity", dest="connectivity", default=1)
    parser.add_argument("--clip-lo", dest="clip_lo", default=2.5)
    parser.add_argument("--clip-hi", dest="clip_hi", default=97.5)
    args = parser.parse_args()
    merge_clusters(args.nii_image, args.nii_mask, args.nii_label, args.threshold, args.connectivity, args.clip_lo, args.clip_hi, args.nii_out)