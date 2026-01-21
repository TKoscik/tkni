args <- commandArgs(trailingOnly = TRUE)

#nii.cluster <- "~/Documents/scratch/test_floodWatershed/flooded.nii"
#nii.thresh <- "~/Documents/scratch/test_floodWatershed/thresh.nii"

min.size <- 10
use.mm <- TRUE
peak.lt <- 0.005
peak.gt <- NULL
connectivity <- 18
do.exclude <- TRUE
do.merge <- TRUE
dir.save <- "default"
nii.save <- "default"

for (i in seq(1,length(args))) {
  if (args[i] %in% c("cluster", "nii.cluster")) {
    nii.cluster <- args[i+1]
  } else if (args[i] %in% c("thresh", "nii.thresh")) {
    nii.thresh <- args[i+1]
  } else if (args[i] %in% c("size", "min.size")) {
    min.size <- as.numeric(args[i+1])
  } else if (args[i] %in% c("use.mm")) {
    use.mm <- as.logical(args[i+1])
  } else if (args[i] %in% c("peak.lt")) {
    peak.lt <- as.numeric(args[i+1])
  } else if (args[i] %in% c("peak.gt")) {
    peak.gt <- as.numeric(args[i+1])
  } else if (args[i] %in% c("con", "connectivity", "-c")) {
    connectivity <- as.numeric(args[i+1])
  } else if (args[i] %in% c("exclude")) {
    do.exclude <- as.logical(args[i+1])
  } else if (args[i] %in% c("merge")) {
    do.merge <- as.logical(args[i+1])
  } else if (args[i] %in% c("dir-save", "dir-save", "-s")) {
    dir.save <- args[i+1]
  } else if (args[i] %in% c("f", "filename", "-f")) {
    nii.save <- args[i+1]
  }
}

# parse inputs -----------------------------------------------------------------
## check nii NOT nii.gz
EXT <- unlist(strsplit(nii.cluster, "[.]"))
if (EXT[length(EXT)] == "gz") {
  stop("ERROR [TKNI:clusterClean.R] Extrema NII file must be decompressed.")
}
EXT <- unlist(strsplit(nii.thresh, "[.]"))
if (EXT[length(EXT)] == "gz") {
  stop("ERROR [TKNI:clusterClean.R] Threshold NII file must be decompressed.")
}

if (dir.save == "default") {dir.save <- dirname(nii.cluster)}
if (nii.save == "default") {
  TBASE <- basename(nii.cluster)
  TPFX <- unlist(strsplit(TBASE, split="[.]"))
  nii.save <- paste0(TPFX[-length(TPFX)], "_clusterClean.nii", collapse="_")
}
EXT <- unlist(strsplit(nii.save, "[.]"))
if (EXT[length(EXT)] == "gz") {
  stop("ERROR [TKNI:clusterClean.R] Desired NII save file must not be compressed.")
}

library(nifti.io)

# load nifti info
img.dims <- info.nii(nii.cluster, "dims")
pixdim=info.nii(nii.cluster, field="pixdim")
orient=info.nii(nii.cluster, field="orient")

# load nifti files
cluster <- read.nii.volume(nii.cluster, 1)
thresh <- read.nii.volume(nii.thresh, 1)

# set size threshold -----------------------------------------------------------
## convert mm to number of voxels is needed
if (use.mm) { min.size <- round(min.size / prod(pixdim[2:4])) }

# set neighborhood to check possible merges ------------------------------------
neighborhood <- switch(
  as.character(connectivity),
  `6` = t(matrix(c(-1,0,0,0,-1,0,0,0,-1,1,0,0,0,1,0,0,0,1), nrow=3)),
  `18` = t(matrix(
    c(-1,-1,0,-1,0,-1,-1,0,0,-1,0,1,-1,1,0,0,-1,-1,0,-1,0,0,-1,1,0,0,-1,0,0,0,
      0,0,1,0,1,-1,0,1,0,0,1,1,1,-1,0,1,0,-1,1,0,0,1,0,1,1,1,0), nrow=3)),
  `26` = t(matrix(
    c(-1,-1,-1,-1,-1,0,-1,-1,1,-1,0,-1,-1,0,0,-1,0,1,-1,1,-1,-1,1,0,-1,1,1,0,
      -1,-1,0,-1,0,0,-1,1,0,0,-1,0,0,1,0,1,-1,0,1,0,0,1,1,1,-1,-1,1,-1,0,1,-1,1,
      1,0,-1,1,0,0,1,0,1,1,1,-1,1,1,0,1,1,1), nrow=3)),
  stop("Unrecognized connectivity"))

# loop over clusters -----------------------------------------------------------
N <- max(cluster, na.rm=T)
new.cluster <- cluster * 0
for (i in 1:N) {
  idx <- which(cluster==i, arr.ind=T)
  cval <- i
  if (nrow(idx) < min.size) {
    cval <- 0
    ## check for neighbors to merge with
    if (do.merge) {
      chk.idx <- matrix(NA, nrow=0, ncol=3)
      for (j in 1:nrow(idx)) {
        tidx <- neighborhood
        tidx[ ,1] <- tidx[ ,1] + idx[j,1]
        tidx[ ,2] <- tidx[ ,2] + idx[j,2]
        tidx[ ,3] <- tidx[ ,3] + idx[j,3]
        ## exclude out of bounds
        tchk <- (tidx[,1]<1) * (tidx[,1]>img.dims[1]) *
          (tidx[,2]<1) * (tidx[,2]>img.dims[2]) *
          (tidx[,3]<1) * (tidx[,3]>img.dims[3]) == 0
        tidx <- tidx[tchk, ]
        chk.idx <- rbind(chk.idx, tidx)
      }
      chk.idx <- unique(chk.idx)
      chk.neighbors <- cluster[chk.idx]
      chk.neighbors <- chk.neighbors[chk.neighbors!=0]
      chk.neighbors <- chk.neighbors[chk.neighbors!=i]
      if (length(chk.neighbors) > 0) {
        tbl.neighbors <- table(chk.neighbors)
        best.neighbor <- as.numeric(names(tbl.neighbors)[tbl.neighbors==max(tbl.neighbors)])
        cval <- best.neighbor
      }
    }
  }
  new.cluster[idx] <- cval
  print(sprintf("size thresholding exclusion and merge %d of %d", i, N))
}

# check for cluster peaks ------------------------------------------------------
cluster.ls <- unique(as.vector(new.cluster))
for (i in 2:length(cluster.ls)) {
  idx <- which(new.cluster==cluster.ls[i], arr.ind=TRUE)
  tval <- thresh[idx]
  if (!is.null(peak.lt)) {
    if (!any(tval < peak.lt)) { new.cluster[idx] <- 0 }
  }
  if (!is.null(peak.gt)) {
    if (!any(tval > peak.gt)) { new.cluster[idx] <- 0 }
  }
  print(sprintf("peak thresholding %d of %d", i, N))
}

# renumber clusters ------------------------------------------------------------
tbl.cluster <- table(new.cluster)
tbl.cluster <- sort(tbl.cluster, decreasing = T)
renum.cluster <- cluster * 0
tnum <- 0
for (i in 1:length(tbl.cluster)) {
  tcl <- as.numeric(names(tbl.cluster[i]))
  if (tcl != 0) {
    tnum <- tnum + 1
    renum.cluster[new.cluster == tcl] <- tnum
  }
}

# save output ------------------------------------------------------------------
fname <- sprintf("%s/%s", dir.save, nii.save)
init.nii(fname, dims=img.dims, pixdim=pixdim, orient=orient)
write.nii.volume(fname, 1, renum.cluster)
