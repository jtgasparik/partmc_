run_type mc                     # Monte Carlo run
output_name dust_salt_part1     # name of output files
n_loop 1                        # number of Monte Carlo loops
num_conc 1d9                    # particle concentration (#/m^3)
kernel sedi                     # coagulation kernel

t_max 800                       # total simulation time (s)
del_t 1                         # timestep (s)
t_output 100                    # output interval (0 disables) (s)
t_state 800                     # state output interval (0 disables) (s)
t_progress 1                    # progress printing interval (0 disables) (s)

n_spec 3                        # number of species
i_water 3                       # species number that is water
rho 2165 2650 1000              # density of species (kg/m^3)
nu 2 2 0                        # number of ions in solution of each species (1)
eps 1 0.5 0                     # solubility of species (1)
M_w 58.44d-3 60.08d-3 18d-3     # molecular weight of species (kg/mole)

n_temps 2                       # number of temperature set-points
temp_times 0 800                # times of temperature set-points (s)
temps 288 280                   # temperatures at temperature set-points (K)
RH 0.999                        # initial relative humidity (1)
pressure 1d5                    # initial pressure (Pa)
rho_a 1.25                      # initial air density (kg/m^3)

n_init_dist 2                   # number of initial distributions

# first distribution - salt particles
n_p 5000                        # number of particles
vol_frac 1 0 0                  # composition proportions of species
dist_type log_normal            # type of distribution
dist_mean_diam 0.266d-6         # mean diameter (m)
dist_std_dev 0.21               # standard deviation (m)

# second distribution - dust particles
n_p 5000                        # number of particles
vol_frac 0 1 0                  # composition proportions of species
dist_type log_normal            # type of distribution
dist_mean_diam 0.05d-6          # mean diameter (m)
dist_std_dev 0.6                # standard deviation (m)

n_bin 160                       # number of bins
v_min 1d-24                     # volume of smallest bin (m^3)
scal 3                          # scale factor (integer)

rand_init 17                    # random initialization (0 to 
do_coagulation yes              # whether to do coagulation (yes/no)
allow_double yes                # double when particle number is small (yes/no)
do_condensation yes             # whether to do condensation (yes/no)
do_restart no                   # whether to restart from stored state (yes/no)
restart_name XXXX.d             # filename to restart from
