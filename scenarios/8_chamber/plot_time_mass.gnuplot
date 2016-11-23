# run from inside gnuplot with:
# load "<filename>.gnuplot"
# or from the commandline with:
# gnuplot -persist <filename>.gnuplot

set title "chamber total number concentration"

set xlabel "time / min"
set ylabel "mass concentration / (ug/m^3)"

unset key

set xrange [0:350]
set yrange [0:45]

plot "out/chamber_tot_mass_conc.txt" using ($1/60):($2*1e9):($3*1e9) with errorbars
