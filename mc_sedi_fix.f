C mc_sedi_fix.f
C
C Monte Carlo simulation with sedimentation kernel and fixed timestepping.

CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC

      program MonteCarlo
 
      integer MM, n_bin, scal
      real*8 t_max, del_t, rho_p, N_tot
      parameter (MM = 10000)       ! number of particles
      parameter (n_bin = 160)      ! number of bins
      parameter (scal = 3)         ! scale factor for bins
      parameter (t_max = 600.)     ! total simulation time (seconds)
      parameter (del_t = 1.)       ! timestep (seconds)
      parameter (rho_p = 1000.)    ! particle density (kg m^{-3})
      parameter (N_tot = 1.e+9)    ! particle number concentration (#/m^3)

      integer M, M_comp, i_loop
      real*8 V(MM), V_comp, dlnr, t1
      real*8 n_ini(n_bin), vv(n_bin), dp(n_bin), rr(n_bin)

      external kernel_sedi

      open(30,file='mc.d')
      call srand(10)

      do i_loop = 1,1
         call cpu_time(t1)
         write(6,*)'START ',i_loop, t1
         write(30,*)'i_loop=',i_loop,t1

         M = MM
         M_comp = M
         V_comp = M / N_tot
         
         call make_grid(n_bin, scal, rho_p, vv, dp, rr, dlnr)
         
c     define bidisperse distribution
         n_ini(97) = (M-1)/dlnr
         n_ini(126) = 1/dlnr

         call compute_volumes(n_bin, MM, n_ini, dp, dlnr, V)

         call mc_fix(MM, M, M_comp, V, V_comp, kernel_sedi, n_bin, vv,
     &        rr, dp, dlnr, t_max, del_t)

      enddo

      end

CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC
