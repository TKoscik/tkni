#!/bin/bash

# Setup information, might work as a script but my need lots of editing
# sudo privileges are a must
# -probably should not run as a cript, rather walk through the code to fix
#   idiosyncracies and reload  the terminal as needed.
# Requires Ubuntu 22.04.5 (no release for freesurfer for Ubuntu 24)

# will install:
## tkni
## R (v4.4)
## AFNI
## ANTs
## niimath
## mrtrix3
## FreeSurfer
## itksnap/c3d
## cuda
## nnUNet

# Prerequisite copy of setup files into folder ---------------------------------
## copy all to ~/Downloads/tkni_setup_tmp
## software zip/deb/files
##   ants-2.6.3-ubuntu-22.04-X64-gcc.zip
##   freesurfer_ubuntu22-8.1.0_amd64.deb
##   itksnap-4.4.0-20250909-Linux-x86_64.tar.gz
##   niimath_lnx_1.0.20250804.zip
## additional [semi-optional] zip files
##   tkni_atlas.zip
##   tkni_private.zip
## additional optional scripts

# Clone TKNI Github repository -------------------------------------------------
sudo mkdir -p /usr/local/tkni/dev
git clone https://github.com/tkoscik/tkni.git /usr/local/tkni/dev
sudo chmod -R 775 /usr/local/tkni

# Add TKNI to bashrc -----------------------------------------------------------
sudo mkdir -p /usr/local/tkni/log
echo -e "\n# TKNI ------" >> ~/.bashrc
echo "export TKNIPATH=/usr/local/tkni/dev" >> ~/.bashrc
echo "export TKNI_LOG=/usr/local/tkni/log" >> ~/.bashrc
echo "export TKNI_TEMPLATE=/usr/local/atlas/adult" >> ~/.bashrc
echo "export TKNI_SCRATCH=/scratch" >> ~/.bashrc
echo "export TKNI_LUT=${TKNIPATH}/lut" >> ~/.bashrc
echo 'export PATH=${PATH}:${TKNIPATH}/anat' >> ~/.bashrc
echo 'export PATH=${PATH}:${TKNIPATH}/dicom' >> ~/.bashrc
echo 'export PATH=${PATH}:${TKNIPATH}/dwi' >> ~/.bashrc
echo 'export PATH=${PATH}:${TKNIPATH}/export' >> ~/.bashrc
echo 'export PATH=${PATH}:${TKNIPATH}/func' >> ~/.bashrc
echo 'export PATH=${PATH}:${TKNIPATH}/generic' >> ~/.bashrc
echo 'export PATH=${PATH}:${TKNIPATH}/log' >> ~/.bashrc
echo 'export PATH=${PATH}:${TKNIPATH}/model' >> ~/.bashrc
echo 'export PATH=${PATH}:${TKNIPATH}/pipelines' >> ~/.bashrc
echo 'export PATH=${PATH}:${TKNIPATH}/qc' >> ~/.bashrc
echo 'export PATH=${PATH}:${TKNIPATH}/R' >> ~/.bashrc

# locate supporting software -----------------------------------------------
## note for niimath version number was appended manually and will need to be added to the folder structure
DIR_SRC="/home/${USER}/Downloads/tkni_setup_tmp"
SRC_ANTS="${DIR_SRC}/ants-2.6.3-ubuntu-22.04-X64-gcc.zip"
SRC_NIIMATH="${DIR_SRC}/niimath_lnx_1.0.20250804.zip"
SRC_ITKSNAP="${DIR_SRC}/itksnap-4.4.0-20250909-Linux-x86_64.tar.gz"
SRC_FREESURFER="${DIR_SRC}/freesurfer_ubuntu22-8.1.0_amd64.deb"
SRC_TKNIATLAS="${DIR_SRC}/tkni_atlas.zip"
SRC_TKNIPRIVATE="${DIR_SRC}/tkni_private.zip"
SRC_TKNINNUNET=("${DIR_SRC}/tkni_nnunet_uhrbex.zip")

