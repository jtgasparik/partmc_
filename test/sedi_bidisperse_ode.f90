! Copyright (C) 2005-2007 Nicole Riemer and Matthew West
! Licensed under the GNU General Public License version 2 or (at your
! option) any later version. See the file COPYING for details.
!
! Compute the evolution of a bidisperse distribution with the
! sedimentation kernel.
!
! This is a complete hack and is not supposed to be general or
! re-usable.
! 
! The initial distribution consists of n_small small particles of
! size v_small, and one big particle of size v_big. The
! sedimentation kernel is zero between same sized particles, so all
! that happens is the number of small particles decreases (but the
! remaining ones keep the initial volume) while the big particle
! remains just one particle but grows in volume. This is thus really
! a one-dimensional ODE which we treat as being defined in terms of
! the current number of small particles.

program sedi_bidisperse_ode
  
  use mod_kernel_sedi
  use mod_env
  use mod_util
  use mod_bin_grid
  
  ! volume of one small particle
  real*8, parameter :: v_small = 0.38542868295629027618d-14
  ! initial volume of big particle
  real*8, parameter :: v_big_init = 0.37488307899239913337d-11
  real*8, parameter :: n_small_init = 10000d0 ! init number of small particles
  real*8, parameter :: t_max = 600d0    ! total simulation time
  real*8, parameter :: del_t = 0.001d0  ! timestep
  real*8, parameter :: t_progress = 10d0 ! how often to print progress
  real*8, parameter :: num_conc_small = 1d9 ! particle number conc (#/m^3)
  integer, parameter :: n_bin = 250     ! number of bins
  real*8, parameter :: bin_r_min = 1d-8 ! minimum bin radius (m)
  real*8, parameter :: bin_r_max = 1d0  ! minimum bin radius (m)
  integer, parameter :: scal = 3        ! scale factor for bins
  integer, parameter :: out_unit = 33   ! output unit number
  character(len=*), parameter :: out_name = "out/sedi_bidisperse_ode_counts.d"
  
  type(env_t) :: env
  integer :: i_step, n_step
  real*8 :: comp_vol, n_small, time, dlnr, v_big, num_conc
  type(bin_grid_t) :: bin_grid

  num_conc = num_conc_small * (n_small_init + 1d0) / n_small_init
  comp_vol = (n_small_init + 1d0) / num_conc
  call bin_grid_make(n_bin, rad2vol(bin_r_min), rad2vol(bin_r_max), bin_grid)
  dlnr = bin_grid%dlnr

  open(unit=out_unit, file=out_name)
  time = 0d0
  n_small = n_small_init
  n_step = nint(t_max / del_t) + 1
  v_big = v_big_init + (n_small_init - n_small) * v_small
  write(*,'(a8,a14,a14,a9)') &
       't', 'n_small', 'v_big', 'n_coag'
  write(*,'(f8.1,e14.5,e14.5,f9.2)') &
       time, n_small / comp_vol / dlnr, v_big / comp_vol / dlnr, &
       n_small_init - n_small
  write(out_unit,'(e20.10,e20.10,e20.10)') &
       time, n_small / comp_vol / dlnr, v_big / comp_vol / dlnr
  do i_step = 1,n_step
     time = dble(i_step - 1) * del_t
     call bidisperse_step(v_small, v_big_init, n_small_init, &
          env, comp_vol, del_t, n_small)
     v_big = v_big_init + (n_small_init - n_small) * v_small
     if (mod(i_step - 1, nint(t_progress / del_t)) .eq. 0) then
        write(*,'(a8,a14,a14,a9)') &
             't', 'n_small', 'v_big', 'n_coag'
        write(*,'(f8.1,e14.5,e14.5,f9.2)') &
             time, n_small / comp_vol / dlnr, v_big / comp_vol / dlnr, &
             n_small_init - n_small
        write(out_unit,'(e20.10,e20.10,e20.10)') &
             time, n_small / comp_vol / dlnr, v_big / comp_vol / dlnr
     end if
  end do
  close(out_unit)
  
contains
  
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
  
  subroutine bidisperse_f(n_small, v_small, v_big_init, &
       n_small_init, env, comp_vol, n_small_dot)
    
    use mod_env

    real*8, intent(in) :: n_small       ! current number of small particles
    real*8, intent(in) :: v_small       ! volume of one small particle
    real*8, intent(in) :: v_big_init    ! initial volume of the big particle
    real*8, intent(in) :: n_small_init  ! initial number of small particles
    type(env_t), intent(in) :: env      ! environment state
    real*8, intent(in) :: comp_vol      ! computational volume (m^3)
    real*8, intent(out) :: n_small_dot  ! derivative of n_small
    
    real*8 v_big, k
    
    v_big = v_big_init + (n_small_init - n_small) * v_small
    call kernel_sedi(v_small, v_big, env, k)
    n_small_dot = - k / comp_vol * n_small
    
  end subroutine bidisperse_f
  
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
  
  subroutine bidisperse_step(v_small, v_big_init, n_small_init, &
       env, comp_vol, del_t, n_small)
    
    use mod_env

    real*8, intent(in) :: v_small       ! volume of one small particle
    real*8, intent(in) :: v_big_init    ! initial volume of the big particle
    real*8, intent(in) :: n_small_init  ! initial number of small particles
    type(env_t), intent(in) :: env      ! environment state
    real*8, intent(in) :: comp_vol      ! computational volume (m^3)
    real*8, intent(in) :: del_t         ! timestep
    real*8, intent(inout) :: n_small    ! current number of small particles
    
    real*8 n_small_dot, k1, k2, k3, k4
    
    ! integrate ODE with Runge-Kutta-4
    
    call bidisperse_f(n_small, &
         v_small, v_big_init, n_small_init, env, comp_vol, n_small_dot)
    k1 = del_t * n_small_dot
    
    call bidisperse_f(n_small + k1/2d0, &
         v_small, v_big_init, n_small_init, env, comp_vol, n_small_dot)
    k2 = del_t * n_small_dot
    
    call bidisperse_f(n_small + k2/2d0, &
         v_small, v_big_init, n_small_init, env, comp_vol, n_small_dot)
    k3 = del_t * n_small_dot
    
    call bidisperse_f(n_small + k3, &
         v_small, v_big_init, n_small_init, env, comp_vol, n_small_dot)
    k4 = del_t * n_small_dot
    
    n_small = n_small + k1/6d0 + k2/3d0 + k3/3d0 + k4/6d0
    
  end subroutine bidisperse_step
  
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
  
end program sedi_bidisperse_ode