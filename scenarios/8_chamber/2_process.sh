#!/bin/sh

# exit on error
set -e
# turn on command echoing
set -v

# The data should have already been generated by ./1_run.sh

../../build/chamber_process

# Now run ./3_plot.sh to plot the data
