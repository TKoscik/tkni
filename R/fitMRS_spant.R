args <- commandArgs(trailingOnly = TRUE)

library(spant, quietly=T)
library(nifti.io, quietly=T)
source("/usr/local/tkni/dev/R/spant_fit_svs.R")

HSVD=30
EDDY=TRUE
DFP=TRUE
CSF <- GM <- WM <- NULL
dir.scratch <- sprintf("/scratch/tkni_fitMRS_spant_%s", format(Sys.time(), "%Y%m%dT%H%M%S"))

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
  } else if (args[i] %in% c("dir.scratch", "scratch.dir", "scratch")) {
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

p.vols=c(wm=0, gm=100, csf=0)
if (!is.null(WM)) { p.vols[1] <- WM}
if (!is.null(GM)) { p.vols[2] <- GM}
if (!is.null(CSF)) { p.vols[3] <- CSF}

#dir.create(dir.scratch, showWarnings = F, recursive = F)
#file.copy(from=mrs.data, to=sprintf("%s/mrs.dat", dir.scratch), overwrite=T)
#setwd(dir.scratch)
#mrs <- read_mrs(sprintf("%s/mrs.dat", dir.scratch))
#print(mrs.data)
#print(dir.save)
#print(p.vols)
spant_fit_svs(input=mrs.data, output_dir=dir.save,
        p_vols=p.vols, ecc=EDDY, hsvd_width=HSVD, dfp_corr=DFP, use_basis_cache="never")

