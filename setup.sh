# Setup information, might work as a script but my need lots of editing
# sudo privileges are a must

# Prerequisite clone tkni github repository
# sudo mkdir -p /usr/local/tkni/dev
# cd /usr/local/tkni
# git clone https://github.com/tkoscik/tkni.git /usr/local/tkni/dev
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
## nnUNet


# locate supporting software -----------------------------------------------
## note for niimath version number was appended manually and will need to be added to the folder structure
DIR_SRC="~/Downloads/tkni_setup"
SRC_ANTS="${DIR_SRC}/ants-2.6.3-ubuntu-22.04-X64-gcc.zip"
SRC_NIIMATH="${DIR_SRC}/niimath_lnx_1.0.20250804.zip"
SRC_ITKSNAP="${DIR_SRC}/itksnap-4.4.0-20250909-Linux-x86_64.tar.gz"
SRC_FREESURFER="${DIR_SRC}/freesurfer_ubuntu22-8.1.0_amd64.deb"
SRC_TKNIATLAS="${DIR_SRC}/tkni_atlas.zip"
SRC_TKNIPRIVATE="${DIR_SRC}/tkni_private.zip"
SRC_TKNINNUNET=(${DIR_SRC}/tkni_nnunet_uhrbex.zip)

# install tkni software first -----------------------------------------------
if [[ -z ${TKNIPATH} ]]; then
  echo "TKNI not found. Check it is downloaded and TKNIPATH exists in bashrc"
  error 1
fi

## add atlases
sudo mkdir -p /usr/local/tkni/atlas
unzip ${SRC_TKNIATLAS} -d /usr/local/tkni/atlas

# add private if available
if [[ -n ${SRC_TKNIPRIVATE} ]] & [[ -f ${SRC_TKNIPRIVATE} ]]; then
  sudo mkdir -p /usr/local/tkni/private
  unzip ${SRC_TKNIATLAS} -d /usr/local/tkni/private
fi
## add entries to bashrc

# install LIBRARIES ----------------------------------------------------------
#MRTRIX
sudo apt update
sduo apt upgrade
sudo apt install git g++ python libeigen3-dev zlib1g-dev \
                 libqt5opengl5-dev libqt5svg5-dev libgl1-mesa-dev \
                 libfftw3-dev libtiff5-dev libpng-dev

# install R -----------------------------------------------------------------
## https://cran.r-project.org/bin/linux/ubuntu/fullREADME.html
deb https://cloud.r-project.org/bin/linux/ubuntu jammy-cran40/
sudo apt-get update
sudo apt-get install r-base r-base-dev

Rscript ${TKNIPATH}/R/r_setup.R

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
## - probably a better idea to set this up without sudo, but with chmod since that mnight be making pip commands fail
## https://surfer.nmr.mgh.harvard.edu/fswiki/rel7downloads
## https://surfer.nmr.mgh.harvard.edu/fswiki/rel7downloads/rel8notes
#cd /usr/local/freesurfer/8.1.0/python/packages/ERC_bayesian_segmentation/
#wget https://ftp.nmr.mgh.harvard.edu/pub/dist/lcnpublic/dist/Histo_Atlas_Iglesias_2023/atlas_simplified.zip
#unzip atlas_simplified.zip


mkdir -p /usr/local/freesurfer
cp ${SRC_FREESURFER} /usr/local/freesurfer/
cd /usr/local/freesurfer
sudo apt install ./$(basename ${SRC_FREESURFER})

sudo FREESURFER_HOME=$FREESURFER_HOME $FREESURFER_HOME/bin/fs_install_mcr R2019b
export LD_LIBRARY_PATH=$FREESURFER_HOME/MCRv97/runtime/glnxa64:$FREESURFER_HOME/MCRv97/bin/glnxa64:$FREESURFER_HOME/MCRv97/sys/os/glnxa64:$FREESURFER_HOME/MCRv97/extern/bin/glnxa64
#sudo FREESURFER_HOME=$FREESURFER_HOME $FREESURFER_HOME/bin/fs_install_cuda
PYDIR=/usr/local/freesurfer/8.1.0/python/bin/python3.8
${PYDIR} -m pip install --timeout 1000 nvidia-curand-cu12==10.3.2.106
${PYDIR} -m pip install --timeout 1000 nvidia-cuda-runtime-cu12==12.1.105
${PYDIR} -m pip install --timeout 1000 triton==2.1.0
${PYDIR} -m pip install --timeout 1000 nvidia-cuda-cupti-cu12==12.1.105
${PYDIR} -m pip install --timeout 1000 nvidia-cusolver-cu12==11.4.5.107
${PYDIR} -m pip install --timeout 1000 typing-extensions>=4.8.0
${PYDIR} -m pip install --timeout 1000 nvidia-cuda-nvrtc-cu12==12.1.105
${PYDIR} -m pip install --timeout 1000 nvidia-cublas-cu12==12.1.3.1
${PYDIR} -m pip install --timeout 1000 nvidia-cudnn-cu12==8.9.2.26
${PYDIR} -m pip install --timeout 1000 nvidia_cusolver_cu12
${PYDIR} -m pip install --timeout 1000 nvidia_cusparse_cu12
${PYDIR} -m pip install --timeout 1000 torch==2.1.2

git clone https://github.com/rohitrango/fireants
cd /usr/local/fireants
pip install -e .
cd fused_ops
${PYDIR} setup.py build_ext && ${PYDIR} setup.py install
cd ..




## nnUNet ---------------------------------------------------------------------------
##instal PYTORCH - https://pytorch.org/get-started/locally/
sudo apt install python
sudo apt install python3-pip
## check pytorch install
##pip install nnunetv2
cd /usr/local
git clone https://github.com/MIC-DKFZ/nnUNet.git
cd nnUNet
pip install -e .
pip install --upgrade git+https://github.com/FabianIsensee/hiddenlayer.git

## set environment variables:
mkdir -p /data/nnUNet_environment
echo "export nnUNet_raw=/data/nnUNet_environment/nnUNet_raw" >> ~/.bashrc
echo "export nnUNet_preprocessed=/data/nnUNet_environment/nnUNet_preprocessed" >> ~/.bashrc
echo "export nnUNet_results=/data/nnUNet_environment/nnUNet_results" >> ~/.bashrc

#install pretrained models
mkdir -p /usr/local/tkni/nnUnet
for (( i=0; i<${#SRC_TKNINNUNET[@]}; i++ )); do
  unzip ${SRC_TKNINNUNET[${i}]} /usr/local/tkni/nnUNet/
done

# ADD UTILITIES FOR CIFS and SSH ------
sudo apt install cifs-utils
sudo apt install openssh-server
sudo apt install imagemagick
