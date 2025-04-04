args <- commandArgs(trailingOnly = TRUE)

invisible(library(nifti.io, quietly=T))
invisible(library(R.utils, quietly=T))
invisible(library(tools, quietly=T))
invisible(library(optimParallel, quietly=T))

TR <- 4.5
FA <- 4
TURBO <- 5
ECHO_SPACING <- 0.0023
T2PREP <- 0.9
T1.init <- 1.3
M0.init <- 875
DT <- NII_QALAS <- NII_MASK <- FNAME <- DIR.SAVE <- DIR.SCRATCH <- NULL
METHOD <- "L-BFGS-B"
NUM.CORES <- 8
VERBOSE <- FALSE

# DEBUG
#NII_QALAS="/home/mrgo/Documents/scratch/qalas_test/sub-103_ses-20231107T1701_aid-4054_qalas.nii.gz"
#NII_MASK="/home/mrgo/Documents/scratch/qalas_test/mask.nii.gz"

for (i in seq(1,length(args))) {
  if (args[i] %in% c("tr", "TR", "repetition_time")) {
    TR <- as.numeric(args[i+1])
  } else if (args[i] %in% c("fa", "FA", "flip", "flip_angle")) {
    FA <- as.numeric(args[i+1])
  } else if (args[i] %in% c("turbo", "TURBO", "turbo_factor")) {
    TURBO <- as.numeric(args[i+1])
  } else if (args[i] %in% c("echo", "ECHO", "echo_spacing")) {
    ECHO_SPACING <- as.numeric(args[i+1])
  } else if (args[i] %in% c("t2prep", "T2PREP", "t2_sensitization")) {
    T2PREP <- as.numeric(args[i+1])
  } else if (args[i] %in% c("dt", "DT")) {
    DT <- as.numeric(unlist(strsplit(args[i+1], split=",")))
  } else if (args[i] %in% c("t1", "T1", "t1_init", "T1_INIT")) {
    T1.init <- as.numeric(args[i+1])
  } else if (args[i] %in% c("m0", "M0", "m0_init", "M0_INIT")) {
    M0.init <- as.numeric(args[i+1])
  } else if (args[i] %in% c("method", "optimizer")) {
    METHOD <- args[i+1]
  } else if (args[i] %in% c("cores", "parallel", "num_cores")) {
    NUM.CORES <- args[i+1]
  } else if (args[i] %in% c("qalas", "QALAS", "nii_qalas")) {
    NII_QALAS <- args[i+1]
  } else if (args[i] %in% c("mask", "MASK", "nii_mask")) {
    NII_MASK <- args[i+1]
  } else if (args[i] %in% c("prefix", "PREFIX", "filename", "FILENAME", "fname", "FNAME")) {
    PREFIX <- args[i+1]
  } else if (args[i] %in% c("save", "dir_save", "DIR_SAVE", "SAVE")) {
    DIR.SAVE <- args[i+1]
  } else if (args[i] %in% c("scratch", "SCRATCH", "dir_scratch", "DIR_SCRATCH")) {
    DIR.SCRATCH <- args[i+1]
  }
}

#print(TR)
#print(FA)
#print(TURBO)
#print(ECHO_SPACING)
#print(T2PREP)
#print(DT)
#print(T1.init)
#print(M0.init)
#print(NII_QALAS)
#print(NII_MASK)
#print(PREFIX)
#print(DIR.SAVE)
#print(DIR.SCRATCH)

# set Timing variable to default -----------------------------------------------
if (is.null(DT)) {
  RO_DUR <- TURBO * ECHO_SPACING 
  RO_GAP <- T2PREP - RO_DUR
  DT <- c(RO_GAP - RO_DUR - 0.1097, #M0->M1
          0.1097, # M1->M2
          RO_DUR, # M2->M3
          T2PREP-RO_DUR-0.0128-0.1+0.00645, # M3->M4
          0.0128, # M4->M5
          0.1-0.00645, # M5->M6
          RO_DUR, # M6->M7
          RO_GAP, # M7->M8
          RO_DUR, # M8->M9
          RO_GAP, # M9->M10
          RO_DUR, # M10->M11
          RO_GAP, # M11->M12
          RO_DUR) # M12->M13
  DT <- c(DT, max(TR-sum(DT),0))
}

# create scratch folder --------------------------------------------------------
if (is.null(DIR.SCRATCH)) {
  DIR.SCRATCH <- sprintf("~/Documents/scratch/qalasConstants_tmp_%s", format(Sys.time(), "%Y%m%dT%H%M%S"))
}
dir.create(DIR.SCRATCH, showWarnings=F, recursive=T)

# set output defaults ----------------------------------------------------------
if (is.null(DIR.SAVE)) { DIR.SAVE <- dirname(NII_QALAS) }
if (is.null(FNAME)) {
  FNAME <- basename(NII_QALAS)
  FNAME <- file_path_sans_ext(FNAME, compression=T)
}

# unzip NII files as needed ----------------------------------------------------
tfext <- file_ext(NII_QALAS)
if (tfext == "gz") {
  gunzip(filename=NII_QALAS, destname=sprintf("%s/QALAS.nii", DIR.SCRATCH), remove=F)
  NII_QALAS=sprintf("%s/QALAS.nii", DIR.SCRATCH)
}
if (!is.null(NII_MASK)) {
  tfext <- file_ext(NII_MASK)
  if (tfext == "gz") {
    gunzip(filename=NII_MASK, destname=sprintf("%s/MASK.nii", DIR.SCRATCH), remove=F)
    NII_MASK=sprintf("%s/MASK.nii", DIR.SCRATCH)
  }
}

