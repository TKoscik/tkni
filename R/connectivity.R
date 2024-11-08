args <- commandArgs(trailingOnly = TRUE)

# example call:
#Rscript ${INC_R}/connectivity.R \
#  "ts" "full/file/name/for/time-series.csv" \
#  "long" "pearson" "mutual-information" "euclidean" "manahattan" \
#  "dirsave" "directory to save output" 

# other options might include wavelet coherence, earthmover's distance, cross-
# correlation, ARIMA, etc.

# load libraries ---------------------------------------------------------------
suppressMessages(suppressWarnings(library(reshape2)))
suppressMessages(suppressWarnings(library(tools)))

# default values ---------------------------------------------------------------
ts <- NULL
lut <- NULL
lut.col <- "label"
do.plot <- TRUE
dir.save <- NULL
var.ls <- character()

# debug
#args <- c("ts",
#          "C:/Users/MBBHResearch/Desktop/sub-105_ses-20190726_task-rest_run-1_dir-fwd_ts-HCPICBM+2mm+WBCXN.csv",
#          "long",
#          "plot_colors", "#0000af,#ffffff,#af0000",
#          "plot_limits", "-1,0,1",
#          "dir_save", "C:/Users/MBBHResearch/Desktop",
#          "corr", "ccf", "coh", "wavelet", "mi", "dist", "city", "dtw", "earth")

# parse arguments --------------------------------------------------------------
for (i in 1:length(args)) {
  if (args[i] %in% c("ts", "timeseries", "time-series")) { ts <- args[i+1] }
  if (args[i] %in% c("corr", "cor", "pearson", "pearsonCorrelation")) { var.ls <- c(var.ls, "pearsonCorrelation") }
  if (args[i] %in% c("z", "fisher", "fisherZ", "fisherz")) { var.ls <- c(var.ls, "fisherZ") }
  if (args[i] %in% c("entropy", "transfer-entropy", "transferentropy", "transferEntropy")) { var.ls <- c(var.ls, "transferEntropy") }
  if (args[i] %in% c("mi", "mutual-information", "mutualInformation")) { var.ls <- c(var.ls, "mutualInformation") }
  if (args[i] %in% c("dist", "euclid", "euclidean", "euclidean-distance")) { var.ls <- c(var.ls, "euclideanDistance") }
  if (args[i] %in% c("city", "cityblock", "cityblock", "manhattan", "city-block-distance", "manhattan distance", "manhattanDistance")) { var.ls <- c(var.ls, "manhattanDistance") }
  if (args[i] %in% c("dtw", "dynamic-time-warping", "warp", "warping", "dynamicTimeWarping")) { var.ls <- c(var.ls, "dynamicTimeWarping") }
  if (args[i] %in% c("lut", "lookup")) { lut <- args[i+1] }
  if (args[i] %in% c("lut_column", "lut_name", "label_column", "label_name")) { lut.col <- args[i+1]}
  if (args[i] %in% c("mx", "matrix")) { df.type <- "matrix" }
  if (args[i] %in% c("no_plot")) { do.plot <- FALSE }
  if (args[i] %in% c("dir_save", "save_dir", "dirsave", "savedir", "save")) { dir.save <- args[i+1] }
}

# input checks -----------------------------------------------------------------
if (is.null(ts)) {
  exit("ERROR [TKNI:connectivityMx.R] input time-series required")
}

# load Time-Series -------------------------------------------------------------
delims <- c("\t",",",";"," ","")
delim.chk <- TRUE
iter <- 0
while (delim.chk) {
  iter <- iter + 1
  df <- read.csv(ts, header=F, sep=delims[iter], as.is=TRUE)
  if (ncol(df) > 1) { delim.chk <- FALSE }
}

# label columns if lut provided ------------------------------------------------
if (!is.null(lut)) {
  delim.chk <- TRUE
  iter <- 0
  while (delim.chk) {
    iter <- iter + 1
    lut.df <- read.csv(lut, sep=delims[iter], as.is=TRUE)
    if (ncol(df) > 1) { delim.chk <- FALSE }
  }
  if (nrow(lut.df) != ncol(df)) {
    exit("ERROR [TKNI:connectivityMx.R] number of labels does not match number of time-series")
  }
  colnames(df) <- lut.df[ ,lut.col]
}
alabs <- matrix(rep(colnames(df), ncol(df)), ncol=ncol(df))
alabs <- alabs[upper.tri(alabs)]
blabs <- matrix(rep(colnames(df), ncol(df)), ncol=ncol(df), byrow = T)
blabs <- blabs[upper.tri(blabs)]

