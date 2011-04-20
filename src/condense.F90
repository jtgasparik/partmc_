! Copyright (C) 2005-2011 Nicole Riemer and Matthew West
! Copyright (C) 2009 Joseph Ching
! Licensed under the GNU General Public License version 2 or (at your
! option) any later version. See the file COPYING for details.

!> \file
!> The pmc_condense module.

!> Water condensation onto aerosol particles.
!!
!! The model here assumes that the temperature \f$ T \f$ and pressure
!! \f$ p \f$ are prescribed as functions of time, while water content
!! per-particle and relative humidity are to be calculated by
!! integrating their rates of change.
!!
!! The state of the system is defined by the per-particle wet
!! diameters \f$ D_i \f$ and the relative humidity \f$ H \f$. The
!! state vector stores these in the order \f$ (D_1,\ldots,D_n,H)
!! \f$. The time-derivative of the state vector and the Jacobian
!! (derivative of the time-derivative with repsect to the state) all
!! conform to this ordering.
!!
!! The SUNDIALS ODE solver is used to compute the system evolution
!! using an implicit method. The system Jacobian is explicitly
!! inverveted as its structure is very simple.
!!
!! All equations used in this file are written in detail in the file
!! \c doc/condense.tex.
module pmc_condense

  use pmc_aero_state
  use pmc_bin_grid
  use pmc_env_data
  use pmc_env_state
  use pmc_aero_data
  use pmc_util
  use pmc_aero_particle
  use pmc_constants
#ifdef PMC_USE_SUNDIALS
  use iso_c_binding
#endif

  !> Whether to numerically test the Jacobian-solve function during
  !> execution (for debugging only).
  logical, parameter :: CONDENSE_DO_TEST_JAC_SOLVE = .false.
  !> Whether to print call-counts for helper routines during execution
  !> (for debugging only).
  logical, parameter :: CONDENSE_DO_TEST_COUNTS = .false.

  !> Result code indicating successful completion.
  integer, parameter :: PMC_CONDENSE_SOLVER_SUCCESS        = 0
  !> Result code indicating failure to allocate \c y vector.
  integer, parameter :: PMC_CONDENSE_SOLVER_INIT_Y         = 1
  !> Result code indicating failure to allocate \c abstol vector.
  integer, parameter :: PMC_CONDENSE_SOLVER_INIT_ABSTOL    = 2
  !> Result code indicating failure to create the solver.
  integer, parameter :: PMC_CONDENSE_SOLVER_INIT_CVODE_MEM = 3
  !> Result code indicating failure to initialize the solver.
  integer, parameter :: PMC_CONDENSE_SOLVER_INIT_CVODE     = 4
  !> Result code indicating failure to set tolerances.
  integer, parameter :: PMC_CONDENSE_SOLVER_SVTOL          = 5
  !> Result code indicating failure to set maximum steps.
  integer, parameter :: PMC_CONDENSE_SOLVER_SET_MAX_STEPS  = 6
  !> Result code indicating failure of the solver.
  integer, parameter :: PMC_CONDENSE_SOLVER_FAIL           = 7

  !> Internal-use structure for storing the inputs for the
  !> rate-calculation function.
  type condense_rates_inputs_t
     !> Temperature (K).
     real(kind=dp) :: T
     !> Rate of change of temperature (K s^{-1}).
     real(kind=dp) :: Tdot
     !> Relative humidity (1).
     real(kind=dp) :: H
     !> Pressure (Pa).
     real(kind=dp) :: p
     !> Computational volume (m^3).
     real(kind=dp) :: V_comp
     !> Particle diameter (m).
     real(kind=dp) :: D
     !> Particle dry diameter (m).
     real(kind=dp) :: D_dry
     !> Kappa parameter (1).
     real(kind=dp) :: kappa
  end type condense_rates_inputs_t

  !> Internal-use structure for storing the outputs from the
  !> rate-calculation function.
  type condense_rates_outputs_t
     !> Change rate of diameter (m s^{-1}).
     real(kind=dp) :: Ddot
     !> Change rate of relative humidity due to this particle (s^{-1}).
     real(kind=dp) :: Hdot_i
     !> Change rate of relative humidity due to environment changes (s^{-1}).
     real(kind=dp) :: Hdot_env
     !> Sensitivity of \c Ddot to input \c D (m s^{-1} m^{-1}).
     real(kind=dp) :: dDdot_dD
     !> Sensitivity of \c Ddot to input \c H (m s^{-1}).
     real(kind=dp) :: dDdot_dH
     !> Sensitivity of \c Hdot_i to input \c D (s^{-1} m^{-1}).
     real(kind=dp) :: dHdoti_dD
     !> Sensitivity of \c Hdot_i to input \c D (s^{-1}).
     real(kind=dp) :: dHdoti_dH
     !> Sensitivity of \c Hdot_env to input \c D (s^{-1} m^{-1}).
     real(kind=dp) :: dHdotenv_dD
     !> Sensitivity of \c Hdot_env to input \c D (s^{-1}).
     real(kind=dp) :: dHdotenv_dH
  end type condense_rates_outputs_t

  !> Internal-use variable for storing the aerosol data during calls
  !> to the ODE solver.
  type(aero_data_t) :: condense_saved_aero_data
  !> Internal-use variable for storing the environment data during
  !> calls to the ODE solver.
  type(env_data_t) :: condense_saved_env_data
  !> Internal-use variable for storing the initial environment state
  !> during calls to the ODE solver.
  type(env_state_t) :: condense_saved_env_state_initial
  !> Internal-use variable for storing the inital computational volume
  !> during calls to the ODE solver.
  real(kind=dp) :: condense_saved_V_comp_initial
  !> Internal-use variable for storing the rate of change of the
  !> temperature during calls to the ODE solver.
  real(kind=dp) :: condense_saved_Tdot
  !> Internal-use variable for storing the per-particle kappa values
  !> during calls to the ODE solver.
  real(kind=dp), allocatable :: condense_saved_kappa(:)
  !> Internal-use variable for storing the per-particle dry diameters
  !> during calls to the ODE solver.
  real(kind=dp), allocatable :: condense_saved_D_dry(:)
  !> Internal-use variable for storing the per-particle weights during
  !> calls to the ODE solver.
  real(kind=dp), allocatable :: condense_saved_weight(:)

  !> Internal-use variable for counting calls to the vector field
  !> subroutine.
  integer, save :: condense_count_vf
  !> Internal-use variable for counting calls to the Jacobian-solving
  !> subroutine.
  integer, save :: condense_count_solve