# gather NII header info for output --------------------------------------------
img.dims <- info.nii(NII_QALAS, "dims")
pixdim <- info.nii(NII_QALAS, "pixdim")
orient <- info.nii(NII_QALAS, "orient")

# load mask (if given) ---------------------------------------------------------
mask <- array(1,dim=img.dims[1:3])
if (!is.null(NII_MASK)) { mask <- read.nii.volume(NII_MASK, 1) }
idx <- which(mask!=0, arr.ind=T)

# load QALAS volumes -----------------------------------------------------------
Q1 <- read.nii.volume(NII_QALAS, 1)[idx]
Q2 <- read.nii.volume(NII_QALAS, 2)[idx]
Q3 <- read.nii.volume(NII_QALAS, 3)[idx]
Q4 <- read.nii.volume(NII_QALAS, 4)[idx]
Q5 <- read.nii.volume(NII_QALAS, 5)[idx]

# set up functions to predict Mz -----------------------------------------------
predictMz <- function(M0, T1, dt, ...) { return(M0*(1-exp(-dt/T1))) }
changeMz <- function(M0, T1, Mn, dt, ...) { return(M0-(M0-Mn)*exp(-dt/T1)) }

# Setup T1 and M0 optimization function ----------------------------------------
optQALAS <- function(INPUT, ...) {
  T1 <- INPUT[1]
  M0 <- INPUT[2]
  M0star <- M0 * (1-exp(-TR/T1)) / (1 - cos(FA) * exp(-TR/T1))
  T1star <- T1 * (1-exp(-TR/T1)) / (1 - cos(FA) * exp(-TR/T1))
  M6 <- predictMz(M0, T1, DT[6])
  M7 <- changeMz(M0star, T1star, M6, DT[7])
  M8 <- changeMz(M0, T1, M7, DT[8])
  M9 <- changeMz(M0star, T1star, M8, DT[9])
  M10 <- changeMz(M0, T1, M9, DT[10])
  M11 <- changeMz(M0star, T1star, M10, DT[11])
  M12 <- changeMz(M0, T1, M11, DT[12])
  M13 <- changeMz(M0star, T1star, M12, DT[13])
  M1 <<- changeMz(M0, T1, M13, sum(DT[1], DT[14]))
  MZ <- c(M6, M8, M10, M12)
  T2e <- -(T2PREP)/(log(Mobs[1]/M1))
  penalty <- 1
  print(sprintf("T1=%0.4g; M0=%0.4g; T2e=%0.4g, M1=%0.4g; Mobs[1]=%0.4g", T1, M0, T2e, M1, Mobs[1]))
  if (is.na(T2e)) {
    penalty <- 100
  } else {
    if (T1 <= T2e) { penalty <- 10}
    if (T2e <= 0) { penalty <- 10}
  }
  sum(((Mobs[2:length(Mobs)] - MZ)^2)*penalty)
}

# loop over voxels -------------------------------------------------------------
OPT.INIT <- c(T1.init, M0.init)
T1 <- T2 <- PD <- as.numeric(nrow(idx))
for (X in 1:nrow(idx)) {
  Mobs <- c(Q1[X], Q2[X], Q3[X], Q4[X], Q5[X])
  T1[X] <- T2[X] <- PD[X] <- 0
  OPT.OUT <- optim(OPT.INIT, optQALAS, method=METHOD, lower=c(0.001,0.001), upper=c(10,max(Mobs)*2))
  T1[X] <- OPT.OUT$par[1]
  T2[X] <- -(T2PREP)/(log(Mobs[1]/M1))
  PD[X] <- OPT.OUT$par[2]
  if (VERBOSE) {
    print(sprintf("%0.2f -- T1=%0.4g; T2=%0.4g; PD=%0.4g", X/nrow(idx), T1[X], T2[X], PD[X]))
  }
}

# output results ----------------------------------------------------------------
TT1 <- TT2 <- TPD <- read.nii.volume(NII_QALAS, 1)*0
TT1[idx] <- T1
TT2[idx] <- T2
TPD[idx] <- PD
## clamp negative values to 0
TT1[TT1<0] <- 0
TT2[TT2<0] <- 0
TPD[TPD<0] <- 0

FT1 <- sprintf("%s/%s_T1map.nii", DIR.SAVE, FNAME)
FT2 <- sprintf("%s/%s_T2map.nii", DIR.SAVE, FNAME)
FPD <- sprintf("%s/%s_PDunscaled.nii", DIR.SAVE, FNAME)
init.nii(FT1, dims=img.dims, pixdim=pixdim, orient=orient, datatype=64)
init.nii(FT2, dims=img.dims, pixdim=pixdim, orient=orient, datatype=64)
init.nii(FPD, dims=img.dims, pixdim=pixdim, orient=orient, datatype=64)
write.nii.volume(FT1, 1, TT1)
write.nii.voxel(FT2, 1, TT2)
write.nii.voxel(FPD, 1, TPD)

# remove scratch directory
fs::dir_delete(DIR.SCRATCH)