pid <- unlist(strsplit(unlist(strsplit(basename(ts), "_"))[1], "sub-"))[2]
sid <- unlist(strsplit(unlist(strsplit(basename(ts), "_"))[2], "ses-"))[2]
prefix <- file_path_sans_ext(basename(ts))
date_calc <- format(Sys.time(),"%Y-%m-%dT%H:%M:%S")
if (do.plot) {
  suppressMessages(suppressWarnings(library(ggplot2)))
  clr.bidir <- c("#00293f", "#00496d", "#006d9e", "#0093d3", "#4ab8ff", "#b6dbff",
                 "#ffffff", "#ffffff", 
                 "#ffc9d3", "#ff8da6", "#ff3878", "#cb0056", "#8c0039", "#52001e")
  clr.unidir <- c("#000000","#390034","#610048","#8c0055","#bc004f","#e32f00","#e37100","#ec9900","#f7be00","#fee300","#ffffff")
  clr.dist <- c("#ffffff","#64ff91","#00e29e","#00c1a0","#00a296","#008587","#006875","#004d62","#00344e","#001b3e","#000000")
}

# do PEARSON CORRELATION --------------------------------------------------------
if ("pearsonCorrelation" %in% var.ls) {
  print(">>>>>calculate PEARSON CORRELATION")
  tx <- cor(df)
  colnames(tx) <- rownames(tx) <- colnames(df)
  for (i in 1:nrow(tx)) { tx[i,i] <- NA }
  write.table(tx, file=paste0(dir.save, "/", prefix, "_pearsonR.csv"),
              sep=",", quote=F, row.names=T, col.names=T)
  if (do.plot) {
    tp <- melt(tx)
    tp$Var2 <- factor(tp$Var2, levels=rev(colnames(tx)))
    tplot <- ggplot(tp, aes(x=Var1, y=Var2, fill=value)) +
      theme_void() +
      coord_equal() +
      scale_fill_gradientn(colours=clr.bidir, limits=c(-1,1)) +
      geom_raster() +
      labs(title= "Pearson Correlation") +
      theme(legend.title=element_blank(),
            legend.position="right",
            plot.background = element_rect(color="transparent", fill="#FFFFFF"))
    if (!is.null(lut)) {
      tplot <- tplot +
        theme(axis.text.x=element_text(angle=90, hjust=0, vjust=0.5, size=6),
              axis.text.y=element_text(hjust=1, vjust=0.5, size=6))
    }
    ggsave(filename=paste0(dir.save, "/", prefix, "_pearsonR.png"),
           plot=tplot, device="png", width=4, height=4, units="in", dpi=340)
  }
}

# do FISHER R TO Z --------------------------------------------------------
if ("fisherZ" %in% var.ls) {
  print(">>>>>calculate FISHER Z")
  suppressMessages(suppressWarnings(library(DescTools)))
  tx <- fisherZ(cor(df))
  colnames(tx) <- rownames(tx) <- colnames(df)
  for (i in 1:nrow(tx)) { tx[i,i] <- NA }
  write.table(tx, file=paste0(dir.save, "/", prefix, "_fisherZ.csv"),
              sep=",", quote=F, row.names=T, col.names=T)
  if (do.plot) {
    tp <- melt(tx)
    tp$Var2 <- factor(tp$Var2, levels=rev(colnames(tx)))
    tplot <- ggplot(tp, aes(x=Var1, y=Var2, fill=value)) +
      theme_void() +
      coord_equal() +
      scale_fill_gradientn(colours=clr.bidir) +
      geom_raster() +
      labs(title= "Fisher Z") +
      theme(legend.title=element_blank(),
            legend.position="right",
            plot.background = element_rect(color="transparent", fill="#FFFFFF"))
    if (!is.null(lut)) {
      tplot <- tplot +
        theme(axis.text.x=element_text(angle=90, hjust=0, vjust=0.5, size=6),
              axis.text.y=element_text(hjust=1, vjust=0.5, size=6))
    }
    ggsave(filename=paste0(dir.save, "/", prefix, "_pearsonR.png"),
           plot=tplot, device="png", width=4, height=4, units="in", dpi=340)
  }
}