contains
  
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

  !> Do condensation to all the particles for a given time interval,
  !> including updating the environment to account for the lost
  !> water vapor.
  subroutine condense_particles(bin_grid, env_state, env_data, &
       aero_data, aero_weight, aero_state, del_t)

    !> Bin grid.
    type(bin_grid_t), intent(in) :: bin_grid
    !> Environment state.
    type(env_state_t), intent(inout) :: env_state
    !> Environment data.
    type(env_data_t), intent(in) :: env_data
    !> Aerosol data.
    type(aero_data_t), intent(in) :: aero_data
    !> Aerosol weight.
    type(aero_weight_t), intent(in) :: aero_weight
    !> Aerosol state.
    type(aero_state_t), intent(inout) :: aero_state
    !> Total time to integrate.
    real(kind=dp), intent(in) :: del_t
    
    integer :: i_bin, i_part, n_eqn, i_eqn
    type(aero_particle_t), pointer :: aero_particle
    real(kind=dp) :: state(aero_state%n_part + 1), init_time, final_time
    real(kind=dp) :: abs_tol_vector(aero_state%n_part + 1)
    real(kind=dp) :: weight, old_weight, new_weight
    type(env_state_t) :: env_state_final
    real(kind=dp) :: water_vol_initial, water_vol_final, d_water_vol
    real(kind=dp) :: vapor_vol_initial, vapor_vol_final, d_vapor_vol
    real(kind=dp) :: V_comp_final, water_rel_error
#ifdef PMC_USE_SUNDIALS
    real(kind=c_double), target :: state_f(aero_state%n_part + 1)
    real(kind=c_double), target :: abstol_f(aero_state%n_part + 1)
    type(c_ptr) :: state_f_p, abstol_f_p
    integer(kind=c_int) :: n_eqn_f, solver_stat
    real(kind=c_double) :: reltol_f, t_initial_f, t_final_f
#endif
    type(aero_particle_t) :: new_aero_particle
    type(aero_info_t) :: aero_info
    integer :: n_copies, i_dup

#ifdef PMC_USE_SUNDIALS
#ifndef DOXYGEN_SKIP_DOC
    interface
       integer(kind=c_int) function condense_solver(neq, x_f, abstol_f, &
            reltol_f, t_initial_f, t_final_f) bind(c)
         use iso_c_binding
         integer(kind=c_int), value :: neq
         type(c_ptr), value :: x_f
         type(c_ptr), value :: abstol_f
         real(kind=c_double), value :: reltol_f
         real(kind=c_double), value :: t_initial_f
         real(kind=c_double), value :: t_final_f
       end function condense_solver
    end interface
