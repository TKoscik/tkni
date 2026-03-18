#!/usr/local/tkni/pyvenv/clusteringVENV/bin/python
import argparse
import nibabel as nib
import numpy as np
import time
from tqdm import tqdm
from skimage import feature, graph
from scipy import ndimage as ndi

def extract_features(image_data, labels, label_id):
    """Calculates GLCM features by looking at the central 2D slice of a 3D region."""
    coords = np.argwhere(labels == label_id)
    if coords.size == 0:
        return np.zeros(3)

    # 1. Get bounding box
    z_min, y_min, x_min = coords.min(axis=0)
    z_max, y_max, x_max = coords.max(axis=0) + 1

    # 2. Extract 3D patch
    patch = image_data[z_min:z_max, y_min:y_max, x_min:x_max]
    mask = labels[z_min:z_max, y_min:y_max, x_min:x_max] == label_id

    # 3. Select the central slice along the Z-axis that contains the most pixels
    # (This ensures we have a valid 2D plane for graycomatrix)
    z_counts = np.sum(mask, axis=(1, 2))
    z_mid = np.argmax(z_counts)

    slice_2d = patch[z_mid, :, :]
    mask_2d = mask[z_mid, :, :]

    # Get only the pixels belonging to the label in this slice
    pixels = slice_2d[mask_2d]
    if pixels.size < 2: # Fallback if slice is too small
        return np.zeros(3)

    # 4. Quantize and Reshape to 2D
    # graycomatrix needs a 2D array, so we use a bounding box of the slice
    rows = np.any(mask_2d, axis=1)
    cols = np.any(mask_2d, axis=0)
    rmin, rmax = np.where(rows)[0][[0, -1]]
    cmin, cmax = np.where(cols)[0][[0, -1]]

    final_slice = slice_2d[rmin:rmax+1, cmin:cmax+1]

    # Normalize/Quantize
    p_min, p_max = final_slice.min(), final_slice.max()
    quantized = ((final_slice - p_min) / (p_max - p_min + 1e-5) * 15).astype(np.uint8)

    # 5. Compute GLCM
    glcm = feature.graycomatrix(quantized, [1], [0], levels=16, symmetric=True, normed=True)
    return np.array([
        feature.graycoprops(glcm, 'homogeneity')[0, 0],
        feature.graycoprops(glcm, 'contrast')[0, 0],
        feature.graycoprops(glcm, 'dissimilarity')[0, 0]
    ])

def _merge_texture_nodes(g, src, dst):
    """Callback to update node properties: averages the pre-calculated features."""
    # Weight the new features based on pixel count to maintain accuracy
    count_src = g.nodes[src].get('count', 1)
    count_dst = g.nodes[dst].get('count', 1)
    total = count_src + count_dst

    g.nodes[dst]['texture_feat'] = (
        (g.nodes[src]['texture_feat'] * count_src +
         g.nodes[dst]['texture_feat'] * count_dst) / total
    )
    g.nodes[dst]['count'] = total

def _texture_weight(g, src, dst, n):
    """Computes weight between merged node and neighbor 'n'."""
    return {'weight': np.linalg.norm(g.nodes[dst]['texture_feat'] - g.nodes[n]['texture_feat'])}

def run_texture_merge(intensity_path, label_path, output_path, threshold=0.1):
    start_time = time.time()

    # 1. Load Data
    print(f"-> Loading Data...")
    img_obj = nib.load(intensity_path)
    img_data = img_obj.get_fdata()
    labels = nib.load(label_path).get_fdata().astype(int)

    # 2. Pre-calculate Texture Features (The Optimization)
    print("-> Pre-calculating texture features for all regions...")
    unique_labels = np.unique(labels[labels > 0])

    # Build RAG and attach pre-calculated features to nodes
    rag = graph.rag_mean_color(img_data, labels)
    # Wrap the loop with tqdm to monitor progress
    for l in tqdm(unique_labels, desc="Texture Extraction", unit="region"):
        if l in rag:
            rag.nodes[l]['texture_feat'] = extract_features(img_data, labels, l)
            rag.nodes[l]['count'] = np.sum(labels == l)

    # 3. Perform Merging
    print(f"-> Merging clusters (threshold={threshold})...")
    merged_labels = graph.merge_hierarchical(labels, rag, thresh=threshold,
                                             rag_copy=False,
                                             in_place_merge=True,
                                             merge_func=_merge_texture_nodes,
                                             weight_func=_texture_weight)

    # 4. Save
    print(f"-> Saving to: {output_path}")
    nib.save(nib.Nifti1Image(merged_labels.astype(np.int32), img_obj.affine), output_path)
    print(f"Done! Total time: {time.time() - start_time:.2f}s")

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Optimized Texture Merging")
    parser.add_argument("-i", "--intensity", required=True)
    parser.add_argument("-l", "--labels", required=True)
    parser.add_argument("-t", "--threshold", type=float, default=0.05)
    parser.add_argument("-o", "--output", required=True)

    args = parser.parse_args()
    run_texture_merge(args.intensity, args.labels, args.output, args.threshold)
