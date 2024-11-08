antsRegistration \
--dimensionality 3 \
--output /scratch/coregistrationChef_kosciktarchildrens.org_20240229T162415911045576/xfm_ \
--write-composite-transform 0 \
--collapse-output-transforms 1 \
--initialize-transforms-per-stage 0 \
--initial-moving-transform [ /scratch/tkniFUNK_evanderplas_unitcall_20240229T160032940979992/anat/anat_roi.nii.gz,/scratch/tkniFUNK_evanderplas_unitcall_20240229T160032940979992/tmp/ts_proc-mean_roi-brain_bold.nii.gz,1 ] \
--transform Rigid[0.1] \
--metric Mattes[ /scratch/tkniFUNK_evanderplas_unitcall_20240229T160032940979992/anat/anat_roi.nii.gz,/scratch/tkniFUNK_evanderplas_unitcall_20240229T160032940979992/tmp/ts_proc-mean_roi-brain_bold.nii.gz,1,32,Regular,0.2 ] \
--convergence [1200x1200x100,1e-6,5] \
--smoothing-sigmas 2x1x0vox \
--shrink-factors 4x2x1 \
--transform Affine[0.25] \
--metric Mattes[ /scratch/tkniFUNK_evanderplas_unitcall_20240229T160032940979992/anat/anat_roi.nii.gz,/scratch/tkniFUNK_evanderplas_unitcall_20240229T160032940979992/tmp/ts_proc-mean_roi-brain_bold.nii.gz,1,32,Regular,0.2 ] \
--convergence [200x20,1e-6,5] \
--smoothing-sigmas 1x0vox \
--shrink-factors 2x1 \
--transform SyN[0.2,3,0] \
--metric Mattes[ /scratch/tkniFUNK_evanderplas_unitcall_20240229T160032940979992/anat/anat_roi.nii.gz,/scratch/tkniFUNK_evanderplas_unitcall_20240229T160032940979992/tmp/ts_proc-mean_roi-brain_bold.nii.gz,1,32 ] \
--convergence [ 40x20x0,1e-7,8 ] \
--smoothing-sigmas 2x1x0vox \
--shrink-factors 4x2x1 \
--use-histogram-matching 0 \
--winsorize-image-intensities [ 0.005,0.995 ] \
--float 1 \
--verbose 0 \
--random-seed 13311800



coregistrationChef --recipe-name intermodalSyn --fixed /scratch/tkniFUNK_evanderplas_unitcall_20240301T095208559086544/anat/anat_roi.nii.gz --moving /scratch/tkniFUNK_evanderplas_unitcall_20240301T095208559086544/tmp/ts_proc-mean_roi-brain_bold.nii.gz --prefix ts0 --label-from raw --label-to native --dir-save /scratch/tkniFUNK_evanderplas_unitcall_20240301T095208559086544/tmp --dir-xfm /scratch/tkniFUNK_evanderplas_unitcall_20240301T095208559086544/xfm --no-png --verbose --dry-run



jq -r '.coregistration_recipe.intermodalSyn."convergence"[]?' < /usr/local/tkbrainlab/neuroimage_code/lut/coregistration_recipes.json
