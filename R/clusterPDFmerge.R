args <- commandArgs(trailingOnly = TRUE)

nii.intensity <- args[1]
nii.segmentation <- args[2]
overlap.threshold <- 0.25
#dir.save <- "default"
nii.save <- "default"

for (i in seq(1,length(args))) {
  if (args[i] %in% c("i", "intensity", "-i")) {
    nii.intensity <- args[i+1]
  } else if (args[i] %in% c("s", "segmentation", "segment", "seg", "-s")) {
    nii.segmentation <- args[i+1]
  } else if (args[i] %in% c("o", "overlap", "-o")) {
    overlap.threshold <- as.numeric(args[i+1])
#  } else if (args[i] %in% c("dir-save", "dir-save", "-s")) {
#    dir.save <- args[i+1]
  } else if (args[i] %in% c("f", "filename", "-f")) {
    nii.save <- args[i+1]
  }
}

######### DEBUG/TEST ###########################################################
rm(list=ls())
gc()
nii.intensity <- "/scratch/watershed_pdfMerge_test/swi.nii"
nii.segmentation <- "/scratch/watershed_pdfMerge_test/label-watershed.nii"
nii.save <- "/scratch/watershed_pdfMerge_test/label-watershed+pdfMerge.nii"
overlap.threshold <- 0.5
process.continue <- TRUE
################################################################################

# load libraries ---------------------------------------------------------------
require("nifti.io")
require("data.table")
require("tools")

# parse inputs -----------------------------------------------------------------
## check nii NOT nii.gz
if (has_extension(nii.intensity, "gz")) {
  stop("ERROR [TKNI:clusterWatershed.R] Intensity NII file must be decompressed.")
}
if (has_extension(nii.segmentation, "gz")) {
  stop("ERROR [TKNI:clusterWatershed.R] Segmentation NII file must be decompressed.")
}
#if (dir.save == "default") {dir.save <- dirname(nii.distance)}
if (nii.save == "default") {
  TBASE <- basename(nii.distance)
  TPFX <- unlist(strsplit(TBASE, split="_"))
  nii.save <- paste0(TPFX[-length(TPFX)], "segmentation+pdfmerge.nii", collapse="_")
}
if (has_extension(nii.save, "gz")) {
  stop("ERROR [TKNI:clusterWatershed.R] Desired NII save file must not be compressed.")
}

# read in data -----------------------------------------------------------------
intensity <- read.nii.volume(nii.intensity, 1)
if (process.continue) {
  segmentation <- read.nii.volume(nii.save, 1)
} else {
  segmentation <- read.nii.volume(nii.segmentation, 1)
}
img.dims <- info.nii(nii.segmentation, "dims")
pixdim <- info.nii(nii.segmentation, "pixdim")
orient <- info.nii(nii.segmentation, "orient")

# get original label list ------------------------------------------------------
labels <- sort(unique(as.vector(segmentation)))[-1]
n.labels <- max(labels)

# get intensity quanitles ------------------------------------------------------
maxIntensity <- max(as.vector(intensity), na.rm=T)

# compare touching labels (face sharing) ---------------------------------------
nn <- t(matrix(c(-1,0,0,0,-1,0,0,0,-1,1,0,0,0,1,0,0,0,1), nrow=3))
new.labels <- numeric(n.labels)

#init.nii(nii.save, dims=img.dims, pixdim=pixdim, orient=orient)
for (i in 1:n.labels) {
  DO.WRITE <- FALSE
  if (new.labels[i] == 0) { new.labels[i] <- i }
  wrklab <- new.labels[i]
  idx1 <- matrix(which(segmentation==labels[i], arr.ind=TRUE), ncol=3)
  if (nrow(idx1) == 0) { next }
  vals1 <- intensity[idx1]
  m1 <- mean(vals1, na.rm=T)
  s1 <- sd(vals1, na.rm=T)
  pdf1 <- function(x) dnorm(x, mean=m1, sd=s1)
  # get touching labels ------
  tlab <- numeric(0)
  for (j in 1:nrow(nn)) {
    tidx <- cbind(idx1[,1]+nn[j,1], idx1[,2]+nn[j,2], idx1[,3]+nn[j,3])
    gidx <- (tidx[,1] <= img.dims[1]) * (tidx[,2] <= img.dims[2]) * (tidx[,3] <= img.dims[3])
    tidx <- tidx[gidx, ]
    tlab <- c(tlab, unique(as.vector(segmentation[tidx])))
  }
  tlab <- sort(unique(tlab))[-1]
  tlab <- tlab[-which(tlab==wrklab)]
  # identify PDF overlap ------
  if (length(tlab) > 0) {
    for (j in 1:length(tlab)) {
      idx2 <- matrix(which(segmentation==tlab[j], arr.ind=TRUE), ncol=3)
      vals2 <- intensity[idx2]
      m2 <- mean(vals2, na.rm=T)
      s2 <- sd(vals2, na.rm=T)
      pdf2 <- function(x) dnorm(x, mean=m2, sd=s2)
      # get overlap coefficient for PDF functions
      min.pdf <- function(x) { pmin(pdf1(x), pdf2(x))}
      toverlap <- integrate(min.pdf, lower=0, upper=maxIntensity)$value
      if (toverlap > overlap.threshold) {
        new.labels[j] <- wrklab
        segmentation[idx2] <- wrklab
        DO.WRITE <- TRUE
      }
    }
  }
  if (DO.WRITE) {
    print("writing")
    write.nii.volume(nii.save, 1, segmentation)
  }
  print(sprintf("Done with label %d", i))
}

# save output ------------------------------------------------------------------
#tbl <- table(segmentation)
new.labels <- sort(unique(as.vector(segmentation)))[-1]
new.segmentation <- segmentation * 0
for (i in 1:length(new.labels)) {
  tseg <- (segmentation==new.labels[i])*i
  new.segmentation <- new.segmentation + tseg
}

init.nii("/scratch/watershed_pdfMerge_test/label-watershed+pdfMerge+reorder.nii",
  dims=img.dims, pixdim=pixdim, orient=orient)
write.nii.volume("/scratch/watershed_pdfMerge_test/label-watershed+pdfMerge+reorder.nii",
  1, new.segmentation)

