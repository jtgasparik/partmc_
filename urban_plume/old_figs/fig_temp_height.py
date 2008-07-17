#!/usr/bin/env python
# Copyright (C) 2007, 2008 Matthew West
# Licensed under the GNU General Public License version 2 or (at your
# option) any later version. See the file COPYING for details.

import os, sys
import copy as module_copy
from Scientific.IO.NetCDF import *
from pyx import *
sys.path.append("../tool")
from pmc_data_nc import *
from pmc_pyx import *

env = ["H"]

data = pmc_var(NetCDFFile("out/urban_plume_with_coag_0001.nc"),
	       "env_state",
	       [])

#data.write_summary(sys.stdout)

data.scale_dim("time", 1.0/60)

temp_data = module_copy.deepcopy(data)
temp_data.reduce([select("env", "temp")])
rh_data = module_copy.deepcopy(data)
rh_data.reduce([select("env", "rel_humid")])
rh_data.scale(100.0)
height_data = module_copy.deepcopy(data)
height_data.reduce([select("env", "height")])

g = graph.graphxy(
    width = 10,
    height = 4,
    x = graph.axis.linear(min = 0.,
                          max = 1440,
			  title = "local standard time (hours:minutes)",
                          parter = graph.axis.parter.linear(tickdists
                                                            = [6 * 60, 3 * 60]),
                          texter = time_of_day(base_time = 6 * 60),
			  painter = grid_painter),
    y = graph.axis.linear(min = 285,
                          max = 300,
                          parter = graph.axis.parter.linear(tickdists
                                                            = [3, 1.5]),
                          title = "temperature (K)",
                          painter = grid_painter),
    y2 = graph.axis.linear(min = 50,
                           max = 100,
                           parter = graph.axis.parter.linear(tickdists
                                                             = [10, 5]),
                           title = "relative humidity (1)",
                          texter = graph.axis.texter.decimal(suffix = r"\%")),
    y4 = graph.axis.linear(min = 0,
                           max = 500,
                           parter = graph.axis.parter.linear(tickdists
                                                             = [100, 50]),
                           title = "mixing height (m)"))
#    key = graph.key.key(pos = "tr"))

g.plot(graph.data.points(temp_data.data_center_list(),
			   x = 1, y = 2,
                           title = "temperature"),
             styles = [graph.style.line(lineattrs = [color.grey.black, style.linewidth.Thick])])

g.plot(graph.data.points(rh_data.data_center_list(),
			   x = 1, y2 = 2,
                           title = "relative humidity"),
             styles = [graph.style.line(lineattrs = [color.grey.black,style.linewidth.Thick,style.linestyle.dashed])])

g.plot(graph.data.points(height_data.data_center_list(),
			   x = 1, y4 = 2,
                           title = "mixing height"),
             styles = [graph.style.line(lineattrs = [color.grey.black,style.linewidth.Thick,style.linestyle.dashdotted])])

g.text(5.2,1,"temperature",[text.halign.boxleft,text.valign.bottom,color.rgb(0,0,0)])
g.text(6.5,2.1,"mixing height",[text.halign.boxleft,text.valign.bottom,color.rgb(0,0,0)])
g.text(7.2,3.5,"relative humidity",[text.halign.boxleft,text.valign.bottom,color.rgb(0,0,0)])

g.writePDFfile("figs/temp_height.pdf")
print "figure height = %.1f cm" % unit.tocm(g.bbox().height())
print "figure width = %.1f cm" % unit.tocm(g.bbox().width())