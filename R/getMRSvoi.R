args <- commandArgs(trailingOnly = TRUE)

library(spant, quietly=T)
library(nifti.io, quietly=T)
library(tools, quietly=T)
library(R.utils, quietly=T)

dir.scratch <- sprintf("/scratch/tkni_getMRSvoi_%s", format(Sys.time(), "%Y%m%dT%H%M%S"))

for (i in seq(1,length(args))) {
  if (args[i] %in% c("nii", "nii.data")) {
    nii.data <- args[i+1]
  } else if (args[i] %in% c("mrs", "mrs.data")) {
    mrs.data <- args[i+1]
  } else if (args[i] %in% c("fname", "file", "filename")) {
    fname <- args[i+1]
  } else if (args[i] %in% c("dir.save", "save.dir", "save")) {
    dir.save <- args[i+1]
  } else if (args[i] %in% c("dir.scratch", "scratch.dir", "scratch")) {
    dir.save <- args[i+1]
  }
}

tfext <- file_ext(nii.data)
if (tfext == "gz") {
  dir.create(dir.scratch, showWarnings = F, recursive = F)
  gunzip(filename=nii.data, destname=sprintf("%s/temp.nii", dir.scratch), remove=F)
  nii.data <- sprintf("%s/temp.nii", dir.scratch)
}

mrs <- read_mrs(mrs.data)
voi <- resample_voi(get_mrsi_voi(mrs), nii.data)
init.nii(new.nii = sprintf("%s/%s.nii", dir.save, fname), ref.nii=nii.data)
write.nii.volume(sprintf("%s/%s.nii", dir.save, fname), 1, voi)

if (dir.exists(dir.scratch)) {
  invisible(file.remove(list.files(dir.scratch, full.names=T)))
  invisible(file.remove(dir.scratch))
}