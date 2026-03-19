#!/usr/bin/env python
#!/usr/local/tkni/pyvenv/clusteringVENV/bin/python
import argparse
import nibabel as nib
import numpy as np
from skimage import graph
from skimage.segmentation import relabel_sequential
from skimage.measure import regionprops
from scipy import ndimage as ndi
from scipy.stats import skew, kurtosis
from tqdm import tqdm

def get_cluster_stats(image_array, label_array):
    """
    Fast, sorting-free statistical fingerprints using moments.
    - Fingerprint: [Mean, SD, Skew, Kurtosis, CV]
    - regionprops indexes the volume once for all labels
    - Minimum pixels needed for valid higher-order moments
    """
    stats_map = {}
    props = regionprops(label_array, intensity_image=image_array)
    for prop in tqdm(props, desc="Statistics", total=len(props)):
        l_id = prop.label
        pixels = prop.intensity_image[prop.image]
        if pixels.size < 4:
            stats_map[l_id] = np.zeros(5)
            continue
        m = prop.mean_intensity
        s = np.std(pixels)
        if s < 1e-4:
            sk = 0.0
            kurt = 0.0
            cv = 0.0
        else:
             if np.allclose(pixels, m, atol=1e-4):
                 sk, kurt, cv = 0.0, 0.0, 0.0
             else:
                 sk = skew(pixels)
                 kurt = kurtosis(pixels)
                 cv = s / (abs(m) + 1e-8)
        stats_map[l_id] = np.array([m, s, sk, kurt, cv])
    return stats_map

def _weight_stats(g, src, dst, n, weights):
    """Calculates the distance between the NEW node (dst) and neighbor (n)."""
    # Defensive programming: If fingerprint is missing, return a huge distance
    # so they don't merge, rather than crashing the whole 69-hour process.
    f_dst = g.nodes[dst].get('fingerprint')
    f_n = g.nodes[n].get('fingerprint')

    if f_dst is None or f_n is None:
        return {'weight': float('inf')}

    diff = (f_dst - f_n) * weights
    return {'weight': np.linalg.norm(diff)}

merge_count = 0
def _merge_stats(g, src, dst):
    """Updates the survivor node 'dst' with the combined stats of 'src'."""
    # 0. counter to give a sense of duration
    global merge_count
    merge_count += 1
    if merge_count % 100 == 0:
        print(f"-> Merged: {merge_count} | # Clusters: {g.number_of_nodes()}", end='\r')

    # 1. Get counts
    count_src = g.nodes[src].get('pixel count', 1)
    count_dst = g.nodes[dst].get('pixel count', 1)
    total = count_src + count_dst

    # 2. Weighted average of fingerprints
    # We use .get() with a fallback to zeros to prevent KeyErrors during high-speed merges
    f_src = g.nodes[src].get('fingerprint', np.zeros(5))
    f_dst = g.nodes[dst].get('fingerprint', np.zeros(5))

    g.nodes[dst]['fingerprint'] = (f_src * count_src + f_dst * count_dst) / total
    g.nodes[dst]['pixel count'] = total

def merge_clusters(nii_image, nii_mask, nii_label, threshold, connectivity, clip_lo, clip_hi, nii_out, feature_weights):
    print("-> Loading NIfTI volumes")
    image = nib.load(nii_image)
    image_array = image.get_fdata().astype(np.float32)
    mask_array = nib.load(nii_mask).get_fdata().astype(np.int32)
    label_array = nib.load(nii_label).get_fdata().astype(np.int32)

    # 1. Standardize
    print("-> Standardizing intensity values")
    image_mask = image_array[mask_array > 0]
    lo, hi = np.percentile(image_mask, [clip_lo, clip_hi])
    sd = np.std(np.clip(image_mask, lo, hi))
    image_array = (np.clip(image_array, lo, hi) - lo) / sd
    image_array *= (mask_array > 0)

    # 2. Stats and RAG
    unique_labels = np.unique(label_array[label_array > 0])
    print("-> calculating statistical fingerprints")
    stats_map = get_cluster_stats(image_array, label_array)
    print("-> calculating regional adjacency graph")
    rag = graph.rag_mean_color(image_array, label_array, connectivity=connectivity)
    print("-> adding statistical features to RAG")
    for l_id in unique_labels:
        if l_id in rag:
            rag.nodes[l_id]['fingerprint'] = stats_map[l_id]
            # Ensure pixel count is present for the merge function
            if 'pixel count' not in rag.nodes[l_id]:
                rag.nodes[l_id]['pixel count'] = np.sum(label_array == l_id)

    # 3. Hierarchical Merge
    # We pass the weights into the weight function via a lambda
    print(f"-> Merging with weights {feature_weights} (threshold={threshold})...")
    new_label = graph.merge_hierarchical(
        label_array,
        rag,
        thresh=threshold,
        rag_copy=False,
        in_place_merge=True,
        merge_func=_merge_stats,
        weight_func=lambda g, s, d, n: _weight_stats(g, s, d, n, feature_weights),
    )

    print("")
    print("-> Relabeling and saving")
    final_label, _, _ = relabel_sequential(new_label.astype(np.int32))
    nib.save(nib.Nifti1Image(final_label.astype(np.int32), image.affine), nii_out)
    print("Done!")

if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="""
TKNI Hierarchical Cluster Merger
--------------------------------------------------------------------------------
This tool performs advanced segmentation merging for NIfTI volumes using Region
Adjacency Graphs (RAGs) and Hierarchical Merging based on a 5-element
statistical 'fingerprint' for each cluster:
[Mean, Standard Deviation, Skewness, Kurtosis, Coef. of Variation].
        """,
        formatter_class=argparse.RawTextHelpFormatter
    )
    parser.add_argument("-i", "--image", required=True,
                        help="Input intensity NIfTI (e.g., T1 or Ex-Vivo scan).")
    parser.add_argument("-m", "--mask", required=True,
                        help="Binary mask NIfTI to restrict processing to brain tissue.")
    parser.add_argument("-l", "--label", required=True,
                        help="Input label NIfTI (e.g., initial watershed results).")
    parser.add_argument("-o", "--output", required=True,
                        help="Output path for the merged label NIfTI.")
    parser.add_argument("-t", "--threshold", type=float, default=0.2,
                        help="Merge threshold. Lower values result in less merging.\n"
                             "Start with 0.1 - 0.3 for standardized ex vivo data.")
    parser.add_argument("-w", "--weights", nargs=5, type=float,
                        default=[1.0, 2.0, 1.5, 1.0, 1.0],
                        metavar=('MEAN', 'SD', 'SKEW', 'KURT', 'CV'),
                        help="""Weights for the 5-element fingerprint vector.
Default: [1.0, 2.0, 1.5, 1.0, 1.0]
-- To Protect White Matter: Increase SD and SKEW weights.
   Example: -w 1.0 3.0 3.0 1.0 1.0
   This prevents WM/GM merging by emphasizing distribution shape over mean intensity.
-- To Merge CSF: If CSF remains fragmented, decrease the MEAN weight.
   Example: -w 0.5 2.0 1.5 1.0 1.0
   Helps unify dark segments that may have high local variance at tissue edges.""")
    parser.add_argument("--clip-lo", type=float, default=2.5,
                        help="Lower percentile for intensity clamping (default: 2.5).")
    parser.add_argument("--clip-hi", type=float, default=97.5,
                        help="Upper percentile for intensity clamping (default: 97.5).")
    args = parser.parse_args()
    w = np.array(args.weights)
    merge_clusters(args.image, args.mask, args.label, args.threshold, 1,
                   args.clip_lo, args.clip_hi, args.output, w)
