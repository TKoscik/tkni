# Setup information, might work as a script but my need lots of editing
# sudo privileges are a must

# Prerequisite clone tkni github repository
# cd /usr/local
# sudo mkdir -p tkni
# git clone https://github.com/tkoscik/tkni
# chmod -r 775 /usr/local/tkni


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

# locate supporting software -----------------------------------------------
## note for niimath version number was appended manually and will need to be added to the folder structure
DIR_SRC="~/Downloads/tkni_setup"
SRC_ANTS="${DIR_SRC}/ants-2.6.3-ubuntu-22.04-X64-gcc.zip"
SRC_NIIMATH="${DIR_SRC}/niimath_lnx_1.0.20250804.zip"
SRC_ITKSNAP="${DIR_SRC}/itksnap-4.4.0-20250909-Linux-x86_64.tar.gz"
SRC_FREESURFER="${DIR_SRC}/freesurfer_ubuntu22-8.1.0_amd64.deb"
SRC_TKNIATLAS="${DIR_SRC}/tkni_atlas.zip"
SRC_TKNIPRIVATE="${DIR_SRC}/tkni_private.zip"

# install tkni software first -----------------------------------------------


## add atlases
sudo mkdir -p /usr/local/tkni/atlas
unzip ${SRC_TKNIATLAS} -d /usr/local/tkni/atlas

# add private if available
if [[ -n ${SRC_TKNIPRIVATE} ]] & [[ -f ${SRC_TKNIPRIVATE} ]]; then
  sudo mkdir -p /usr/local/tkni/private
  unzip ${SRC_TKNIATLAS} -d /usr/local/tkni/private
fi

## add entries to bashrc

# install R -----------------------------------------------------------------
## https://cran.r-project.org/bin/linux/ubuntu/fullREADME.html
deb https://cloud.r-project.org/bin/linux/ubuntu jammy-cran40/
sudo apt-get update
sudo apt-get install r-base r-base-dev

Rscript ${TKNIPATH}/R/r_setup.R

# install LIBRARIES ----------------------------------------------------------

#MRTRIX
sudo apt-get install git g++ python libeigen3-dev zlib1g-dev \
                     libqt5opengl5-dev libqt5svg5-dev libgl1-mesa-dev \
                     libfftw3-dev libtiff5-dev libpng-dev

# Install NVIDIA Drivers and CUDA --------------------------------------------


# install AFNI ---------------------------------------------------------------
cd
curl -O https://raw.githubusercontent.com/afni/afni/master/src/other_builds/OS_notes.linux_ubuntu_22_64_a_admin.txt
curl -O https://raw.githubusercontent.com/afni/afni/master/src/other_builds/OS_notes.linux_ubuntu_22_64_b_user.tcsh
curl -O https://raw.githubusercontent.com/afni/afni/master/src/other_builds/OS_notes.linux_ubuntu_22_64_c_nice.tcsh
sudo bash OS_notes.linux_ubuntu_22_64_a_admin.txt 2>&1 | tee o.ubuntu_22_a.txt
tcsh OS_notes.linux_ubuntu_22_64_b_user.tcsh 2>&1 | tee o.ubuntu_22_b.txt
tcsh OS_notes.linux_ubuntu_22_64_c_nice.tcsh 2>&1 | tee o.ubuntu_22_c.txt
## check setup
afni_system_check.py -check_all
## R will likely need some tweaks


# install ANTs ---------------------------------------------------------------------
mkdir -p /usr/local/ants
cd /usr/local/ants
cp ${SRC_ANTS} ./
unzip $(basename ${SRC_ANTS})
## add bashrc entries
echo -e "\n # ANTS ------" >> ~/.bashrc
echo "ANTSPATH=/usr/local/ants/ants-2.6.3/bin" >> ~/.bashrc
echo "export PATH=$PATH:${ANTSPATH}" >> ~/.bashrc

## install NIIMATH ------------------------------------------------------------------
mkdir -p /usr/local/niimath/niimath-1.0.20250804
cd /usr/local/niimath
cp ${SRC_NIIMATH} ./
unzip $(basename ${SRC_NIIMATH})
mv /usr/local/niimath/niimath /usr/local/niimath/niimath-1.0.20250804/
## add bashrc entry
echo -e "\n # NIIMATH ------" >> ~/.bashrc
echo "export PATH=$PATH:/usr/local/niimath/niimath-1.0.20250804" >> ~/.bashrc

## install ITKSNAP -------------------------------------------------------------------
mkdir -p /usr/local/itksnap
cd /usr/local/itksnap
cp ${SRC_ITKSNAP} ./
unzip $(basename ${SRC_ITKSNAP})
## add bashrc entry
echo -e "\n # ITKSNAP & C3D ------" >> ~/.bashrc
echo "export PATH=$PATH:/usr/local/itksnap/itksnap/itksnap-4.4.0-20250909-Linux-x86_64/bin" >> ~/.bashrc

## install MRTRIX3 -------------------------------------------------------------------
mkdir -p /usr/local/mrtrix3
cd /usr/local
git clone https://github.com/MRtrix3/mrtrix3.git
cd /usr/local/mrtrix3
./configure
./build
## add to bashrc
### look into what this is adding make it consistent with others
./set_path

## install freesurfer ----------------------------------------------------------------
mkdir -p /usr/local/freesurfer/freesurfer-8.1.0
cp ${SRC_FREESURFER} /usr/local/freesurfer/
cd /usr/local/freesurfer
sudo apt install $(basename ${SRC_FREESURFER})

sudo apt install 
