args <- commandArgs(trailingOnly = TRUE)

# check for single input
if (length(args) < 1) { stop("A single, 4D input must be provided") }
nii <- args[1]
lo <- 0.5
hi <- 1
dir.save <- dirname(nii)
if (length(args) > 1) {
  for (i in 1:length(args)) {
    if (args[i] == "lo") { lo <- as.numeric(args[i+1]) }
    if (args[i] == "hi") { hi <- as.numeric(args[i+1]) }
    if (args[i] %in% c("s", "dir", "save", "dir-save",
        "dirsave", "dir_save", "savedir", "save-dir", "save_dir")) {
      dir.save = args[i+1]
    }
  }
}

library(nifti.io, quietly=TRUE)
library(matrixStats, quietly=TRUE)
library(tools, quietly=TRUE)

# check if unzipped
if (file_ext(nii) == "gz") { stop("input NII.GZ must be decompressed first") }

# get image dimensions and check if 4D
sz <- info.nii(nii, "dim")[2:5]
#print(sprintf("Image size: X=%0.0f, Y=%0.0f, Z=%0.0f, t=%0.0f", sz[1], sz[2], sz[3], sz[4]))
if (sz[4] <= 1) { stop("Not a 4D NII file") }

# load timeseries into matrix, voxels in rows, time across columns
ts <- matrix(0, nrow=prod(sz[1:3]), ncol=sz[4])
for (i in 1:sz[4]) { ts[ ,i] <- read.nii.volume(nii, i) }

# clamp extreme values
if (lo > 0) { ts[ts < quantile(ts, lo)] <- 0 }
if (hi < 1) { ts[ts > quantile(ts, hi)] <- quantile(ts, hi)}

# calculate time-series z scores
z <- (ts - rowMeans(ts)) / rowSds(ts)
z <- array(z, dim=sz)

## save z-score if desired
tname <- unlist(strsplit(unlist(strsplit(basename(nii), "[.]"))[1], "_"))
z.nii <- paste0(dir.save, "/",
  paste(tname[1:(length(tname)-1)], collapse="_"),
  "_mod-", tname[length(tname)],
  "_tensor-z.nii")
dims <- info.nii(nii, "dim")[2:5]
pixdim <- info.nii(nii, "pixdim")
orient <- info.nii(nii, "orient")
datatype <- info.nii(nii, "datatype")
init.nii(z.nii, dims=dims, pixdim=pixdim, orient=orient, datatype=datatype)
for (i in 1:sz[4]) { write.nii.volume(z.nii, i, z[ , , ,i]) }


