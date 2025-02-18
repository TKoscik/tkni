args <- commandArgs(trailingOnly = TRUE)

library(nifti.io, quietly=T)
library(R.utils, quietly=T)
library(tools, quietly=T)

# parse inputs -----------------------------------------------------------------
## Defaults
volume <- 1
mask.volume <- 1
roi.thresh <- 0.05
peak.thresh <- 0.001
cluster.size <- 25
connectivity <- 26L
save.clusters=TRUE
save.table=TRUE
save.mask=TRUE
do.pos <- TRUE
do.neg <- TRUE
nii.mask <- NULL
dir.scratch <- sprintf("/scratch/tkni_clusterEffect_%s", format(Sys.time(), "%Y%m%dT%H%M%S"))

for (i in seq(1,length(args))) {
  if (args[i] %in% c("nii.coef", "coef", "estimate", "beta")) {
    nii.coef <- args[i+1]
  } else if (args[i] %in% c("nii.test", "test", "t", "f")) {
    nii.test <- args[i+1]
  } else if (args[i] %in% c("nii.pval", "pval", "p")) {
    nii.pval <- args[i+1]
  } else if (args[i] %in% c("nii.mask", "mask", "roi")) {
    nii.mask <- args[i+1]
  } else if (args[i] %in% c("effect.volume", "effect.vol")) {
    effect.volume <- as.numeric(args[i+1])
  } else if (args[i] %in% c("mask.volume", "mask.vol")) {
    mask.volume <- as.numeric(args[i+1])
  } else if (args[i] %in% c("effect", "effect.name")) {
    effect.name <- args[i+1]
  } else if (args[i] %in% c("roi.thresh", "roi.threshold")) {
    roi.thresh <- as.numeric(args[i+1])
  } else if (args[i] %in% c("peak.thresh", "peak.threshold")) {
    peak.thresh <- as.numeric(args[i+1])
  } else if (args[i] %in% c("cluster.size", "size")) {
    cluster.size <- as.numeric(args[i+1])
  } else if (args[i] %in% c("connectivity", "con")) {
    connectivity <- as.numeric(args[i+1])
  } else if (args[i] %in% c("no.cluster")) {
    save.clusters <- FALSE
  } else if (args[i] %in% c("no.table")) {
    save.table <- FALSE
  } else if (args[i] %in% c("no.mask")) {
    save.mask <- FALSE
  } else if (args[i] %in% c("no.pos", "no.positive")) {
    do.pos <- FALSE
  } else if (args[i] %in% c("no.neg", "no.negative")) {
    do.neg <- FALSE
  } else if (args[i] %in% c("dir.save", "save.dir", "save")) {
    dir.save <- args[i+1]
  } else if (args[i] %in% c("dir.scratch", "scratch.dir", "dir.tmp", "tmp.dir")) {
    dir.scratch <- args[i+1]
  }
}

# Show input values ------------------------------------------------------------
# print(nii.coef)
# print(nii.test)
# print(nii.pval)
# print(nii.mask)
# print(effect.volume)
# print(mask.volume)
# print(effect.name)
# print(roi.thresh)
# print(peak.thresh)
# print(cluster.size)
# print(connectivity)
# print(save.clusters)
# print(save.table)
# print(save.mask)
# print(do.pos)
# print(do.neg)
# print(dir.save)
# print(dir.scratch)

