#!/usr/bin/env python
# Copyright (C) 2007 Matthew West
# Licensed under the GNU General Public License version 2 or (at your
# option) any later version. See the file COPYING for details.

import os, sys
import copy as module_copy
sys.path.append("../tool")
from pmc_data import *
from pmc_pyx import *
sys.path.append(os.path.expanduser("~/.python"))
from pyx import *

gas_species = ["O3", "HNO3", "NO", "NO2"]

data_set = read_data_set(file_list("out/urban_plume_state", "gas.dat"),
			 [])

g = graph.graphxy(
    width = 10,
    x = graph.axis.linear(title = "time (hour)",
			  painter = grid_painter),
    y = graph.axis.linear(title = "gas concentration (ppb)",
			  painter = grid_painter),
    key = graph.key.key(pos = "tr"))

for i in range(len(gas_species)):
    data_slice = module_copy.deepcopy(data_set)
    data_slice.reduce([select("species", gas_species[i])])
    data_slice.scale_dim("time", 1.0/3600)
    g.plot(graph.data.list(data_slice.data_center_list(),
			   x = 1, y = 2,
			   title = tex_species(gas_species[i])),
	   styles = [graph.style.line(lineattrs = [color_list[i]])])

g.writePDFfile("out/gas.pdf")