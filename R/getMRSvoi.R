args <- commandArgs(trailingOnly = TRUE)

library(spant, quietly=T)
library(nifti.io, quietly=T)

for (i in seq(1,length(args))) {
  if (args[i] %in% c("nii", "nii.data")) {
    nii.data <- args[i+1]
  } else if (args[i] %in% c("mrs", "mrs.data")) {
    mrs.data <- args[i+1]
  } else if (args[i] %in% c("fname", "file", "filename")) {
    fname <- args[i+1]
  } else if (args[i] %in% c("dir.save", "save.dir", "save")) {
    dir.save <- args[i+1]
  }
}

voi <- resample_voi(get_mrsi_voi(mrs.data), nii.data)
init.nii(new.nii = sprintf("%s/%s.nii", dir.save, fname), ref.nii=nii.data)
write.nii.volume(sprintf("%s/%s.nii", dir.save, fname), 1, nii)
