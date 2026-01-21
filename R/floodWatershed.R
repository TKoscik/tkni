args <- commandArgs(trailingOnly = TRUE)

vol.extrema <- 1
vol.value <- 1
vol.mask <- 1
datum <- 0
direction <- "both"
connectivity <- 6
dir.save <- "default"
nii.save <- "default"

for (i in seq(1,length(args))) {
  if (args[i] %in% c("extrema", "nii.extrema")) {
    nii.extrema <- args[i+1]
  } else if (args[i] %in% c("v", "value", "nii.value")) {
    nii.value <- args[i+1]
  } else if (args[i] %in% c("m", "mask", "nii.mask")) {
    nii.mask <- args[i+1]
  } else if (args[i] %in% c("vol.extrema")) {
    vol.extrema <- as.numeric(args[i+1])
  } else if (args[i] %in% c("vol.value")) {
    vol.value <- as.numeric(args[i+1])
  } else if (args[i] %in% c("vol.mask")) {
    vol.mask <- as.numeric(args[i+1])
  } else if (args[i] %in% c("datum", "-g")) {
    datum <- as.numeric(args[i+1])
  } else if (args[i] %in% c("con", "connectivity", "-c")) {
    connectivity <- as.numeric(args[i+1])
  } else if (args[i] %in% c("d", "direction", "-d")) {
    direction <- args[i+1]
  } else if (args[i] %in% c("dir-save", "dir-save", "-s")) {
    dir.save <- args[i+1]
  } else if (args[i] %in% c("f", "filename", "-f")) {
    nii.save <- args[i+1]
  }
}

# parse inputs -----------------------------------------------------------------
## check nii NOT nii.gz
EXT <- unlist(strsplit(nii.extrema, "[.]"))
if (EXT[length(EXT)] == "gz") {
  stop("ERROR [TKNI:floodWatershed.R] Extrema NII file must be decompressed.")
}
EXT <- unlist(strsplit(nii.value, "[.]"))
if (EXT[length(EXT)] == "gz") {
  stop("ERROR [TKNI:floodWatershed.R] Value NII file must be decompressed.")
}
if (nii.mask != FALSE) {
  EXT <- unlist(strsplit(nii.mask, "[.]"))
  if (EXT[length(EXT)] == "gz") {
    stop("ERROR [TKNI:floodWatershed.R] Mask NII file must be decompressed.")
  }
}

if (dir.save == "default") {dir.save <- dirname(nii.value)}
if (nii.save == "default") {
  TBASE <- basename(nii.value)
  TPFX <- unlist(strsplit(TBASE, split="[.]"))
  nii.save <- paste0(TPFX[-length(TPFX)], "_floodWatershed.nii", collapse="_")
}
EXT <- unlist(strsplit(nii.save, "[.]"))
if (EXT[length(EXT)] == "gz") {
  stop("ERROR [TKNI:clusterWatershed.R] Desired NII save file must not be compressed.")
}


library(nifti.io)

# load nifti info
img.dims <- info.nii(nii.value, "dims")
pixdim=info.nii(nii.value, field="pixdim")
orient=info.nii(nii.value, field="orient")

# load nifti files
extrema <- read.nii.volume(nii.extrema, vol.extrema)
value <- read.nii.volume(nii.value, vol.value)
mask <- (read.nii.volume(nii.mask, vol.mask) > 0) * 1

# set value datum and direction
value <- value - datum
print(direction)
if (direction == "both") {
  value <- abs(value)
} else if (direction == "pos") {
  value[value <= datum] <- 0
} else if (direction == "neg") {
  value[value >= datum] <- 0
  value <- abs(value)
}

# set neighborhood
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

# loop over extrema, flood fill to basin
n.extrema <- max(extrema) 
flooded <- extrema
for (i in 1:n.extrema) {
  idx <- matrix(which(extrema == i, arr.ind=T), ncol=3)
  while (length(idx > 0)) {
    tval <- value[matrix(idx[1, ], ncol=3)]
    idx.search <- neighborhood
    idx.search[ ,1] <- idx.search[ ,1] + idx[1,1]
    idx.search[ ,2] <- idx.search[ ,2] + idx[1,2]
    idx.search[ ,3] <- idx.search[ ,3] + idx[1,3]
    in.mask <- mask[idx.search] == 1
    idx.search <- matrix(idx.search[in.mask, ], ncol=3)
    do.flood <- value[idx.search] < tval
    do.flood[is.na(do.flood)] <- FALSE
    if (sum(do.flood) != 0) {
      idx.flood <- matrix(idx.search[do.flood, ], ncol=3)
      flooded[idx.flood] <- i
      idx <- rbind(idx, idx.flood)
    }
    idx <- matrix(unique(idx), ncol=3)
    idx <- idx[-1, ,drop=FALSE]
  }
  print(sprintf("flooding %d of %d", i, n.extrema))
}

# save output ------------------------------------------------------------------
fname <- sprintf("%s/%s", dir.save, nii.save)
init.nii(fname, dims=img.dims, pixdim=pixdim, orient=orient)
write.nii.volume(fname, 1, flooded)

