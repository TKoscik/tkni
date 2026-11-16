# python venv setup

DIR_VENV=/app/ni/venv_share
mkdir -p ${DIR_VENV}/clusteringVENV
cd ${DIR_VENV}/clusteringVENV

python3 -m venv clusteringVENV

# Activate it
source ${DIR_VENV}/clusteringVENV/bin/activate

# Install everything from the file
pip install --upgrade pip
pip install -r ${TKNIPATH}/python/requirements_clusteringVENV.txt
