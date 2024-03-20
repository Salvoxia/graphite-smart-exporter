# Add optware to PATH to ensure the correct smartctl version is found
export PATH=/opt/sbin:/opt/bin:$PATH
# Locate current script, we assume the exporter is sitting in the same folder
BASEDIR=$(dirname "$0")
# Run exporter, passing all arguments passed to the wrapper
bash $BASEDIR/graphite_smart_exporter.sh "$@"