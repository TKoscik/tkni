args <- commandArgs(trailingOnly = TRUE)

library(nifti.io)

nii <- read.nii.volume(args[1], 1)
voxels <- info.nii(args[1], "voxels")
orient <- info.nii(args[1], "orient")
pixdim <- info.nii(args[1], "pixdim")

vals.orig <- unique(as.numeric(nii))
vals.orig <- vals.orig[vals.orig != 0]
vals.rank <- rank(vals.orig)
nii.rank <- nii * 0
for (i in 1:length(vals.orig)) {
  idx <- which(nii == vals.orig[i], arr.ind = T)
  nii.rank[idx] <- vals.rank[i]
}

init.nii(new.nii = args[2], dims=voxels, orient=orient, pixdim=pixdim)
write.nii.volume(args[2], 1, nii.rank)