# do EFFECTIVE TRANSFER ENTROPY ================================================
if ("transferEntropy" %in% var.ls) {
  print(">>>>>calculate TRANSFER ENTROPY")
  suppressMessages(suppressWarnings(library(RTransferEntropy)))
  tx <- matrix(NA,nrow=ncol(df), ncol=ncol(df))
  for (i in 1:(ncol(df)-1)) {
    for (j in (i+1):ncol(df)) {
      tx[i,j] <- calc_ete(df[,i], df[,j])
      tx[j,i] <- calc_ete(df[,j], df[,i])
    }
  }
  colnames(tx) <- rownames(tx) <- colnames(df)
  write.table(tx, file=paste0(dir.save, "/", prefix, "_transferEntropy.csv"),
              sep=",", quote=F, row.names=T, col.names=T)
  if (do.plot) {
    tp <- melt(tx)
    tp$Var2 <- factor(tp$Var2, levels=rev(colnames(tx)))
    tplot <- ggplot(tp, aes(x=Var1, y=Var2, fill=value)) +
      theme_void() +
      coord_equal() +
      scale_fill_gradientn(colors=clr.unidir) +
      geom_raster() +
      labs(title= "Transfer Entropy") +
      theme(legend.title=element_blank(),
            legend.position="right",
            plot.background = element_rect(color="transparent", fill="#FFFFFF"))
    if (!is.null(lut)) {
      tplot <- tplot +
        theme(axis.text.x=element_text(angle=90, hjust=0, vjust=0.5, size=6),
              axis.text.y=element_text(hjust=1, vjust=0.5, size=6))
    }
    ggsave(filename=paste0(dir.save, "/", prefix, "_transferEntropy.png"),
           plot=tplot, device="png", width=4, height=4, units="in", dpi=340)
  }
}

# do MUTUAL INFORMATION ========================================================
if ("mutualInformation" %in% var.ls) {
  print(">>>>>calculate MUTUAL INFORMATION")
  suppressMessages(suppressWarnings(library(infotheo)))
  tx <- mutinformation(discretize(df))
  colnames(tx) <- rownames(tx) <- colnames(df)
  for (i in 1:nrow(tx)) { tx[i,i] <- NA }
  write.table(tx, file=paste0(dir.save, "/", prefix, "_mutualInformation.csv"),
              sep=",", quote=F, row.names=T, col.names=T)
  if (do.plot) {
    tp <- melt(tx)
    tp$Var2 <- factor(tp$Var2, levels=rev(colnames(tx)))
    tplot <- ggplot(tp, aes(x=Var1, y=Var2, fill=value)) +
      theme_void() +
      scale_fill_gradientn(colors=clr.unidir) +
      geom_raster() +
      labs(title= "Mutual Information") +
      theme(legend.title=element_blank(), 
            legend.position="right",
            plot.background = element_rect(color="transparent", fill="#FFFFFF"))
    if (!is.null(lut)) {
      tplot <- tplot +
        theme(axis.text.x=element_text(angle=90, hjust=0, vjust=0.5, size=6),
              axis.text.y=element_text(hjust=1, vjust=0.5, size=6))
    }
    ggsave(filename=paste0(dir.save, "/", prefix, "_mutualInformation.png"),
           plot=tplot, device="png", width=4, height=4, units="in", dpi=340)
  }
}

## make scaled dataset to scale distance between 0 and 1 -----------------------
if (any(c("euclideanDistance", "manhattanDistance") %in% var.ls)) {
  sf <- df
  for (i in 1:ncol(sf)) {
    sf[,i] <- (sf[,i] - min(sf[,i]))/(max(sf[,i]) - min(sf[,i]))
  }
}

