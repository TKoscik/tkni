rm(list=ls())
invisible(gc())

CRAN.pkgs <- c("car",
               "devtools",
               "doParallel",
               "downloadthis",
               "effects",
               "ez.combat",
               "fastcluster",
               "ggplot2",
               "grid",
               "gridExtra",
               "Hmisc",
               "jsonlite",
               "kableExtra",
               "lme4",
               "lmerTest",
               "MASS",
               "mixtools",
               "moments",
               "nifti.io",
               "optimParallel",
               "R.utils",
               "RcppColors",
               "reshape2",
               "spant",
               "tools",
               "viridis",
               "withr")
GITHUB.pkgs <- c("tkoscik/fsurfR",
                 "tkoscik/tkmisc",
                 "tkoscik/timbow")

# Setup a library including the appropriate R packages -------------------------
pkgs <- as.character(unique(as.data.frame(installed.packages())$Package))

# check and install missing packages from CRAN ---------------------------------
CRAN.chk <- which(!(CRAN.pkgs %in% pkgs))
if (length(CRAN.chk)>0) {
  #install.packages(pkgs=CRAN.pkgs[CRAN.chk], repos="http://cran.r-project.org", verbose=FALSE)
  install.packages(pkgs=CRAN.pkgs[CRAN.chk])
  print(CRAN.pkgs[CRAN.chk])
}

# check and install from github ------------------------------------------------
GITHUB.chk <- which(!(unlist(strsplit(GITHUB.pkgs, "[/]"))[seq(2, length(GITHUB.pkgs)*2, 2)] %in% pkgs))
for (i in 1:length(GITHUB.chk)) {
  library(devtools)
  library(withr)
  #with_libpaths(new=inc.r.path, install_github(GITHUB.pkgs[i], quiet=TRUE))
  install.packages(pkgs=CRAN.pkgs[CRAN.chk])
  print(GITHUB.pkgs[i])
}

