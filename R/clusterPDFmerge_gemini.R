args <- commandArgs(trailingOnly = TRUE)

nii.intensity <- args[1]
nii.segmentation <- args[2]
overlap.threshold <- 0.25
num.cores <- 24
dir.save <- "default"
nii.save <- "default"

for (i in seq(1,length(args))) {
  if (args[i] %in% c("i", "intensity", "-i")) {
    nii.intensity <- args[i+1]
  } else if (args[i] %in% c("s", "segmentation", "segment", "seg", "-s")) {
    nii.segmentation <- args[i+1]
  } else if (args[i] %in% c("o", "overlap", "-o")) {
    overlap.threshold <- as.numeric(args[i+1])
  } else if (args[i] %in% c("c", "cores", "num.cores", "-c")) {
    num.cores <- as.numeric(args[i+1])
  } else if (args[i] %in% c("dir-save", "dir-save", "-s")) {
    dir.save <- args[i+1]
  } else if (args[i] %in% c("f", "filename", "-f")) {
    nii.save <- args[i+1]
  }
}

# load libraries ---------------------------------------------------------------
require("nifti.io")
require("data.table")
require("tools")
require("future.apply")

# parse inputs -----------------------------------------------------------------
## check nii NOT nii.gz
if (file_ext(nii.intensity) == "gz") {
  stop("ERROR [TKNI:clusterPDFmerge.R] Intensity NII file must be decompressed.")
}
if (file_ext(nii.segmentation) == "gz") {
  stop("ERROR [TKNI:clusterPDFmerge.R] Segmentation NII file must be decompressed.")
}
if (dir.save == "default") {dir.save <- dirname(nii.segmentation)}
if (nii.save == "default") {
  TBASE <- basename(nii.distance)
  nii.save <- paste0(gsub(".nii", "", TBASE), "+pdfmerge", overlap.threshold, ".nii")
}
if (file_ext(nii.save) == "gz") {
  stop("ERROR [TKNI:clusterPDFmerge.R] Desired NII save file must not be compressed.")
}

# read in data -----------------------------------------------------------------
print("MSG [TKNI:clusterPDFmerge.R] >>>reading data")
intensity <- read.nii.volume(nii.intensity, 1)
segmentation <- read.nii.volume(nii.segmentation, 1)
img.dims <- info.nii(nii.segmentation, "dims")
pixdim <- info.nii(nii.segmentation, "pixdim")
orient <- info.nii(nii.segmentation, "orient")

# precalculate MEANs and SDs for each label ------------------------------------
print("MSG [TKNI:clusterPDFmerge.R] >>>precalculate means and SDs")
plan(multisession, workers = num.cores)
all_means <- future_tapply(intensity, segmentation, mean, na.rm = TRUE)
all_sds   <- future_tapply(intensity, segmentation, sd, na.rm = TRUE)
stats <- data.frame(id=names(all_means),
                    m=as.numeric(all_means),
                    s=as.numeric(all_sds))

# Rapid Adjacency via Array Shifting -------------------------------------------
# Check X, Y, and Z neighbors
# Ensure unique pairs (sorted to avoid duplicates like 1-2 and 2-1)
print("MSG [TKNI:clusterPDFmerge.R] >>>identify adjacencies")
get_adj_pairs <- function(seg) {
  d <- dim(seg)
  p1 <- cbind(as.vector(seg[1:(d[1]-1), ,]), as.vector(seg[2:d[1], ,]))
  p2 <- cbind(as.vector(seg[, 1:(d[2]-1),]), as.vector(seg[, 2:d[2],]))
  p3 <- cbind(as.vector(seg[, , 1:(d[3]-1)]), as.vector(seg[, , 2:d[3]]))
  all_p <- rbind(p1, p2, p3)
  all_p <- all_p[all_p[,1] != all_p[,2] & all_p[,1] != 0 & all_p[,2] != 0, ]
  unique(t(apply(all_p, 1, sort)))
}
adj_pairs <- get_adj_pairs(segmentation)

