args <- commandArgs(trailingOnly = TRUE)

library(spant, quietly=T)
library(nifti.io, quietly=T)

HSVD=30
EDDY=TRUE
DFP=TRUE
CSF <- GM <- WM <- NULL

for (i in seq(1,length(args))) {
  if (args[i] %in% c("mrs", "mrs.data")) {
    mrs.data <- args[i+1]
  } else if (args[i] %in% c("hsvd", "no-hsvd")) {
    no.hsvd <- args[i+1]
  } else if (args[i] %in% c("eddy", "no-eddy")) {
    no.eddy <- args[i+1]
  } else if (args[i] %in% c("dfp", "no-dfp")) {
    no.dfp <- args[i+1]
  } else if (args[i] %in% c("csf", "csf-pct")) {
    CSF <- as.numeric(args[i+1])
  } else if (args[i] %in% c("gm", "gm.pct")) {
    GM <- as.numeric(args[i+1])
  } else if (args[i] %in% c("wm", "wm.pct")) {
    WM <- as.numeric(args[i+1])
  } else if (args[i] %in% c("dir.save", "save.dir", "save")) {
    dir.save <- args[i+1]
  }
}

if (no.hsvd == "true") {
  HSVD=NULL
} else if (no.hsvd != "false" ) {
  HSVD=as.numeric(no.hsvd)
}

if (no.eddy == "true") { EDDY=FALSE }
if (no.dfp == "true") { DFP=FALSE }

p_vols=c(wm=0, gm=100, csf=0)
if (!is.null(WM)) { p_vols[1] <- WM}
if (!is.null(GM)) { p_vols[2] <- GM}
if (!is.null(CSF)) { p_vols[3] <- CSF}

fit_svs(input = mrs.data, output_dir = dir.save, pvols=p_vols, ecc=EDDY, hsvd_width=HSVD, dfp_corr=DFP)