# cluster function -------------------------------------------------------------
cluster.func <- function(bin.array, dimensions, connectivity=26) {
  cdim <- cumprod(c(1, dimensions[1:3][-3]))
  neighborhood <- switch(
    as.character(connectivity),
    `6` = t(matrix(c(1,2,2,2,1,2,2,2,1,3,2,2,2,3,2,2,2,3), nrow=3)),
    `18` = t(matrix(
      c(1,1,2,1,2,1,1,2,2,1,2,3,1,3,2,2,1,1,2,1,2,2,1,3,2,2,1,2,2,2,
        2,2,3,2,3,1,2,3,2,2,3,3,3,1,2,3,2,1,3,2,2,3,2,3,3,3,2), nrow=3)),
    `26` = t(matrix(
      c(1,1,1,1,1,2,1,1,3,1,2,1,1,2,2,1,2,3,1,3,1,1,3,2,1,3,3,2,1,1,
        2,1,2,2,1,3,2,2,1,2,2,3,2,3,1,2,3,2,2,3,3,3,1,1,3,1,2,3,1,3,
        3,2,1,3,2,2,3,2,3,3,3,1,3,3,2,3,3,3), nrow=3)),
    stop("Unrecognized connectivity"))
  center.pt <- t(matrix(c(2,2,2), nrow=3))
  offsets <- as.integer(colSums(t(neighborhood[ ,1:3, drop=FALSE]-1)*cdim) + 1L) -
    as.integer(colSums(t(center.pt[ ,1:3, drop=FALSE]-1)*cdim) + 1L)
  connected <- array(0, dim=dimensions[1:3])
  num.clusters <- 0
  idx <- numeric()
  for (x in 1:dimensions[1]) {
    for (y in 1:dimensions[2]) {
      for (z in 1:dimensions[3]) {
        if (bin.array[x,y,z] == 1) {
          num.clusters <- num.clusters + 1
          current.pt <- t(as.matrix(c(x,y,z)))
          idx <- as.integer(colSums(t(current.pt[ ,1:3, drop=FALSE]-1)*cdim) + 1L)
          connected[idx] <- num.clusters
          while (length(idx)!=0) {
            bin.array[idx] <- 0
            neighbors = as.vector(apply(as.matrix(idx), 1, '+', offsets))
            neighbors = unique(neighbors[which(neighbors > 0)])
            idx = neighbors[which(bin.array[neighbors]!=0)]
            connected[idx] <- num.clusters
          }
        }
      }
    }
  }
  return(connected)
}

# make scratch directory -------------------------------------------------------
dir.create(dir.scratch, showWarnings = F, recursive = F)

# copy files to scratch --------------------------------------------------------
## or unzip in scratch
tfext <- file_ext(nii.coef)
if (tfext == "gz") {
  gunzip(filename=nii.coef, destname=sprintf("%s/coef.nii", dir.scratch), remove=F)
} else {
  file.copy(from = nii.coef, to = sprintf("%s/coef.nii", dir.scratch), overwrite=T)
}
nii.coef <- sprintf("%s/coef.nii", dir.scratch)

tfext <- file_ext(nii.test)
if (tfext == "gz") {
  gunzip(filename=nii.test, destname=sprintf("%s/test.nii", dir.scratch), remove=F)
} else {
  file.copy(from = nii.test, to = sprintf("%s/test.nii", dir.scratch), overwrite=T)
}
nii.test <- sprintf("%s/test.nii", dir.scratch)

tfext <- file_ext(nii.pval)
if (tfext == "gz") {
  gunzip(filename=nii.pval, destname=sprintf("%s/pval.nii", dir.scratch), remove=F)
} else {
  file.copy(from = nii.pval, to = sprintf("%s/pval.nii", dir.scratch), overwrite=T)
}
nii.pval <- sprintf("%s/pval.nii", dir.scratch)

if (!is.null(nii.mask)) {
  tfext <- file_ext(nii.mask)
  if (tfext == "gz") {
    gunzip(filename=nii.mask, destname=sprintf("%s/mask.nii", dir.scratch), remove=F)
  } else {
    file.copy(from = nii.mask, to = sprintf("%s/mask.nii", dir.scratch), overwrite=T)
  }
  nii.mask<- sprintf("%s/mask.nii", dir.scratch)
}

# Load image dimensions and orientation ----------------------------------------
img.dims <- info.nii(nii.coef, "dims")
pixdim <- info.nii(nii.coef, "pixdim")
orient <- info.nii(nii.coef, "orient")

# load mask (if given) ---------------------------------------------------------
mask <- array(1,dim=img.dims[1:3])
if (!is.null(nii.mask)) { mask <- read.nii.volume(nii.mask, mask.volume) }

# Coefficient Estimates --------------------------------------------------------
coef <- read.nii.volume(nii.coef, effect.volume)
coef.na <- is.na(coef) * 1
coef[coef.na == 1] <- 0
coef <- coef * mask

# Statistical Tests ------------------------------------------------------------
test <- read.nii.volume(nii.test, effect.volume)
test.na <- is.na(coef) * 1
test[test.na == 1] <- 0
test <- test * mask

# P-values ---------------------------------------------------------------------
pval <- read.nii.volume(nii.pval, effect.volume)
pval.na <- is.na(pval) * 1
pval[pval.na == 1] <- 0
pval <- pval * mask