#endif
#endif

    ! initial water volume in the aerosol particles in volume V_comp
    water_vol_initial = 0d0
    do i_bin = 1,bin_grid%n_bin
       do i_part = 1,aero_state%bin(i_bin)%n_part
          aero_particle => aero_state%bin(i_bin)%particle(i_part)
          weight = aero_weight_value(aero_weight, &
               aero_particle_radius(aero_particle))
          water_vol_initial = water_vol_initial &
               + aero_particle%vol(aero_data%i_water) * weight
       end do
    end do

    ! save data for use within the timestepper
    call aero_data_allocate(condense_saved_aero_data)
    call env_data_allocate(condense_saved_env_data)
    call env_state_allocate(condense_saved_env_state_initial)

    call aero_data_copy(aero_data, condense_saved_aero_data)
    call env_data_copy(env_data, condense_saved_env_data)
    call env_state_copy(env_state, condense_saved_env_state_initial)

    condense_saved_V_comp_initial = aero_state%comp_vol
    
    call env_state_allocate(env_state_final)
    call env_state_copy(env_state, env_state_final)
    call env_data_update_state(env_data, env_state_final, &
         env_state_final%elapsed_time + del_t, update_rel_humid = .false.)
    condense_saved_Tdot = (env_state_final%temp - env_state%temp) / del_t

    ! construct initial state vector from aero_state and env_state
    allocate(condense_saved_kappa(aero_state%n_part))
    allocate(condense_saved_D_dry(aero_state%n_part))
    allocate(condense_saved_weight(aero_state%n_part))
    i_eqn = 0
    do i_bin = 1,bin_grid%n_bin
       ! work backwards for consistency with the later weight
       ! adjustment, which has specific ordering requirements
       do i_part = aero_state%bin(i_bin)%n_part,1,-1
          i_eqn = i_eqn + 1
          aero_particle => aero_state%bin(i_bin)%particle(i_part)
          condense_saved_kappa(i_eqn) &
               = aero_particle_solute_kappa(aero_particle, aero_data)
          condense_saved_D_dry(i_eqn) = vol2diam(&
               aero_particle_solute_volume(aero_particle, aero_data))
          condense_saved_weight(i_eqn) = aero_weight_value(aero_weight, &
               aero_particle_radius(aero_particle))
          state(i_eqn) = aero_particle_diameter(aero_particle)
          abs_tol_vector(i_eqn) = max(1d-30, &
                1d-8 * (state(i_eqn) - condense_saved_D_dry(i_eqn)))
       end do
    end do
    state(aero_state%n_part + 1) = env_state%rel_humid
    abs_tol_vector(aero_state%n_part + 1) = 1d-10

#ifdef PMC_USE_SUNDIALS
    ! call SUNDIALS solver
    n_eqn = aero_state%n_part + 1
    n_eqn_f = int(n_eqn, kind=c_int)
    reltol_f = real(1d-8, kind=c_double)
    t_initial_f = real(0, kind=c_double)
    t_final_f = real(del_t, kind=c_double)
    do i_eqn = 1,n_eqn
       state_f(i_eqn) = real(state(i_eqn), kind=c_double)
       abstol_f(i_eqn) = real(abs_tol_vector(i_eqn), kind=c_double)
    end do
    state_f_p = c_loc(state_f)
    abstol_f_p = c_loc(abstol_f)
    condense_count_vf = 0
    condense_count_solve = 0
    solver_stat = condense_solver(n_eqn_f, state_f_p, abstol_f_p, reltol_f, &
         t_initial_f, t_final_f)
    call condense_check_solve(solver_stat)
    if (CONDENSE_DO_TEST_COUNTS) then
       write(0,*) 'condense_count_vf ', condense_count_vf
       write(0,*) 'condense_count_solve ', condense_count_solve
    end if
    do i_eqn = 1,n_eqn
       state(i_eqn) = real(state_f(i_eqn), kind=dp)
    end do
