clusterWatershed_R <- function(nii.distance,
                               nii.mask,
                               connectivity = 6,
                               datum = "2vox",
                               dir.save,
                               nii.save) {
  
  # load libraries -------------------------------------------------------------
  requires("nifti.io")
  requires("data.table")
  requires("tools")
  
  # parse inputs ---------------------------------------------------------------
  ## check nii NOT nii.gz
  if (has_extension(nii.distance, "gz")) {
    stop("ERROR [TKNI:clusterWatershed.R] Distance NII file must be decompressed.")
  }
  if (has_extension(nii.mask, "gz")) {
    stop("ERROR [TKNI:clusterWatershed.R] ROI mask NII file must be decompressed.")
  }
  if (has_extension(nii.save, "gz")) {
    stop("ERROR [TKNI:clusterWatershed.R] Desired NII save file must not be compressed.")
  }
  
  ## set datum
  if (grepl("vox")) {
    nvox <- unlist(strsplit(datum, "vox"))[1]
    voxel.size <- info.nii(nii.distance, "spacing")
    datum <- nvox * min(voxel.size)
  }
  
  # load data ------------------------------------------------------------------
  mask <- read.nii.volume(nii.mask,1)
  dist <- read.nii.volume(nii.distance,1) * mask
  img.dims <- info.nii(nii.distance, "dims")
  pixdim=info.nii(nii.distance, field="pixdim")
  orient=info.nii(nii.distance, field="orient")
  
  ## clear mask from memory
  rm(list=c("mask")); gc()
  
  # Initialize connectivity neighborhood ---------------------------------------
  n <- 3
  dimorder <- 1:3
  cdim <- cumprod(c(1, img.dims[dimorder][-n]))
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
  
  # initialize clustering arrays -----------------------------------------------
  volume <- (dist >= datum)*1
  connected <- array(0, dim=img.dims[1:3])
  
  # cluster initial cores ------------------------------------------------------
  num.clusters <- 0
  idx <- numeric()
  for (x in 1:img.dims[1]) {
    for (y in 1:img.dims[2]) {
      for (z in 1:img.dims[3]) {
        if (volume[x,y,z] == 1) {
          num.clusters <- num.clusters + 1
          current.pt <- t(as.matrix(c(x,y,z)))
          idx <- as.integer(colSums(t(current.pt[ ,1:3, drop=FALSE]-1)*cdim) + 1L)
          connected[idx] <- num.clusters
          while (length(idx)!=0) {
            volume[idx] <- 0
            neighbors = as.vector(apply(as.matrix(idx), 1, '+', offsets))
            neighbors = unique(neighbors[which(neighbors > 0)])
            idx = neighbors[which(volume[neighbors]!=0)]
            connected[idx] <- num.clusters
          }
        }
      }
    }
  }
  init.nii(nii.save, dims=img.dims, pixdim=pixdim, orient=orient)
  write.nii.volume(nii.save, 1, connected)
  # reclaim and clean memory
  rm("volume");   gc()
  
  # Fill in labels from core edges ---------------------------------------------
  ## move 1 voxel of a boundary, add if they are touching a label
  label.xyz <- as.data.table(which(connected>0, arr.ind=T))
  blank.xyz <- as.data.table(which(dist<datum & dist > 0, arr.ind=TRUE))
  nn <- t(matrix(c(-1,0,0,0,-1,0,0,0,-1,1,0,0,0,1,0,0,0,1), nrow=3))
  keep.going <- TRUE
  while (keep.going) {
    ttbl <- data.table(dim1=integer(), dim2=integer(), dim3=integer())
    for (i in 1:nrow(nn)) {
      tx <- as.data.table(sweep(blank.xyz, 2, nn[i,], FUN="+"))
      tint <- as.matrix(tx[label.xyz, on=c("dim1", "dim2", "dim3"), nomatch=NULL])
      if (nrow(tint) > 0) {
        vals <- connected[tint]
        idx <- sweep(tint, 2, nn[i, ], FUN="-")
        connected[idx] <- vals
        ttbl <- rbind(ttbl, as.data.table(idx))
        rm(list=c("tx", "vals", "idx"))
        gc()
      }
    }
    ttbl <- unique(ttbl)
    if (nrow(ttbl) != 0) {
      new.blank <- blank.xyz[!ttbl, on=c("dim1", "dim2", "dim3")]
      blank.xyz <- new.blank
      label.xyz <- ttbl
      rm(list=c("new.blank"))
    } else {
      keep.going = FALSE
    }
    rm(list=c("ttbl"))
    gc()
  }
  write.nii.volume(nii.save, 1, connected)
  
  # Add small clusters with sub-datum peaks ------------------------------------
  if (nrow(blank.xyz) > 0) {
    small.labels <- array(0, dim=img.dims[1:3])
    small.blobs <- (dist<distance.thresh & dist>0 & connected==0) * 1
    idx <- numeric()
    for (x in 1:img.dims[1]) {
      for (y in 1:img.dims[2]) {
        for (z in 1:img.dims[3]) {
          if (small.blobs[x,y,z] == 1) {
            num.clusters <- num.clusters + 1
            current.pt <- t(as.matrix(c(x,y,z)))
            idx <- as.integer(colSums(t(current.pt[ ,1:3, drop=FALSE]-1)*cdim) + 1L)
            small.labels[idx] <- num.clusters
            while (length(idx)!=0) {
              small.blobs[idx] <- 0
              neighbors = as.vector(apply(as.matrix(idx), 1, '+', offsets))
              neighbors = unique(neighbors[which(neighbors > 0)])
              idx = neighbors[which(small.blobs[neighbors]!=0)]
              small.labels[idx] <- num.clusters
            }
          }
        }
      }
    }
  }
  idx <- which(small.labels != 0)
  connected[idx] <- small.labels[idx]
  write.nii.volume(nii.save, 1, connected)
}