# PROCESSING -------------------------------------------------------------------
## 1. mask by SIGN of the COEFFICIENT ESTIMATES (nii.coef) (e.g., positive effects)
##    and threshold by ROI p-value
## 2. generate clusters
## 3. calculate cluster table
## 4. sort clusters by size
## 5. threshold by cluster size, excluide clusters LESS THAN desired size
## 6. add peak values (XYZ coordinates, estimate, test statistice, and p value) to cluster tables
## 7. threshold by peak p, exclude clusters without peak
## 8. renumber clusters in array, (sorted by cluster size)
## 9. output nifti clusters, mask, and table
for (i in 1:2) {
  if (do.pos & i==1) {
    tpfx <- sprintf("%s/effect-%s_dir-pos_p-%0.0g_peak-%0.0g_cl-%d",
                    dir.save, effect.name, roi.thresh, peak.thresh, cluster.size)
    sig <- (pval < roi.thresh) * (coef > 0) * 1
  } else if (do.neg & i==2) {
    tpfx <- sprintf("%s/effect-%s_dir-neg_p-%0.0g_peak-%0.0g_cl-%d",
                    dir.save, effect.name, roi.thresh, peak.thresh, cluster.size)
    sig <- (pval < roi.thresh) * (coef < 0) * 1
  }
  clusters <- cluster.func(sig, img.dims, connectivity)
  cluster.table <- as.data.frame(table(clusters))
  if (nrow(cluster.table) > 1) {
    cluster.table <- cluster.table[-1, ]
    cluster.table <- cluster.table[order(-cluster.table$Freq), ]
    cluster.table <- cluster.table[which(cluster.table$Freq >= cluster.size), ]
    cluster.table$peak.x <- cluster.table$peak.y <- cluster.table$peak.z <- as.numeric(NA)
    cluster.table$peak.estimate <- cluster.table$peak.test <- cluster.table$peak.p <- as.numeric(NA)
    for (i in 1:nrow(cluster.table)) {
      idx <- which(clusters==cluster.table$clusters[i], arr.ind=T)
      vals <- abs(test[idx])
      pk.idx <- idx[which(vals==max(vals))[1], ]
      cluster.table$peak.p[i] <- pval[pk.idx[1], pk.idx[2], pk.idx[3]]
      cluster.table$peak.x[i] <- pk.idx[1]
      cluster.table$peak.y[i] <- pk.idx[2]
      cluster.table$peak.z[i] <- pk.idx[3]
      cluster.table$peak.estimate[i] <- coef[pk.idx[1], pk.idx[2], pk.idx[3]]
      cluster.table$peak.test[i] <- test[pk.idx[1], pk.idx[2], pk.idx[3]]
    } 
    cluster.table <- cluster.table[which(cluster.table$peak.p < peak.thresh), ]
    cluster.map <- array(0, dim=img.dims[1:3])
    for (i in 1:nrow(cluster.table)) { cluster.map[which(clusters==cluster.table$clusters[i])] <- i }
    if (save.clusters) {
      fname <- sprintf("%s_cluster.nii", tpfx)
      init.nii(new.nii=fname, dims=img.dims, pixdim=pixdim, orient=orient)
      write.nii.volume(fname, 1, cluster.map)
      gzip(fname, overwrite=TRUE)
    }
    if (save.mask) {
      fname <- sprintf("%s_mask.nii", tpfx)
      init.nii(new.nii=fname, dims=img.dims, pixdim=pixdim, orient=orient)
      write.nii.volume(fname, 1, (cluster.map>0)*1)
      gzip(fname,overwrite=TRUE)
    }
    if (save.table) {
      fname <- sprintf("%s_cluster.csv", tpfx)
      write.table(cluster.table, fname, sep=",", quote=F, row.names=F, col.names=T)
    }
  } else {
    print(sprintf("NO CLUSTERS SURVIVE: effect-%s_dir-neg_p-%0.0g_peak-%0.0g_cl-%d",
		  effect.name, roi.thresh, peak.thresh, cluster.size))
  }
}

# clear scratch ----------------------------------------------------------------
invisible(file.remove(list.files(dir.scratch, full.names=T)))
invisible(file.remove(dir.scratch))

