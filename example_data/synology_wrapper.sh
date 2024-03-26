#!/usr/bin/env bash
# Make sure to add the task for initializing optware as a prerequisite!
# Add this wrapper as a "Triggered Task" -> "Custom Script" 
# /bin/bash ./wrapper.sh <exporterArguments>

# Add optware to PATH to ensure the correct smartctl version is found
export PATH=/opt/sbin:/opt/bin:$PATH
# Prevent error
# ERROR: ld.so: object 'openhook.so' from LD_PRELOAD cannot be preloaded (cannot open shared object file): ignored.
# when getting started from Task Planner
export LD_PRELOAD=
# Locate current script, we assume the exporter is sitting in the same folder
BASEDIR=$(dirname "$0")
# Run exporter, passing all arguments passed to the wrapper
$BASEDIR/graphite_smart_exporter.sh $@