# Fast Analytical Overlap Function ---------------------------------------------
# 0. overlap function
# 1. Setup parallel workers (e.g., use 4 cores)
# 2. Pre-calculate all overlaps in parallel
# We pass the stats dataframe to workers so they can look up means/SDs
# 3. Process Merges Sequentially (now very fast)
print("MSG [TKNI:clusterPDFmerge.R] >>>specifying overlap function")
calc_overlap <- function(m1, s1, m2, s2) {
  if (any(is.na(c(m1, s1, m2, s2)))) { return(0) }
  if (m1 == m2 && s1 == s2) { return(1) }
  if (abs(s1 - s2) < 1e-9) { return(2 * pnorm(-abs(m1 - m2) / (2 * s1))) }
  var1 <- s1^2
  var2 <- s2^2
  a <- var1-var2
  b <- 2*(m1*var2-m2*var1)
  c <- m2^2*var1-m1^2*var2-2*var1*var2*log(s1/s2)
  roots <- c((-b+sqrt(b^2-4*a*c))/(2*a), (-b-sqrt(b^2-4*a*c))/(2*a))
  x_int <- roots[roots > min(m1, m2) & roots < max(m1, m2)]
  if (length(x_int) == 0) { x_int <- roots[which.min(abs(roots - (m1 + m2)/2))] }
  if (m1 < m2) { return(pnorm(x_int, m1, s1, lower.tail=F) + pnorm(x_int, m2, s2)) }
  return(pnorm(x_int, m2, s2, lower.tail=F) + pnorm(x_int, m1, s1))
}
print("MSG [TKNI:clusterPDFmerge.R] >>>precalculate overlap")
overlaps <- future_sapply(1:nrow(adj_pairs),
  function(i) {l1 <- as.character(adj_pairs[i, 1])
               l2 <- as.character(adj_pairs[i, 2])
               s1_idx <- which(stats$id == l1)
               s2_idx <- which(stats$id == l2)
               if (length(s1_idx) == 0 || length(s2_idx) == 0) { return(0) }
               calc_overlap(stats$m[s1_idx], stats$s[s1_idx], stats$m[s2_idx], stats$s[s2_idx])
              },
  future.seed = TRUE)
print("MSG [TKNI:clusterPDFmerge.R] >>>merge similar neighbors")
for (i in 1:nrow(adj_pairs)) {
  if (overlaps[i] > overlap.threshold) {
    l1 <- as.character(adj_pairs[i, 1])
    l2 <- as.character(adj_pairs[i, 2])
    target_label <- label_map[l1]
    label_map[label_map == l2] <- target_label
  }
  print(sprintf("Merging %f done", i/nrow(adj_pairs)))
}


# Process Merges ---------------------------------------------------------------
# Use a named vector as a translation table to avoid modifying the 3D array in
# the loop
#labels <- as.character(unique(as.vector(segmentation[segmentation != 0])))
#label_map <- setNames(labels, labels)
#for (i in 1:nrow(adj_pairs)) {
#  l1 <- as.character(adj_pairs[i,1])
#  l2 <- as.character(adj_pairs[i,2])
#  s1_idx <- which(stats$id==l1)
#  s2_idx <- which(stats$id==l2)
#  if (length(s1_idx)==0 || length(s2_idx)==0) { next }
#  ovl <- calc_overlap(stats$m[s1_idx], stats$s[s1_idx], stats$m[s2_idx], stats$s[s2_idx])
#  if (ovl > overlap.threshold) {
#    label_map[label_map==l2] <- label_map[l1]
#    print(sprintf("Merging %s into %s (OVL: %f): %f done", l2, l1, ovl, i/nrow(adj_pairs)))
#  }
#}

# RENUMBER labels --------------------------------------------------------------
# 1. Apply the merge map to the entire volume
# 2. Identify voxels that are NOT background (0)
# 3. Initialize a result vector with 0s of the same length
# 4. Sequentially renumber ONLY the non-background voxels
# factor() identifies unique values; as.integer() assigns them 1, 2, 3...
# 5. Restore the 3D array structure with the new values
print("MSG [TKNI:clusterPDFmerge.R] >>>renumber labels 1..N")
mapped_labels <- label_map[as.character(segmentation)]
non_bg_idx <- (mapped_labels != "0") & !(is.na(mapped_labels))
renumbered_vector <- rep(0, length(mapped_labels))
renumbered_vector[non_bg_idx] <- as.integer(factor(mapped_labels[non_bg_idx]))
segmentation[] <- renumbered_vector

# SAVE result ------------------------------------------------------------------
#segmentation[] <- label_map[as.character(segmentation)]
#segmentation[segmentation!=0] <- rank(segmentation[segmentation!=0], ties.method=random)
print("MSG [TKNI:clusterPDFmerge.R] >>>saving output")
dir.create(dir.save, showWarnings=F, recursive=T)
init.nii(sprintf("%s/%s", dir.save, nii.save), dims=img.dims, pixdim=pixdim, orient=orient)
write.nii.volume(sprintf("%s/%s", dir.save, nii.save), 1, segmentation)

print("MSG [TKNI:clusterPDFmerge.R] >>>cleaning workspace")
rm(list=ls())
gc()