## add atlases
sudo mkdir -p /usr/local/tkni/atlas
sudo chmod 775 /usr/local/tkni/atlas
unzip ${SRC_TKNIATLAS} -d /usr/local/tkni/

# add private if available
if [[ -n ${SRC_TKNIPRIVATE} ]] & [[ -f ${SRC_TKNIPRIVATE} ]]; then
  sudo mkdir -p /usr/local/tkni/private
  sudo unzip ${SRC_TKNIPRIVATE} -d /usr/local/tkni/
  echo 'export PATH=${PATH}:/usr/local/tkni/private' >> ~/.bashrc
fi

# install R -----------------------------------------------------------------
## https://cran.r-project.org/bin/linux/ubuntu/fullREADME.html
sudo apt-key adv --keyserver keyserver.ubuntu.com \
  --recv-keys E298A3A825C0D65DFD57CBB651716619E084DAB9
sudo add-apt-repository 'deb https://cloud.r-project.org/bin/linux/ubuntu jammy-cran40/'
sudo apt update
sudo apt install r-base r-base-dev
sudo apt install r-cran-car \
                 r-cran-data.table \
                 r-cran-devtools \
                 r-cran-doparallel \
                 r-cran-effects \
                 r-cran-fastcluster \
                 r-cran-ggplot2 \
                 r-cran-gridextra \
                 r-cran-hmisc \
                 r-cran-jsonlite \
                 r-cran-lme4 \
                 r-cran-lmertest \
                 r-cran-mass \
                 r-cran-mixtools \
                 r-cran-R.utils \
                 r-cran-reshape2 \
                 r-cran-viridis \
                 r-cran-withr
Rscript -e 'install.packages("ez.combat")' \
        -e 'install.packages("kableExtra")' \
        -e 'install.packages("moments")' \
        -e 'install.packages("nifti.io")' \
        -e 'install.packages("spant")' \
        -e 'install.packages("tools")' \
        -e 'devtools::install_github("tkoscik/fsurfR")' \
        -e 'devtools::install_github("tkoscik/tkmisc")'

# install AFNI ---------------------------------------------------------------
sudo apt install curl
cd
curl -O https://raw.githubusercontent.com/afni/afni/master/src/other_builds/OS_notes.linux_ubuntu_22_64_a_admin.txt
curl -O https://raw.githubusercontent.com/afni/afni/master/src/other_builds/OS_notes.linux_ubuntu_22_64_b_user.tcsh
curl -O https://raw.githubusercontent.com/afni/afni/master/src/other_builds/OS_notes.linux_ubuntu_22_64_c_nice.tcsh
## A installs required libraries
sudo bash OS_notes.linux_ubuntu_22_64_a_admin.txt 2>&1 | tee o.ubuntu_22_a.txt
## B installs AFNI
tcsh OS_notes.linux_ubuntu_22_64_b_user.tcsh 2>&1 | tee o.ubuntu_22_b.txt
## C prettifies the console
tcsh OS_notes.linux_ubuntu_22_64_c_nice.tcsh 2>&1 | tee o.ubuntu_22_c.txt

## RESTART TERMINAL ######
## check setup
afni_system_check.py -check_all
## R will likely need some tweaks
echo 'export AFNIDIR=/home/${USER}/abin' >> ~/.bashrc

# install ANTs ---------------------------------------------------------------------
sudo mkdir -p /usr/local/ants
cd /usr/local/ants
sudo mv ${SRC_ANTS} ./
sudo unzip $(basename ${SRC_ANTS})
## add bashrc entries
echo -e "\n# ANTS ------" >> ~/.bashrc
echo "export ANTSPATH=/usr/local/ants/ants-2.6.3/bin" >> ~/.bashrc
echo 'export PATH=$PATH:${ANTSPATH}' >> ~/.bashrc

