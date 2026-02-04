args <- commandArgs(trailingOnly = TRUE)

IMAGE <- args[1]
VOLUME <- as.numeric(args[2])
PLANE <- args[3]
SHIFT <- as.numeric(args[4])
FILENAME <- args[5]

library(nifti.io)

imgdims <- info.nii(IMAGE, "dims")
pixdim <- info.nii(IMAGE, "pixdim")
orient <- info.nii(IMAGE, "orient")
data <- read.nii.volume(IMAGE, VOLUME)

if (PLANE == "x") {
  data <- data[c(SHIFT:imgdims[1], 1:(SHIFT-1)), , ]
} else if (PLANE == "y") {
  data <- data[ ,c(SHIFT:imgdims[2], 1:(SHIFT-1)), ]
} else if (PLANE == "z") {
  data <- data[ , ,c(SHIFT:imgdims[3], 1:(SHIFT-1))]
}

init.nii(FILENAME,dims=imgdims, pixdim=pixdim, orient=orient)
write.nii.volume(FILENAME, 1, data)