# do EUCLIDEAN DISTANCE ========================================================
if ("euclideanDistance" %in% var.ls) {
  print(">>>>>calculate EUCLIDEAN DISTANCE")
  tx <- as.matrix(dist(t(sf), method="euclidean")) / sqrt(ncol(sf))
  colnames(tx) <- rownames(tx) <- colnames(df)
  for (i in 1:nrow(tx)) { tx[i,i] <- NA }
  write.table(tx, file=paste0(dir.save, "/", prefix, "_euclideanDistance.csv"),
                sep=",", quote=F, row.names=T, col.names=T)
  if (do.plot) {
    tp <- melt(tx)
    tp$Var2 <- factor(tp$Var2, levels=rev(colnames(tx)))
    tplot <- ggplot(tp, aes(x=Var1, y=Var2, fill=value)) +
      theme_void() +
      coord_equal() +
      scale_fill_gradientn(colors=clr.dist) +
      geom_raster() +
      labs(title= "Euclidean Distance (normalized)") +
      theme(legend.title=element_blank(),
            legend.position="right",
            plot.background = element_rect(color="transparent", fill="#FFFFFF"))
    if (!is.null(lut)) {
      tplot <- tplot +
        theme(axis.text.x=element_text(angle=90, hjust=0, vjust=0.5, size=6),
              axis.text.y=element_text(hjust=1, vjust=0.5, size=6))
    }
    ggsave(filename=paste0(dir.save, "/", prefix, "_euclideanDistance.png"),
           plot=tplot, device="png", width=4, height=4, units="in", dpi=340)
  }
}

# do CITY BLOCK DISTANCE =======================================================
if ("manhattanDistance" %in% var.ls) {
  print(">>>>>calculate MANHATTAN DISTANCE")
  tx <- as.matrix(dist(t(sf), method="manhattan", upper=T)) / ncol(sf)
  colnames(tx) <- rownames(tx) <- colnames(df)
  for (i in 1:nrow(tx)) { tx[i,i] <- NA }
  write.table(tx, file=paste0(dir.save, "/", prefix, "_manhattanDistance.csv"),
              sep=",", quote=F, row.names=T, col.names=T)
  if (do.plot) {
    tp <- melt(tx)
    tp$Var2 <- factor(tp$Var2, levels=rev(colnames(tx)))
    tplot <- ggplot(tp, aes(x=Var1, y=Var2, fill=value)) +
      theme_void() +
      coord_equal() +
      scale_fill_gradientn(colors=clr.dist) +
      geom_raster() +
      labs(title= "Manhattan Distance") +
      theme(legend.title=element_blank(),
            legend.position="right",
            plot.background = element_rect(color="transparent", fill="#FFFFFF"))
    if (!is.null(lut)) {
      tplot <- tplot +
        theme(axis.text.x=element_text(angle=90, hjust=0, vjust=0.5, size=6),
              axis.text.y=element_text(hjust=1, vjust=0.5, size=6))
    }
    ggsave(filename=paste0(dir.save, "/", prefix, "_manhattanDistance.png"),
           plot=tplot, device="png", width=4, height=4, units="in", dpi=340)
  }
}
# do DYNAMIC-TIME WARPING ======================================================
if ("dynamicTimeWarping" %in% var.ls) {
  print(">>>>>calculate DYNAMIC TIME-WARPING")
  suppressMessages(suppressWarnings(library(dtw)))
  tx <- matrix(as.numeric(NA), nrow=ncol(df), ncol=ncol(df))
  for (i in 1:(ncol(df)-1)) {
    for (j in (i+1):ncol(df)) {
      tx[i,j] <- dtw(df[,i], df[,j], window.type="sakoechiba", window.size = 2)$normalizedDistance
      tx[j,i] <- dtw(df[,j], df[,i], window.type="sakoechiba", window.size = 2)$normalizedDistance
    }
  }
  colnames(tx) <- rownames(tx) <- colnames(df)
  for (i in 1:nrow(tx)) { tx[i,i] <- NA }
  write.table(tx, file=paste0(dir.save, "/", prefix, "_dynamicTimeWarping.csv"),
              sep=",", quote=F, row.names=T, col.names=T)
  if (do.plot) {
    tp <- melt(tx)
    tp$Var2 <- factor(tp$Var2, levels=rev(colnames(tx)))
    tplot <- ggplot(tp, aes(x=Var1, y=Var2, fill=value)) +
      theme_void() +
      coord_equal() +
      scale_fill_gradientn(colors=clr.dist) +
      geom_raster() +
      labs(title= "Dynamic Time Warping") +
      theme(legend.title=element_blank(),
            legend.position="right",
            plot.background = element_rect(color="transparent", fill="#FFFFFF"))
    if (!is.null(lut)) {
      tplot <- tplot +
        theme(axis.text.x=element_text(angle=90, hjust=0, vjust=0.5, size=6),
              axis.text.y=element_text(hjust=1, vjust=0.5, size=6))
    }
    ggsave(filename=paste0(dir.save, "/", prefix, "_dynamicTimeWarping.png"),
           plot=tplot, device="png", width=4, height=4, units="in", dpi=340)
  }
}