## install NIIMATH -------------------------------------------------------------
sudo mkdir -p /usr/local/niimath/niimath-1.0.20250804
cd /usr/local/niimath
sudo mv ${SRC_NIIMATH} ./
sudo unzip $(basename ${SRC_NIIMATH}) -d /usr/local/niimath/niimath-1.0.20250804/
echo -e "\n# NIIMATH ------" >> ~/.bashrc
echo 'export PATH=$PATH:/usr/local/niimath/niimath-1.0.20250804' >> ~/.bashrc

## install ITKSNAP -------------------------------------------------------------
sudo mkdir -p /usr/local/itksnap
cd /usr/local/itksnap
sudo mv ${SRC_ITKSNAP} ./
sudo tar -xzvf $(basename ${SRC_ITKSNAP})
echo -e "\n# ITKSNAP & C3D ------" >> ~/.bashrc
echo 'export PATH=$PATH:/usr/local/itksnap/itksnap-4.4.0-20250909-Linux-x86_64/bin' >> ~/.bashrc

## build MRTRIX3 ---------------------------------------------------------------
sudo apt install libeigen3-dev libqt5opengl5-dev libqt5svg5-dev
sudo mkdir -p /usr/local/mrtrix3
cd /usr/local
sudo git clone https://github.com/MRtrix3/mrtrix3.git
cd /usr/local/mrtrix3
sudo ./configure
sudo ./build
echo -e "\n# MRTRIX3 ------" >> ~/.bashrc
echo 'export MRTRIXPATH=/usr/local/mrtrix3/bin' >> ~/.bashrc
echo 'export PATH=$PATH:/usr/local/mrtrix3/bin' >> ~/.bashrc

## install freesurfer ----------------------------------------------------------
sudo mkdir -p /usr/local/freesurfer
sudo mv ${SRC_FREESURFER} /usr/local/freesurfer/
cd /usr/local/freesurfer
sudo apt install ./$(basename ${SRC_FREESURFER}) -y

echo -e "\n# FREESURFER ------" >> ~/.bashrc
echo 'export FREESURFER_HOME=/usr/local/freesurfer/8.1.0' >> ~/.bashrc
echo 'source $FREESURFER_HOME/SetUpFreeSurfer.sh' >> ~/.bashrc

## nnUNet ----------------------------------------------------------------------
## python3 should already be installed
sudo apt install python3-pip
## install PYTORCH - https://pytorch.org/get-started/locally/
#pip install torch==2.8.0
# this gets uninstalled in the latter step
cd /usr/local
sudo git clone https://github.com/MIC-DKFZ/nnUNet.git
sudo chmod -R 777 /usr/local/nnUNet
cd /usr/local/nnUNet
## the below installs torch 2.9 anyways so the 2.8 install per their recommendation may be moot
pip install -e .
#pip install --upgrade git+https://github.com/FabianIsensee/hiddenlayer.git

# required downgrade to make it work
pip install 'numpy<2'

## set environment variables:
mkdir -p /data/nnUNet_environment/nnUNet_raw
mkdir -p /data/nnUNet_environment/nnUNet_preprocessed
mkdir -p /data/nnUNet_environment/nnUNet_results
echo -e "\n# nnUNetv2 ------" >> ~/.bashrc
echo "export nnUNet_raw=/data/nnUNet_environment/nnUNet_raw" >> ~/.bashrc
echo "export nnUNet_preprocessed=/data/nnUNet_environment/nnUNet_preprocessed" >> ~/.bashrc
echo "export nnUNet_results=/data/nnUNet_environment/nnUNet_results" >> ~/.bashrc

#install pretrained models
mkdir -p /usr/local/tkni/nnUnet
for (( i=0; i<${#SRC_TKNINNUNET[@]}; i++ )); do
  unzip ${SRC_TKNINNUNET[${i}]} -d /usr/local/tkni/nnUNet/
done
