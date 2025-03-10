args <- commandArgs(trailingOnly = TRUE)

invisible(library(nifti.io, quietly=T))
invisible(library(mclust, quietly=T))
invisible(library(R.utils, quietly=T))
invisible(library(tools, quietly=T))

NCL <- 3
CLNAME <- c("CSF", "GM", "WM")
ORDER.BY <- "PD"
PREFIX <- NULL
DIR.SAVE <- NULL
DIR.SCRATCH <- NULL

for (i in seq(1,length(args))) {
  if (args[i] %in% c("t1", "T1", "longitudinal_relaxation_time", "longitudinal")) {
    NII_T1 <- args[i+1]
  } else if (args[i] %in% c("t2", "T2", "transverse_relaxation_time", "transverse")) {
    NII_T2 <- args[i+1]
  } else if (args[i] %in% c("pd", "PD", "proton_density")) {
    NII_PD <- args[i+1]
  } else if (args[i] %in% c("mask", "MASK", "nii_mask")) {
    NII_MASK <- args[i+1]
  } else if (args[i] %in% c("n", "g", "cluster", "mixture_components", "components")) {
    NCL <- as.numeric(args[i+1])
  } else if (args[i] %in% c("prefix", "PREFIX", "filename", "FILENAME", "fname", "FNAME")) {
    PREFIX <- args[i+1]
  } else if (args[i] %in% c("save", "dir_save", "DIR_SAVE", "SAVE")) {
    DIR.SAVE <- args[i+1]
  } else if (args[i] %in% c("scratch", "SCRATCH", "dir_scratch", "DIR_SCRATCH")) {
    DIR.SCRATCH <- args[i+1]
  }
}

# create scratch folder --------------------------------------------------------
if (is.null(DIR.SCRATCH)) {
  DIR.SCRATCH <- sprintf("~/Documents/scratch/qmriMClust_tmp_%s", format(Sys.time(), "%Y%m%dT%H%M%S"))
}
dir.create(DIR.SCRATCH, showWarnings=F, recursive=T)

# set output defaults ----------------------------------------------------------
if (is.null(DIR.SAVE)) { DIR.SAVE <- dirname(NII_T1) }
if (is.null(PREFIX)) {
  PREFIX <- basename(NII_T1)
  PREFIX <- file_path_sans_ext(PREFIX, compression=T)
  PREFIX <- unlist(strsplit(PREFIX, split="_"))
  PREFIX <- paste0(PREFIX[1:(length(PREFIX)-1)], collapse="_")
}

# unzip NII files as needed ----------------------------------------------------
if (file_ext(NII_T1) == "gz") {
  gunzip(filename=NII_T1, destname=sprintf("%s/T1.nii", DIR.SCRATCH), remove=F)
  NII_T1=sprintf("%s/T1.nii", DIR.SCRATCH)
}
if (file_ext(NII_T2) == "gz") {
  gunzip(filename=NII_T2, destname=sprintf("%s/T2.nii", DIR.SCRATCH), remove=F)
  NII_T2=sprintf("%s/T2.nii", DIR.SCRATCH)
}
if (file_ext(NII_PD) == "gz") {
  gunzip(filename=NII_PD, destname=sprintf("%s/PD.nii", DIR.SCRATCH), remove=F)
  NII_PD=sprintf("%s/PD.nii", DIR.SCRATCH)
}
if (!is.null(NII_MASK)) {
  if (file_ext(NII_MASK) == "gz") {
    gunzip(filename=NII_MASK, destname=sprintf("%s/MASK.nii", DIR.SCRATCH), remove=F)
    NII_MASK=sprintf("%s/MASK.nii", DIR.SCRATCH)
  }
}

# gather NII header info for output --------------------------------------------
img.dims <- info.nii(NII_T1, "dims")
pixdim <- info.nii(NII_T1, "pixdim")
orient <- info.nii(NII_T1, "orient")

# load mask (if given) ---------------------------------------------------------
mask <- array(1,dim=img.dims[1:3])
if (!is.null(NII_MASK)) { mask <- read.nii.volume(NII_MASK, 1) }
idx <- which(mask!=0, arr.ind=T)

# load QALAS volumes -----------------------------------------------------------
df <- data.frame(T1=scale(read.nii.volume(NII_T1, 1)[idx], center=F, scale=T),
                 T2=scale(read.nii.volume(NII_T2, 1)[idx], center=F, scale=T),
                 PD=scale(read.nii.volume(NII_PD, 1)[idx], center=F, scale=T))

# Run Model-based clustering based on parameterized Gaussian mixture models ----
mc <- Mclust(df, G=NCL)

# mc$z                A matrix whose [i,k]th entry is the probability that
#                     observation i in the test data belongs to the kth class.
# mc$parameters$mean  The mean for each component. If there is more than one
#                     component, this is a matrix whose kth column is the mean
#                     of the kth component of the mixture model.
# mc$classification   Classification of voxel into cluster

# Set order of cluster labels and values ---------------------------------------
if (ORDER.BY == "T1") {
  cl.order <- order(mc$parameters$mean[1, ], decreasing=T)
} else if (ORDER.BY == "T2") {
  cl.order <- order(mc$parameters$mean[2, ], decreasing=T)
} else if (ORDER.BY == "PD") {
  cl.order <- order(mc$parameters$mean[3, ], decreasing=T)
} else if (ORDER.BY == "DIST") {
  cl.order <- order(sqrt(colSums(mc$parameters$mean^2)), decreasing=T)
} else if (ORDER.BY == "T1T2") {
  cl.order <- order(sqrt(colSums(mc$parameters$mean[1:2, ]^2)), decreasing=T)
} else if (ORDER.BY == "T1PD") {
  cl.order <- order(sqrt(colSums(mc$parameters$mean[c(1,3), ]^2)), decreasing=T)
} else if (ORDER.BY == "T2PD") {
  cl.order <- order(sqrt(colSums(mc$parameters$mean[2:3, ]^2)), decreasing=T)
}

# write out Posteriors and classification --------------------------------------
CX <- mask * 0
for (i in 1:NCL) {
  TCL <- cl.order[i]
  POST <- sprintf("%s/%s_posterior-%s.nii", DIR.SAVE, PREFIX, CLNAME[TCL])
  AX <- mask * 0
  AX[idx] <- mc$z[ ,TCL]
  init.nii(POST, dims=img.dims, pixdim=pixdim, orient=orient, datatype=64)
  write.nii.volume(POST, 1, AX)

  CLIDX <- idx[mc$classification == TCL, ]
  CX[CLIDX] <- i
}
SEG <- sprintf("%s/%s_label-tissue+QMRI.nii", DIR.SAVE, PREFIX)
init.nii(SEG, dims=img.dims, pixdim=pixdim, orient=orient)
write.nii.volume(SEG, 1, CX)

# remove scratch directory -----------------------------------------------------
fs::dir_delete(DIR.SCRATCH)
