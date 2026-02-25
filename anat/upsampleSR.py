import os
os.environ["TF_USE_LEGACY_KERAS"] = "1"
import ants
import antspynet
import numpy as np
import tensorflow as tf
import argparse
from scipy.ndimage import gaussian_filter

# setup a 3D Gaussian weight mask to blend patch edges -------------------------
def create_gaussian_weight_mask(size, sigma=10):
    mask = np.zeros((size, size, size))
    mask[size//2, size//2, size//2] = 1
    mask = gaussian_filter(mask, sigma=sigma)
    return mask / mask.max()

# Start main function ==========================================================
def main():
    parser = argparse.ArgumentParser(description="Super-resolution upscaling by a factor of 2")
    parser.add_argument("--input", "-i", type=str, required=True, help="path to low resolution image")
    parser.add_argument("--output", "-o", type=str, required=True, help="path to upscaled output image")
    parser.add_argument("--model", "-m", type=str, required=True, help="")
    parser.add_argument("--patch", "-p", type=int, default=64, help="")
    parser.add_argument("--stride", "-s", type=int, default=32, help="")

    args = parser.parse_args()

    # verify files exist and load inputs ---------------------------------------
    if not os.path.exists(args.input):
        print(f"Error: Input file {args.input} not found.")
        sys.exit(1)
    if not os.path.exists(args.model):
        print(f"Error: Model file {args.model} no found.")
        sys.exit(1)

    print(f"--- Loading Model: {args.model} ---")
    model_sr = tf.keras.models.load_model(args.model, compile=False)

    print(f"--- Loading Image: {args.input} ---")
    img = ants.image_read(args.input)

    # Geometry for 2x upscaling ------------------------------------------------
    new_spacing = [s /2 for s in img.spacing]
    ref_grid = ants.resample_image(img, new_spacing, use_voxels=False, interp_type=4)

    reconstructed_data = np.zeros(ref_grid.shape, dtype='float32')
    weight_accumulator = np.zeros(ref_grid.shape, dtype='float32')

    p_size = args.patch
    out_p_size = p_size * 2
    stride = args.stride

    # precompute Gaussian weight -----------------------------------------------
    g_weight = create_gaussian_weight_mask(out_p_size, sigma=out_p_size/4)

    # Nested loop for 3D sliding window ----------------------------------------
    print(f"--- Starting Tiling Inference on {img.shape} volume...")
    for x in range(0, img.shape[0] - p_size + 1, stride):
        for y in range(0, img.shape[1] - p_size + 1, stride):
            for z in range(0, img.shape[2] - p_size + 1, stride):
                # Extract Patch
                patch = ants.crop_indices(img, (x, y, z), (x+p_size, y+p_size, z+p_size))
                # Run Super-Resolution on Patch
                # batch_size=1 keeps VRAM usage at minimum
                sr_patch = antspynet.apply_super_resolution_model_to_image(
                    patch, model_sr, target_range=(0, 1), batch_size=1
                )
                sr_data = sr_patch.numpy()
                # Place into Reconstruction Grid
                xs, ys, zs = x*2, y*2, z*2
                xe, ye, ze = xs+out_p_size, ys+out_p_size, zs+out_p_size
                # reconstruct with Guassian blending of edges
                reconstructed_data[xs:xe, ys:ye, zs:ze] += (sr_data * g_weight)
                weight_accumulator[xs:xe, ys:ye, zs:ze] += g_weight

    weight_accumulator[weight_accumulator == 0] = 1
    final_data = reconstructed_data / weight_accumulator

    final_img = ants.from_numpy(final_data, origin=ref_grid.origin,
                                spacing=ref_grid.spacing, direction=ref_grid.direction)
    print("--- Finalizing Intensity Matching ---")
    final_img = ants.histogram_match_image(final_img, img)
    final_img.to_file(args.output)
    print(f"--- SUCCESS: upscaled output saved to {args.output}")

if __name__ == "__main__":
    main()
