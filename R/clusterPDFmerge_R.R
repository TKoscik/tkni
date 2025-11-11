clusterPDFmerge_R <- function(nii.intensity,
                              nii.segmentation,
                              overlap.threshold=0.25,
                              dir.save,
                              nii.save) {
  
  # load libraries -------------------------------------------------------------
  requires("nifti.io")
  requires("data.table")
  requires("tools")
  
  # parse inputs ---------------------------------------------------------------
  ## check nii NOT nii.gz
  if (has_extension(nii.intensity, "gz")) {
    stop("ERROR [TKNI:clusterWatershed.R] Intensity NII file must be decompressed.")
  }
  if (has_extension(nii.segmentation, "gz")) {
    stop("ERROR [TKNI:clusterWatershed.R] Segmentation NII file must be decompressed.")
  }
  
  # read in data ---------------------------------------------------------------
  intensity <- read.nii.volume(nii.intensity, 1)
  seg <- read.nii.volume(nii.seg, 1)
  
  # get original label list ----------------------------------------------------
  labels <- sort(unique(as.vector(seg)))[-1]
  n.labels <- length(labels)
  
  # compare touching labels (face sharing) -------------------------------------
  nn <- t(matrix(c(-1,0,0,0,-1,0,0,0,-1,1,0,0,0,1,0,0,0,1), nrow=3))
  joinls <- integer(n.labels)
  while (any(joinls == 0)) {
    label.which <- which(joinls == 0)[1]
    joinls[label.which] <- labels[label.which]
    label.idx <- as.data.table(which(seg==labels[label.which], arr.ind=T))
    label.vals <- intensity[which(seg==label.which, arr.ind=T)]
    label.mean <- mean(label.vals, na.rm=T)
    label.sd <- sd(label.vals, na.rm=T)
    label.pdf <- function(x) dnorm(x, mean=label.mean, sd=label.sd)
    # evaluate touching neighbors
    for (i in 1:nrow(nn)) {
      touch.idx <- as.data.table(sweep(label.idx, 2, nn[i,], FUN="+"))
      touch.idx <- as.matrix(unique(touch.idx[!label.idx, on=c("dim1", "dim2", "dim3")]))
      touch.which <- unique(seg[as.matrix(touch.idx)])
      touch.which <- touch.which[-which(touch.which==0)]
      overlap.coef <- numeric(length(touch.which))
      for (j in 1:length(touch.which)) {
        touch.vals <- intensity[which(seg==touch.which[j], arr.ind=T)]
        touch.mean <- mean(touch.vals, na.rm=T)
        touch.sd <- sd(touch.vals, na.rm=T)
        touch.pdf <- function(x) dnorm(x, mean=touch.mean, sd=touch.sd)
        min.pdf <- function(x) { pmin(label.pdf(x), touch.pdf(x))}
        overlap.coef[j] <- integrate(min.pdf, lower=-Inf, upper=Inf)$value
      }
      touch.sig <- which(overlap.coef>overlap.threshold)
      joinls[touch.sig] <- labels[label.which]
    }
  }
  
  # relabel values -------------------------------------------------------------
  new.seg <- seg * 0
  joinls <- order(joinls) # renumber the labels so they are no gaps in the range
  for (i in 1:length(label.ls)) {
    new.seg[which(seg==label.ls[i])] <- joinls[i]
  }
  
  # save output ----------------------------------------------------------------
  init.nii(nii.save, dims=img.dims, pixdim=pixdim, orient=orient)
  write.nii.volume(nii.save, 1, new.seg)
  
}