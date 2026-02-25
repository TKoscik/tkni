# python venv setup

mkdir -p /usr/local/tkni/pyvenv/clusteringVENV
cd /usr/local/tkni/pyvenv

python3 -m venv clusteringVENV

# Activate it
source /usr/local/tkni/pyvenv/clusteringVENV/bin/activate

# Install everything from the file
pip install --upgrade pip
pip install -r ${TKNIPATH}/python/requirements_clusteringVENV.txt
