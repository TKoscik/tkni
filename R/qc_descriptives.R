
args <- commandArgs(trailingOnly = TRUE)

vol <- 1
mask <- NULL
dir.scratch <- sprintf("/scratch/tkni_qc_descriptives_%s", format(Sys.time(), "%Y%m%dT%H%M%s"))

for (i in seq(1,length(args))) {
  if (args[i] %in% c("i", "image", "-i")) {
    img <- args[i+1]
  } else if (args[i] %in% c("v", "vol", "volume", "-v")) {
    vol <- args[i+1]
  } else if (args[i] %in% c("m", "mask", "-m")) {
    mask <- args[i+1]
  } else if (args[i] %in% c("scratch", "dir.scratch", "-dir.scratch")) {
    dir.scratch <- args[i+1]
  }
}

require(nifti.io)
require(tools)
require(R.utils)
require(moments)

# read in image data, unzip as needed ------------------------------------------
if (file_ext(img) == "gz") {
  dir.create(dir.scratch, showWarnings=F, recursive=T)
  gunzip(filename=img, destname=sprintf("%s/img.nii", dir.scratch), remove=F)
  img <- sprintf("%s/img.nii", dir.scratch)
}
img <- read.nii.volume(img, vol)

# mask unwanted voxels, unzip mask as needed -----------------------------------
if (!is.null(mask)) {
  if (file_ext(mask) == "gz"){
    dir.create(dir.scratch, showWarnings=F, recursive=T)
    gunzip(filename=mask, destname=sprintf("%s/mask.nii", dir.scratch), remove=F)
    mask <- sprintf("%s/mask.nii", dir.scratch)
  }
  mask <- which(read.nii.volume(mask, 1)!=0, arr.ind=T)
  img <- img[mask]
} else {
  img <- as.numeric(img)
}

# Calculate descriptive statistics ---------------------------------------------
descriptives <- c(mean=mean(img, na.rm=TRUE),
    sd=sd(img, na.rm=TRUE),
    median=median(img, na.rm=TRUE),
    mad=mad(img, na.rm=TRUE),
    skew=skewness(img, na.rm=TRUE),
    kurtosis=kurtosis(img, na.rm=TRUE),
    p05=unname(quantile(img, 0.05, na.rm=TRUE)),
    p95=unname(quantile(img, 0.95, na.rm=TRUE)))

# clear scratch directory if used ----------------------------------------------
if (dir.exists(dir.scratch)) {
  invisible(file.remove(list.files(dir.scratch, full.names=T)))
  invisible(file.remove(dir.scratch))
}

# output to command line -------------------------------------------------------
cat(descriptives)
