clusterEffect <- function(nii.coef, nii.test, nii.pval, nii.mask,
                          volume, mask.volume,
                          roi.thresh, peak.thresh,
                          cluster.size, connectivity=NULL,
                          save.clusters=TRUE, save.table=TRUE, save.mask=TRUE,
                          dir.save, dir.scratch) {

  ## DEBUG ------------------------
  # nii.coef <- "/data/x/projects/xou/geglowing/derivatives/tkni/analyses/model-mom_mainEffect-fatTotalT1_dv-fa_20241217/coef_Estimate.nii.gz"
  # nii.test <- "/data/x/projects/xou/geglowing/derivatives/tkni/analyses/model-mom_mainEffect-fatTotalT1_dv-fa_20241217/coef_tvalue.nii.gz"
  # nii.pval <- "/data/x/projects/xou/geglowing/derivatives/tkni/analyses/model-mom_mainEffect-fatTotalT1_dv-fa_20241217/coef_Prt.nii.gz"
  # volume <- 2
  # roi.thresh <- 0.05 ## DEFINES HOW CLUSTERS ARE GENERATED
  # peak.thresh <- 0.001 ## EXCLUDES CLUSTERS WITHOUT HIGH PEAK
  # cluster.size <- 25
  # effect.name <- "testName"
  # dir.save <- "/data/x/projects/xou/geglowing/derivatives/tkni/analyses/model-mom_mainEffect-fatTotalT1_dv-fa_20241217"

  # load libraries
  require(nifti.io)
  require(R.utils)
  require(tools)

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

  # make scratch directory -----------------------------------------------------
  if (missing(dir.scratch)) {
    dir.scratch <- sprintf("/scratch/tkni_clusterEffect_%s", format(Sys.time(), "%Y%m%dT%H%M%S"))
  }
  dir.create(dir.scratch, showWarnings = F, recursive = F)

  # copy files to scratch ------------------------------------------------------
  ## or unzip in scratch
  tfext <- file_ext(nii.coef)
  if (tfext == "gz") {
    gunzip(filename=nii.coef, destname=sprintf("%s/coef.nii", dir.scratch), remove=F)
  } else {
    file.copy(from = nii.coef, to = sprint("%s/coef.nii", dir.scratch))
  }
  nii.coef <- sprintf("%s/coef.nii", dir.scratch)

  tfext <- file_ext(nii.test)
  if (tfext == "gz") {
    gunzip(filename=nii.test, destname=sprintf("%s/test.nii", dir.scratch), remove=F)
  } else {
    file.copy(from = nii.test, to = sprint("%s/test.nii", dir.scratch))
  }
  nii.test <- sprintf("%s/test.nii", dir.scratch)

  tfext <- file_ext(nii.pval)
  if (tfext == "gz") {
    gunzip(filename=nii.pval, destname=sprintf("%s/pval.nii", dir.scratch), remove=F)
  } else {
    file.copy(from = nii.pval, to = sprint("%s/pval.nii", dir.scratch))
  }
  nii.pval <- sprintf("%s/pval.nii", dir.scratch)

  if (!missing(nii.mask)) {
    tfext <- file_ext(nii.mask)
    if (tfext == "gz") {
      gunzip(filename=nii.mask, destname=sprintf("%s/mask.nii", dir.scratch), remove=F)
    } else {
      file.copy(from = nii.mask, to = sprint("%s/mask.nii", dir.scratch))
    }
    nii.mask<- sprintf("%s/mask.nii", dir.scratch)
  }
  # Load image dimensions and orientation --------------------------------------
  img.dims <- info.nii(nii.coef, "dims")
  pixdim <- info.nii(nii.coef, "pixdim")
  orient <- info.nii(nii.coef, "orient")

  # load mask (if given) -------------------------------------------------------
  mask <- array(1,dim=img.dims[1:3])
  if (!missing(nii.mask)) { mask <- read.nii.volume(nii.mask, mask.volume) }

  # Coefficient Estimates -----------------------------------------------------
  coef <- read.nii.volume(nii.coef, volume)
  coef.na <- is.na(coef) * 1
  coef[coef.na == 1] <- 0
  coef <- coef * mask
  coef.pos <- (coef > 0) * 1
  coef.neg <- (coef < 0) * 1

  # Statistical Tests ----------------------------------------------------------
  test <- read.nii.volume(nii.test, volume)
  test.na <- is.na(coef) * 1
  test[test.na == 1] <- 0
  test <- test * mask

  # P-values -------------------------------------------------------------------
  pval <- read.nii.volume(nii.pval, volume)
  pval.na <- is.na(pval) * 1
  pval[pval.na == 1] <- 0
  pval <- pval * mask

  # Threshold  by direction ----------------------------------------------------
  sig.pos <- (pval < roi.thresh) * coef.pos
  sig.neg <- (pval < roi.thresh) * coef.neg

  # Generate clusters ----------------------------------------------------------
  clust.pos <- cluster.func(sig.pos, img.dims)
  clust.neg <- cluster.func(sig.neg, img.dims)
  ## convert to tables
  clust.pos.table <- as.data.frame(table(clust.pos))[-1, ]
  clust.neg.table <- as.data.frame(table(clust.neg))[-1, ]
  ## sort clusters by size
  clust.pos.table <- clust.pos.table[order(-clust.pos.table$Freq), ]
  clust.neg.table <- clust.neg.table[order(-clust.neg.table$Freq), ]
  ## threshold by cluster size
  clust.pos.table <- clust.pos.table[which(clust.pos.table$Freq >= cluster.size), ]
  clust.neg.table <- clust.neg.table[which(clust.neg.table$Freq >= cluster.size), ]

  # Add peak values to cluster tables ------------------------------------------
  clust.pos.table$peak.x <- clust.pos.table$peak.y <- clust.pos.table$peak.z <- as.numeric(NA)
  clust.pos.table$peak.estimate <- clust.pos.table$peak.test <- clust.pos.table$peak.p <- as.numeric(NA)
  for (i in 1:nrow(clust.pos.table)) {
    idx <- which(clust.pos==clust.pos.table$clust.pos[i], arr.ind=T)
    vals <- abs(test[idx])
    pk.idx <- idx[which(vals==max(vals))[1], ]
    clust.pos.table$peak.p[i] <- pval[pk.idx[1], pk.idx[2], pk.idx[3]]
    clust.pos.table$peak.x[i] <- pk.idx[1]
    clust.pos.table$peak.y[i] <- pk.idx[2]
    clust.pos.table$peak.z[i] <- pk.idx[3]
    clust.pos.table$peak.estimate[i] <- coef[pk.idx[1], pk.idx[2], pk.idx[3]]
    clust.pos.table$peak.test[i] <- test[pk.idx[1], pk.idx[2], pk.idx[3]]
  }
  # threshold by peak p
  clust.pos.table <- clust.pos.table[which(clust.pos.table$peak.p < peak.thresh), ]
  clust.neg.table <- clust.neg.table[which(clust.neg.table$peak.p < peak.thresh), ]

  # renumber clusters in array -------------------------------------------------
  clust.pos.map <- array(0, dim=img.dims[1:3])
  for (i in 1:nrow(clust.pos.table)) { clust.pos.map[which(clust.pos==clust.pos.table$clust.pos[i])] <- i }
  clust.neg.map <- array(0, dim=img.dims[1:3])
  for (i in 1:nrow(clust.neg.table)) { clust.neg.map[which(clust.neg==clust.neg.table$clust.neg[i])] <- i }

  # output nifti clusters ------------------------------------------------------
  if (save.clusters) {
    fname <- sprintf("%s/effect-%s_dir-pos_p-%0.0g_cl-%d_cluster.nii", dir.save, effect.name, p.threshold, cluster.size)
    init.nii(new.nii=fname, dims=img.dims, pixdim=pixdim, orient=orient)
    write.nii.volume(fname, 1, clust.pos.map)
    fname <- sprintf("%s/effect-%s_dir-neg_p-%0.0g_cl-%d_cluster.nii", dir.save, effect.name, p.threshold, cluster.size)
    init.nii(new.nii=fname, dims=img.dims, pixdim=pixdim, orient=orient)
    write.nii.volume(fname, 1, clust.neg.map)
  }

  if (save.mask) {
    fname <- sprintf("%s/effect-%s_dir-pos_p-%0.0g_cl-%d_mask.nii", dir.save, effect.name, p.threshold, cluster.size)
    init.nii(new.nii=fname, dims=img.dims, pixdim=pixdim, orient=orient)
    write.nii.volume(fname, 1, (clust.pos.map>0)*1)
    fname <- sprintf("%s/effect-%s_dir-neg_p-%0.0g_cl-%d_mask.nii", dir.save, effect.name, p.threshold, cluster.size)
    init.nii(new.nii=fname, dims=img.dims, pixdim=pixdim, orient=orient)
    write.nii.volume(fname, 1, (clust.neg.map>0)*1)
  }

  # Save Cluster Table ---------------------------------------------------------
  if (save.table) {
    fname <- sprintf("%s/effect-%s_dir-pos_p-%0.0g_cl-%d_cluster.csv", dir.save, effect.name, p.threshold, cluster.size)
    write.table(clust.pos.table, fname, sep=",", quote=F, row.names=F, col.names=T)
    fname <- sprintf("%s/effect-%s_dir-neg_p-%0.0g_cl-%d_cluster.csv", dir.save, effect.name, p.threshold, cluster.size)
    write.table(clust.neg.table, fname, sep=",", quote=F, row.names=F, col.names=T)
  }

  # clear scratch --------------------------------------------------------------
  invisible(file.remove(list.files(dir.scratch, full.names=T)))
  invisible(file.remove(dir.scratch))
}
