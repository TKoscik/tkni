# identify low signal region

MSD=($(3dBrickStat -mask mask-ME10.nii.gz -mean -stdev FA16.nii.gz))

# scale to internal region no centering
## convert to z score
## invert and threshold
## resmooth edge
## scale intensity modifier as needed
## mask to brain region
## add one to create bias-field like multiplier
## multiply original to debias

K1=1
THRESH=0.05
K2=0
K3=3
SCALE=3
niimath FA16.nii.gz \
  -sub ${MSD[0]} -div ${MSD[1]} \
  -s ${K1} \
  -mul -1 -thr ${THRESH} \
  -bin -s ${K2} \
  -div ${SCALE} \
  -mas mask-brain.nii.gz \
  -add 1 \
  -s ${K3} \
  bias.nii.gz
#itksnap -g FA16.nii.gz -o bias.nii.gz

ImageMath 3 bias.nii.gz Sharpen bias.nii.gz

niimath FA16.nii.gz \
  -mul bias.nii.gz \
  FA16_clean.nii.gz
#itksnap -g FA16_clean.nii.gz -o FA16.nii.gz

N4BiasFieldCorrection -d 3 \
  -i FA16_clean.nii.gz \
  -o FA16_clean_N4.nii.gz \
  -x mask-brain.nii.gz \
  -s 4
itksnap -g FA16_clean_N4.nii.gz -o FA16_clean.nii.gz FA16.nii.gz