#endif

    ! unpack result state vector into env_state
    env_state%rel_humid = state(aero_state%n_part + 1)

    ! unpack result state vector into aero_state, compute the final
    ! water volume in the aerosol particles in volume V_comp, and
    ! adjust particle number to account for weight changes
    call aero_particle_allocate(new_aero_particle)
    call aero_info_allocate(aero_info)
    water_vol_final = 0d0
    i_eqn = 0
    do i_bin = 1,bin_grid%n_bin
       ! work backwards so any additions and removals will only affect
       ! particles that we've already dealt with
       do i_part = aero_state%bin(i_bin)%n_part,1,-1
          i_eqn = i_eqn + 1
          aero_particle => aero_state%bin(i_bin)%particle(i_part)
          old_weight = aero_weight_value(aero_weight, &
               aero_particle_radius(aero_particle))

          ! translate output back to particle
          aero_particle%vol(aero_data%i_water) = diam2vol(state(i_eqn)) &
               - aero_particle_solute_volume(aero_particle, aero_data)

          ! ensure volumes stay positive
          aero_particle%vol(aero_data%i_water) = max(0d0, &
               aero_particle%vol(aero_data%i_water))

          ! add up total water volume, using old weights
          water_vol_final = water_vol_final &
               + aero_particle%vol(aero_data%i_water) * old_weight

          ! adjust particle number to account for weight changes
          if (aero_weight%type /= AERO_WEIGHT_TYPE_NONE) then
             new_weight = aero_weight_value(aero_weight, &
                  aero_particle_radius(aero_particle))
             n_copies = prob_round(old_weight / new_weight)
             if (n_copies == 0) then
                aero_info%id = aero_particle%id
                aero_info%action = AERO_INFO_WEIGHT
                aero_info%other_id = 0
                call aero_state_remove_particle_with_info(aero_state, &
                     i_bin, i_part, aero_info)
             elseif (n_copies > 1) then
                do i_dup = 1,(n_copies - 1)
                   call aero_particle_copy(aero_particle, new_aero_particle)
                   call aero_particle_new_id(new_aero_particle)
                   ! this might be adding into the wrong bin, but
                   ! that's necessary as we might not have processed
                   ! the correct bin yet.
                   call aero_state_add_particle(aero_state, i_bin, &
                        new_aero_particle)
                   ! re-get the particle pointer, which may have
                   ! changed due to reallocations caused by adding
                   aero_particle => aero_state%bin(i_bin)%particle(i_part)
                end do
             end if
          end if
       end do
    end do
    ! We've modified particle diameters, so we need to update which
    ! bins they are in.
    call aero_state_resort(bin_grid, aero_state)
    call aero_particle_deallocate(new_aero_particle)
    call aero_info_deallocate(aero_info)
    
    ! Check that water removed from particles equals water added to
    ! vapor. Note that water concentration is not conserved (due to
    ! V_comp changes), and we need to consider particle weightings
    ! correctly.
    V_comp_final = condense_saved_V_comp_initial &
         * env_state_final%temp / condense_saved_env_state_initial%temp
    vapor_vol_initial = aero_data%molec_weight(aero_data%i_water) &
         / (const%univ_gas_const * condense_saved_env_state_initial%temp) &
         * env_state_sat_vapor_pressure(condense_saved_env_state_initial) &
         * condense_saved_env_state_initial%rel_humid &
         * condense_saved_V_comp_initial &
         / aero_particle_water_density(aero_data)
    vapor_vol_final = aero_data%molec_weight(aero_data%i_water) &
         / (const%univ_gas_const * env_state_final%temp) &
         * env_state_sat_vapor_pressure(env_state_final) &
         * env_state%rel_humid &
         * V_comp_final / aero_particle_water_density(aero_data)
    d_vapor_vol = vapor_vol_final - vapor_vol_initial
    d_water_vol = water_vol_final - water_vol_initial
    water_rel_error = (d_vapor_vol + d_water_vol) &
         / (vapor_vol_final + water_vol_final)
    call warn_assert_msg(477865387, abs(water_rel_error) < 1d-6, &
         "condensation water imbalance too high: " &
         // trim(real_to_string(water_rel_error)))

    deallocate(condense_saved_kappa)
    deallocate(condense_saved_D_dry)
    deallocate(condense_saved_weight)
    call env_state_deallocate(env_state_final)
    call aero_data_deallocate(condense_saved_aero_data)
    call env_data_deallocate(condense_saved_env_data)
    call env_state_deallocate(condense_saved_env_state_initial)

  end subroutine condense_particles

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

#ifdef PMC_USE_SUNDIALS
  !> Check the return code from the condense_solver() function.
  subroutine condense_check_solve(value)

    !> Return code to check.
    integer(kind=c_int), intent(in) :: value

    if (value == PMC_CONDENSE_SOLVER_SUCCESS) then
       return
    elseif (value == PMC_CONDENSE_SOLVER_INIT_Y) then
       call die_msg(123749472, "condense_solver: " &
            // "failed to allocate y vector")
    elseif (value == PMC_CONDENSE_SOLVER_INIT_ABSTOL) then
       call die_msg(563665949, "condense_solver: " &
            // "failed to allocate abstol vector")
    elseif (value == PMC_CONDENSE_SOLVER_INIT_CVODE_MEM) then
       call die_msg(700541443, "condense_solver: " &
            // "failed to create the solver")
    elseif (value == PMC_CONDENSE_SOLVER_INIT_CVODE) then
       call die_msg(297559183, "condense_solver: " &
            // "failure to initialize the solver")
    elseif (value == PMC_CONDENSE_SOLVER_SVTOL) then
       call die_msg(848342417, "condense_solver: " &
            // "failed to set tolerances")
    elseif (value == PMC_CONDENSE_SOLVER_SET_MAX_STEPS) then
       call die_msg(275591501, "condense_solver: " &
            // "failed to set maximum steps")
    elseif (value == PMC_CONDENSE_SOLVER_FAIL) then
       call die_msg(862254233, "condense_solver: solver failed")
    else
       call die_msg(635697577, "condense_solver: unknown return code: " &
            // trim(integer_to_string(value)))
    end if

  end subroutine condense_check_solve
#endif

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

  !> Fills in the \c env_state with the current environment state,
  !> taken from the \c state vector and from global variables.
  subroutine condense_current_env_state(n_eqn, time, state, env_state)

    !> Length of state vector.
    integer, intent(in) :: n_eqn
    !> Current time (s).
    real(kind=dp), intent(in) :: time
    !> Current state vector.
    real(kind=dp), intent(in) :: state(n_eqn)
    !> Current environment state.
    type(env_state_t), intent(inout) :: env_state

    call env_state_copy(condense_saved_env_state_initial, env_state)
    call env_data_update_state(condense_saved_env_data, &
         env_state, env_state%elapsed_time + time, &
         update_rel_humid = .false.)
    env_state%rel_humid = state(n_eqn)

  end subroutine condense_current_env_state

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

  !> Compute the rate of change of particle diameter and relative
  !> humidity for a single particle, together with the derivatives of
  !> the rates with respect to the input variables.
  subroutine condense_rates(inputs, outputs)

    !> Inputs to rates.
    type(condense_rates_inputs_t), intent(in) :: inputs
    !> Outputs rates.
    type(condense_rates_outputs_t), intent(out) :: outputs

    real(kind=dp) :: rho_w, M_w, P_0, dP0_dT_div_P0, rho_air, k_a, D_v, U
    real(kind=dp) :: V, W, X, Y, Z, k_ap, dkap_dD, D_vp, dDvp_dD
    real(kind=dp) :: a_w, daw_dD, delta_star, h, dh_ddelta, dh_dD
    real(kind=dp) :: dh_dH, ddeltastar_dD, ddeltastar_dH
    integer :: newton_step

    rho_w = const%water_density
    M_w = const%water_molec_weight
    P_0 = const%water_eq_vap_press &
         * 10d0**(7.45d0 * (inputs%T - const%water_freeze_temp) &
         / (inputs%T - 38d0))
    dP0_dT_div_P0 = 7.45d0 * log(10d0) * (const%water_freeze_temp - 38d0) &
         / (inputs%T - 38d0)**2
    rho_air = const%air_molec_weight * inputs%p &
         / (const%univ_gas_const * inputs%T)

    k_a = 1d-3 * (4.39d0 + 0.071d0 * inputs%T)
    D_v = 0.211d-4 / (inputs%p / const%air_std_press) &
         * (inputs%T / 273d0)**1.94d0
    U = const%water_latent_heat * rho_w / (4d0 * inputs%T)
    V = 4d0 * M_w * P_0 / (rho_w * const%univ_gas_const * inputs%T)
    W = const%water_latent_heat * M_w / (const%univ_gas_const * inputs%T)
    X = 4d0 * M_w * const%water_surf_eng &
         / (const%univ_gas_const * inputs%T * rho_w) 
    Y = 2d0 * k_a / (const%accom_coeff * rho_air &
         * const%air_spec_heat) &
         * sqrt(2d0 * const%pi * const%air_molec_weight &
         / (const%univ_gas_const * inputs%T))
    Z = 2d0 * D_v / const%accom_coeff * sqrt(2d0 * const%pi * M_w &
         / (const%univ_gas_const * inputs%T))

    outputs%Hdot_env = - dP0_dT_div_P0 * inputs%Tdot * inputs%H
    outputs%dHdotenv_dD = 0d0
    outputs%dHdotenv_dH = - dP0_dT_div_P0 * inputs%Tdot

    if (inputs%D <= inputs%D_dry) then
       k_ap = k_a / (1d0 + Y / inputs%D_dry)
       dkap_dD = 0d0
       D_vp = D_v / (1d0 + Z / inputs%D_dry)
       dDvp_dD = 0d0
       a_w = 0d0
       daw_dD = 0d0

       delta_star = U * V * D_vp * inputs%H / k_ap
       
       outputs%Ddot = k_ap * delta_star / (U * inputs%D_dry)
       outputs%Hdot_i = - 2d0 * const%pi / (V * inputs%V_comp) &
            * inputs%D_dry**2 * outputs%Ddot
       
       dh_ddelta = k_ap
       dh_dD = 0d0
       dh_dH = - U * V * D_vp

       ddeltastar_dD = - dh_dD / dh_ddelta
       ddeltastar_dH = - dh_dH / dh_ddelta
       
       outputs%dDdot_dD = 0d0
       outputs%dDdot_dH = k_ap / (U * inputs%D_dry) * ddeltastar_dH
       outputs%dHdoti_dD = - 2d0 * const%pi / (V * inputs%V_comp) &
            * inputs%D_dry**2 * outputs%dDdot_dD
       outputs%dHdoti_dH = - 2d0 * const%pi / (V * inputs%V_comp) &
            * inputs%D_dry**2 * outputs%dDdot_dH

       return
    end if

    k_ap = k_a / (1d0 + Y / inputs%D)
    dkap_dD = k_a * Y / (inputs%D + Y)**2
    D_vp = D_v / (1d0 + Z / inputs%D)
    dDvp_dD = D_v * Z / (inputs%D + Z)**2
    a_w = (inputs%D**3 - inputs%D_dry**3) &
         / (inputs%D**3 + (inputs%kappa - 1d0) * inputs%D_dry**3)
    daw_dD = 3d0 * inputs%D**2 * inputs%kappa * inputs%D_dry**3 &
         / (inputs%D**3 + (inputs%kappa - 1d0) * inputs%D_dry**3)**2

    delta_star = 0d0
    h = 0d0
    dh_ddelta = 1d0
    do newton_step = 1,5
       ! update delta_star first so when the newton loop ends we have
       ! h and dh_ddelta evaluated at the final delta_star value
       delta_star = delta_star - h / dh_ddelta
       h = k_ap * delta_star - U * V * D_vp &
            * (inputs%H - a_w / (1d0 + delta_star) &
            * exp(W * delta_star / (1d0 + delta_star) &
            + (X / inputs%D) / (1d0 + delta_star)))
       dh_ddelta = &
            k_ap - U * V * D_vp * a_w / (1d0 + delta_star)**2 &
            * (1d0 - W / (1d0 + delta_star) &
            + (X / inputs%D) / (1d0 + delta_star)) &
            * exp(W * delta_star / (1d0 + delta_star) &
            + (X / inputs%D) / (1d0 + delta_star))
    end do
    call warn_assert_msg(387362320, &
         abs(h) < 1d3 * epsilon(1d0) * abs(U * V * D_vp * inputs%H), &
         "condensation newton loop did not satisfy convergence tolerance")

    outputs%Ddot = k_ap * delta_star / (U * inputs%D)
    outputs%Hdot_i = - 2d0 * const%pi / (V * inputs%V_comp) &
         * inputs%D**2 * outputs%Ddot

    dh_dD = dkap_dD * delta_star &
         - U * V * dDvp_dD * inputs%H + U * V &
         * (a_w * dDvp_dD + D_vp * daw_dD &
         - D_vp * a_w * (X / inputs%D**2) / (1d0 + delta_star)) &
         * (1d0 / (1d0 + delta_star)) &
         * exp((W * delta_star) / (1d0 + delta_star) &
         + (X / inputs%D) / (1d0 + delta_star))
    dh_dH = - U * V * D_vp

    ddeltastar_dD = - dh_dD / dh_ddelta
    ddeltastar_dH = - dh_dH / dh_ddelta

    outputs%dDdot_dD = dkap_dD * delta_star / (U * inputs%D) &
         + k_ap * ddeltastar_dD / (U * inputs%D) &
         - k_ap * delta_star / (U * inputs%D**2)
    outputs%dDdot_dH = k_ap / (U * inputs%D) * ddeltastar_dH
    outputs%dHdoti_dD = - 2d0 * const%pi / (V * inputs%V_comp) &
         * (2d0 * inputs%D * outputs%Ddot + inputs%D**2 * outputs%dDdot_dD)
    outputs%dHdoti_dH = - 2d0 * const%pi / (V * inputs%V_comp) &
         * inputs%D**2 * outputs%dDdot_dH

  end subroutine condense_rates

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

#ifdef PMC_USE_SUNDIALS
  !> Compute the condensation rates (Ddot and Hdot) at the current
  !> value of the state (D and H).
  subroutine condense_vf_f(n_eqn, time, state_p, state_dot_p) bind(c)
    
    !> Length of state vector.
    integer(kind=c_int), value, intent(in) :: n_eqn
    !> Current time (s).
    real(kind=c_double), value, intent(in) :: time
    !> Pointer to state data.
    type(c_ptr), value, intent(in) :: state_p
    !> Pointer to state_dot data.
    type(c_ptr), value, intent(in) :: state_dot_p

    real(kind=c_double), pointer :: state(:)
    real(kind=c_double), pointer :: state_dot(:)
    real(kind=dp) :: Hdot
    integer :: i_part
    type(env_state_t) :: env_state
    type(condense_rates_inputs_t) :: inputs
    type(condense_rates_outputs_t) :: outputs

    condense_count_vf = condense_count_vf + 1

    call c_f_pointer(state_p, state, (/ n_eqn /))
    call c_f_pointer(state_dot_p, state_dot, (/ n_eqn /))
    
    call env_state_allocate(env_state)
    call condense_current_env_state(n_eqn, time, state, env_state)

    inputs%T = env_state%temp
    inputs%Tdot = condense_saved_Tdot
    inputs%H = env_state%rel_humid
    inputs%p = env_state%pressure
    
    Hdot = 0d0
    do i_part = 1,(n_eqn - 1)
       inputs%D = state(i_part)
       inputs%D_dry = condense_saved_D_dry(i_part)
       inputs%V_comp = condense_saved_V_comp_initial &
            * env_state%temp / condense_saved_env_state_initial%temp &
            / condense_saved_weight(i_part)
       inputs%kappa = condense_saved_kappa(i_part)
       call condense_rates(inputs, outputs)
       state_dot(i_part) = outputs%Ddot
       Hdot = Hdot + outputs%Hdot_i
    end do
    Hdot = Hdot + outputs%Hdot_env
    
    state_dot(n_eqn) = Hdot
    
    call env_state_deallocate(env_state)
    
  end subroutine condense_vf_f
#endif
  
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

#ifdef PMC_USE_SUNDIALS
  !> Compute the Jacobian given by the derivatives of the condensation
  !> rates (Ddot and Hdot) with respect to the input variables (D and
  !> H).
  subroutine condense_jac(n_eqn, time, state_p, dDdot_dD, dDdot_dH, &
       dHdot_dD, dHdot_dH)

    !> Length of state vector.
    integer(kind=c_int), intent(in) :: n_eqn
    !> Current time (s).
    real(kind=c_double), intent(in) :: time
    !> Pointer to current state vector.
    type(c_ptr), intent(in) :: state_p
    !> Derivative of Ddot with respect to D.
    real(kind=dp), intent(out) :: dDdot_dD(n_eqn - 1)
    !> Derivative of Ddot with respect to H.
    real(kind=dp), intent(out) :: dDdot_dH(n_eqn - 1)
    !> Derivative of Hdot with respect to D.
    real(kind=dp), intent(out) :: dHdot_dD(n_eqn - 1)
    !> Derivative of Hdot with respect to H.
    real(kind=dp), intent(out) :: dHdot_dH

    real(kind=c_double), pointer :: state(:)
    integer :: i_part
    type(env_state_t) :: env_state
    type(condense_rates_inputs_t) :: inputs
    type(condense_rates_outputs_t) :: outputs

    call c_f_pointer(state_p, state, (/ n_eqn /))

    call env_state_allocate(env_state)
    call condense_current_env_state(n_eqn, time, state, env_state)
    
    inputs%T = env_state%temp
    inputs%Tdot = condense_saved_Tdot
    inputs%H = env_state%rel_humid
    inputs%p = env_state%pressure
    
    dHdot_dH = 0d0
    do i_part = 1,(n_eqn - 1)
       inputs%D = state(i_part)
       inputs%D_dry = condense_saved_D_dry(i_part)
       inputs%V_comp = condense_saved_V_comp_initial &
            * env_state%temp / condense_saved_env_state_initial%temp &
            / condense_saved_weight(i_part)
       inputs%kappa = condense_saved_kappa(i_part)
       call condense_rates(inputs, outputs)
       dDdot_dD(i_part) = outputs%dDdot_dD
       dDdot_dH(i_part) = outputs%dDdot_dH
       dHdot_dD(i_part) = outputs%dHdoti_dD + outputs%dHdotenv_dD
       dHdot_dH = dHdot_dH + outputs%dHdoti_dH
    end do
    dHdot_dH = dHdot_dH + outputs%dHdotenv_dH
    
    call env_state_deallocate(env_state)
    
  end subroutine condense_jac
#endif

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

#ifdef PMC_USE_SUNDIALS
  !> Solve the system \f$ Pz = r \f$ where \f$ P = I - \gamma J \f$
  !> and \f$ J = \partial f / \partial y \f$. The solution is returned
  !> in the \f$ r \f$ vector.
  subroutine condense_jac_solve_f(n_eqn, time, state_p, state_dot_p, &
       rhs_p, gamma) bind(c)

    !> Length of state vector.
    integer(kind=c_int), value, intent(in) :: n_eqn
    !> Current time (s).
    real(kind=c_double), value, intent(in) :: time
    !> Pointer to current state vector.
    type(c_ptr), value, intent(in) :: state_p
    !> Pointer to current state derivative vector.
    type(c_ptr), value, intent(in) :: state_dot_p
    !> Pointer to right-hand-side vector.
    type(c_ptr), value, intent(in) :: rhs_p
    !> Value of \c gamma scalar parameter.
    real(kind=c_double), value, intent(in) :: gamma

    real(kind=c_double), pointer :: state(:), state_dot(:), rhs(:)
    real(kind=c_double) :: soln(n_eqn)
    real(kind=dp) :: dDdot_dD(n_eqn - 1), dDdot_dH(n_eqn - 1)
    real(kind=dp) :: dHdot_dD(n_eqn - 1), dHdot_dH
    real(kind=dp) :: lhs_n, rhs_n
    real(kind=c_double) :: residual(n_eqn)
    real(kind=dp) :: rhs_norm, soln_norm, residual_norm
    integer :: i_part

    condense_count_solve = condense_count_solve + 1

    call condense_jac(n_eqn, time, state_p, dDdot_dD, dDdot_dH, &
         dHdot_dD, dHdot_dH)

    call c_f_pointer(state_p, state, (/ n_eqn /))
    call c_f_pointer(state_dot_p, state_dot, (/ n_eqn /))
    call c_f_pointer(rhs_p, rhs, (/ n_eqn /))

    !FIXME: write this all in matrix-vector notation, no i_part looping
    lhs_n = 1d0 - gamma * dHdot_dH
    rhs_n = rhs(n_eqn)
    do i_part = 1,(n_eqn - 1)
       lhs_n = lhs_n - (- gamma * dDdot_dH(i_part)) &
            * (- gamma * dHdot_dD(i_part)) / (1d0 - gamma * dDdot_dD(i_part))
       rhs_n = rhs_n - (- gamma * dHdot_dD(i_part)) * rhs(i_part) &
            / (1d0 - gamma * dDdot_dD(i_part))
    end do
    soln(n_eqn) = rhs_n / lhs_n

    do i_part = 1,(n_eqn - 1)
       soln(i_part) = (rhs(i_part) &
            - (- gamma * dDdot_dH(i_part)) * soln(n_eqn)) &
            / (1d0 - gamma * dDdot_dD(i_part))
    end do

    if (CONDENSE_DO_TEST_JAC_SOLVE) then
       ! (I - g J) soln = rhs

       ! residual = J soln
       residual(n_eqn) = sum(dHdot_dD * soln(1:(n_eqn-1))) &
            + dHdot_dH * soln(n_eqn)
       residual(1:(n_eqn-1)) = dDdot_dD * soln(1:(n_eqn-1)) &
            + dDdot_dH * soln(n_eqn)

       residual = rhs - (soln - gamma * residual)
       rhs_norm = sqrt(sum(rhs**2))
       soln_norm = sqrt(sum(soln**2))
       residual_norm = sqrt(sum(residual**2))
       write(0,*) 'rhs, soln, residual, residual/rhs = ', &
            rhs_norm, soln_norm, residual_norm, residual_norm / rhs_norm
    end if

    rhs = soln

  end subroutine condense_jac_solve_f
#endif

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

  !> Determine the water equilibrium state of a single particle.
  subroutine condense_equilib_particle(env_state, aero_data, &
       aero_particle)

    !> Environment state.
    type(env_state_t), intent(in) :: env_state
    !> Aerosol data.
    type(aero_data_t), intent(in) :: aero_data
    !> Particle.
    type(aero_particle_t), intent(inout) :: aero_particle

    real(kind=dp) :: X, kappa, D_dry, D, g, dg_dD, a_w, daw_dD
    integer :: newton_step

    X = 4d0 * const%water_molec_weight * const%water_surf_eng &
         / (const%univ_gas_const * env_state%temp &
         * const%water_density)
    kappa = aero_particle_solute_kappa(aero_particle, aero_data)
    D_dry = vol2diam(aero_particle_solute_volume(aero_particle, aero_data))

    D = D_dry
    g = 0d0
    dg_dD = 1d0
    do newton_step = 1,20
       D = D - g / dg_dD
       a_w = (D**3 - D_dry**3) / (D**3 + (kappa - 1d0) * D_dry**3)
       daw_dD = 3d0 * D**2 * kappa * D_dry**3 &
            / (D**3 + (kappa - 1d0) * D_dry**3)**2
       g = env_state%rel_humid - a_w * exp(X / D)
       dg_dD = - daw_dD * exp(X / D) + a_w * exp(X / D) * (X / D**2)
    end do
    call warn_assert_msg(426620001, abs(g) < 1d3 * epsilon(1d0), &
         "convergence problem in equilibriation")

    aero_particle%vol(aero_data%i_water) = diam2vol(D) - diam2vol(D_dry)

  end subroutine condense_equilib_particle

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

  !> Call condense_equilib_particle() on each particle in the aerosol
  !> to ensure that every particle has its water content in
  !> equilibrium.
  subroutine condense_equilib_particles(bin_grid, env_state, aero_data, &
       aero_weight, aero_state)

    !> Bin grid.
    type(bin_grid_t), intent(in) :: bin_grid
    !> Environment state.
    type(env_state_t), intent(inout) :: env_state
    !> Aerosol data.
    type(aero_data_t), intent(in) :: aero_data
    !> Aerosol weight.
    type(aero_weight_t), intent(in) :: aero_weight
    !> Aerosol state.
    type(aero_state_t), intent(inout) :: aero_state

    integer :: i_bin, i_part
    type(aero_particle_t), pointer :: aero_particle
    real(kind=dp) :: old_weight, new_weight
    type(aero_particle_t) :: new_aero_particle
    type(aero_info_t) :: aero_info
    integer :: n_copies, i_dup
 
    call aero_particle_allocate(new_aero_particle)
    call aero_info_allocate(aero_info)
    do i_bin = 1,bin_grid%n_bin
       ! work backwards so any additions and removals will only affect
       ! particles that we've already dealt with
       do i_part = aero_state%bin(i_bin)%n_part,1,-1
          aero_particle => aero_state%bin(i_bin)%particle(i_part)
          old_weight = aero_weight_value(aero_weight, &
               aero_particle_radius(aero_particle))

          ! equilibriate the particle by adjusting its water content
          call condense_equilib_particle(env_state, aero_data, &
               aero_state%bin(i_bin)%particle(i_part))

          ! adjust particle number to account for weight changes
          if (aero_weight%type /= AERO_WEIGHT_TYPE_NONE) then
             new_weight = aero_weight_value(aero_weight, &
                  aero_particle_radius(aero_particle))
             n_copies = prob_round(old_weight / new_weight)
             if (n_copies == 0) then
                aero_info%id = aero_particle%id
                aero_info%action = AERO_INFO_WEIGHT
                aero_info%other_id = 0
                call aero_state_remove_particle_with_info(aero_state, &
                     i_bin, i_part, aero_info)
             elseif (n_copies > 1) then
                do i_dup = 1,(n_copies - 1)
                   call aero_particle_copy(aero_particle, new_aero_particle)
                   call aero_particle_new_id(new_aero_particle)
                   ! this might be adding into the wrong bin, but
                   ! that's necessary as we might not have processed
                   ! the correct bin yet.
                   call aero_state_add_particle(aero_state, i_bin, &
                        new_aero_particle)
                   ! re-get the particle pointer, which may have
                   ! changed due to reallocations caused by adding
                   aero_particle => aero_state%bin(i_bin)%particle(i_part)
                end do
             end if
          end if
       end do
    end do
    ! We've modified particle diameters, so we need to update which
    ! bins they are in.
    call aero_state_resort(bin_grid, aero_state)

    call aero_particle_deallocate(new_aero_particle)
    call aero_info_deallocate(aero_info)

  end subroutine condense_equilib_particles

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
  
end module pmc_condense