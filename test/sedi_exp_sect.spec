run_type sect                   # sectional code
output_file out/sedi_exp_sect_summary.d # name of output file
kernel sedi                     # coagulation kernel

t_max 600                       # total simulation time (s)
del_t 1                         # timestep (s)
t_output 60                     # output interval (0 disables) (s)
t_progress 60                   # progress printing interval (0 disables) (s)

n_bin 220                       # number of bins
r_min 1e-8                      # minimum radius (m)
r_max 1e-2                      # maximum radius (m)

gas_data gas_data_simple.dat    # file containing gas data
aerosol_data aerosol_data_water.dat # file containing aerosol data
aerosol_init sedi_exp_init.dat  # initial aerosol distribution

temp_profile temp_constant_15C.dat # temperature profile file
rel_humidity 0.999              # initial relative humidity (1)
pressure 1e5                    # initial pressure (Pa)
air_density 1.25                # initial air density (kg/m^3)
latitude 40                     # latitude (degrees, -90 to 90)
longitude 0                     # longitude (degrees, -180 to 180)
altitude 0                      # altitude (m)
start_time 0                    # start time (s since 00:00 UTC)
start_day 1                     # start day of year (UTC)

gas_emissions gas_none.dat      # gas emissions file
gas_emission_rate 0             # gas emission rate (s^{-1})
gas_background gas_none.dat     # background gas concentrations file
gas_dilution_rate 0             # gas dilution rate with background (s^{-1})

aerosol_emissions aerosol_none.dat # aerosol emissions file
aerosol_emission_rate 0         # aerosol emission rate (s^{-1})
aerosol_background aerosol_none.dat # aerosol background file
aerosol_dilution_rate 0         # aerosol dilution rate with background (s^{-1})

do_coagulation yes              # whether to do coagulation (yes/no)