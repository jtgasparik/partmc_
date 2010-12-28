! Copyright (C) 2009-2010 Matthew West
! Licensed under the GNU General Public License version 2 or (at your
! option) any later version. See the file COPYING for details.

!> \file
!> The extract_aero_species program.

!> Read NetCDF output files and write out the per-species bulk aerosol
!> concentrations in text format.
program extract_aero_species

  use netcdf

  integer, parameter :: dp = kind(0.d0)
  integer, parameter :: out_unit = 64

  character(len=1000) :: in_prefix, in_filename, out_filename
  integer :: ncid
  integer :: dimid_aero_species, dimid_aero_particle
  integer :: varid_time, varid_aero_species
  integer :: varid_aero_particle_mass
  integer :: varid_aero_comp_vol
  integer :: n_aero_species, n_aero_particle
  character(len=1000) :: tmp_str, aero_species_names, remaining_species
  real(kind=dp) :: time
  real(kind=dp), allocatable :: aero_particle_mass(:,:)
  real(kind=dp), allocatable :: aero_comp_vol(:)
  real(kind=dp), allocatable :: aero_conc(:)
  integer :: xtype, ndims, nAtts
  integer, dimension(nf90_max_var_dims) :: dimids
  integer :: ios, i_time, i_spec, i_part, status, n_time, i
  character(len=36) :: uuid, run_uuid

  ! process commandline arguments
  if (command_argument_count() .ne. 2) then
     write(6,*) 'Usage: extract_aero_species <netcdf_state_prefix>' &
          // ' <output_filename>'
     stop 2
  endif
  call get_command_argument(1, in_prefix)
  call get_command_argument(2, out_filename)

  ! open output file
  open(unit=out_unit, file=out_filename, status='replace', iostat=ios)
  if (ios /= 0) then
     write(0,'(a,a,a,i4)') 'ERROR: unable to open file ', &
          trim(out_filename), ' for writing: ', ios
     stop 1
  end if

  ! write information
  write(*,'(a,a)') "Output file: ", trim(out_filename)
  write(*,'(a)') "  Each row of output is one time."
  write(*,'(a)') "  The columns of output are:"
  write(*,'(a)') "    column  1: time (s)"

  ! process NetCDF files
  i_time = 0
  n_time = 0
  do while (.true.)
     i_time = i_time + 1
     write(in_filename,'(a,i8.8,a)') trim(in_prefix), i_time, ".nc"
     status = nf90_open(in_filename, NF90_NOWRITE, ncid)
     if (status /= NF90_NOERR) then
        exit
     end if
     n_time = i_time

     ! read and check uuid
     call nc_check_msg(nf90_get_att(ncid, NF90_GLOBAL, "UUID", uuid), &
          "getting global attribute 'UUID'")
     if (i_time == 1) then
        run_uuid = uuid
     else
        if (run_uuid /= uuid) then
           write(0,*) 'ERROR: UUID mismatch at: ' // trim(in_filename)
           stop 1
        end if
     end if

     ! read time
     call nc_check_msg(nf90_inq_varid(ncid, "time", varid_time), &
          "getting variable ID for 'time'")
     call nc_check_msg(nf90_get_var(ncid, varid_time, time), &
          "getting variable 'time'")

     ! read aero_species
     call nc_check_msg(nf90_inq_dimid(ncid, "aero_species", dimid_aero_species), &
          "getting dimension ID for 'aero_species'")
     call nc_check_msg(nf90_Inquire_Dimension(ncid, dimid_aero_species, &
          tmp_str, n_aero_species), "inquiring dimension 'aero_species'")
     call nc_check_msg(nf90_inq_varid(ncid, "aero_species", varid_aero_species), &
          "getting variable ID for 'aero_species'")
     call nc_check_msg(nf90_get_att(ncid, varid_aero_species, &
          "names", aero_species_names), &
          "getting attribute 'names' for variable 'aero_species'")
     if (i_time == 1) then
        allocate(aero_conc(n_aero_species))
        remaining_species = aero_species_names
        do i_spec = 1,n_aero_species
           if (i_spec < n_aero_species) then
              i = index(remaining_species, ',')
           else
              i = index(remaining_species, ' ')
           end if
           write(*,'(a,i2,a,a,a)') '    column ', i_spec + 1, ': ', &
                remaining_species(1:(i-1)), ' (kg/m^3)'
           remaining_species = remaining_species((i+1):)
        end do
     end if
     
     ! read aero_particle dimension
     status = nf90_inq_dimid(ncid, "aero_particle", dimid_aero_particle)
     if (status == NF90_EBADDIM) then
        ! dimension missing ==> no particles, so concentration = 0
        aero_conc = 0d0
     else
        call nc_check_msg(status, "getting dimension ID for 'aero_particle'")
        call nc_check_msg(nf90_Inquire_Dimension(ncid, dimid_aero_particle, &
             tmp_str, n_aero_particle), "inquiring dimension 'aero_species'")
        
        ! read aero_particle_mass
        call nc_check_msg(nf90_inq_varid(ncid, "aero_particle_mass", &
             varid_aero_particle_mass), &
             "getting variable ID for 'aero_particle_mass'")
        call nc_check_msg(nf90_Inquire_Variable(ncid, varid_aero_particle_mass, &
             tmp_str, xtype, ndims, dimids, nAtts), &
             "inquiring variable 'aero_particle_mass'")
        if ((ndims /= 2) &
             .or. (dimids(1) /= dimid_aero_particle) &
             .or. (dimids(2) /= dimid_aero_species)) then
           write(*,*) "ERROR: unexpected aero_particle_mass dimids"
           stop 1
        end if
        allocate(aero_particle_mass(n_aero_particle, n_aero_species))
        call nc_check_msg(nf90_get_var(ncid, varid_aero_particle_mass, &
             aero_particle_mass), "getting variable 'aero_particle_mass'")
        
        ! read aero_comp_vol
        call nc_check_msg(nf90_inq_varid(ncid, "aero_comp_vol", &
             varid_aero_comp_vol), "getting variable ID for 'aero_comp_vol'")
        call nc_check_msg(nf90_Inquire_Variable(ncid, varid_aero_comp_vol, &
             tmp_str, xtype, ndims, dimids, nAtts), &
             "inquiring variable 'aero_comp_vol'")
        if ((ndims /= 1) &
             .or. (dimids(1) /= dimid_aero_particle)) then
           write(*,*) "ERROR: unexpected aero_comp_vol dimids"
           stop 1
        end if
        allocate(aero_comp_vol(n_aero_particle))
        call nc_check_msg(nf90_get_var(ncid, varid_aero_comp_vol, &
             aero_comp_vol), "getting variable 'aero_comp_vol'")
        
        call nc_check_msg(nf90_close(ncid), &
             "closing file " // trim(in_filename))
        
        ! compute per-species total mass
        aero_conc = 0d0
        do i_part = 1,n_aero_particle
           do i_spec = 1,n_aero_species
              aero_conc(i_spec) = aero_conc(i_spec) &
                   + aero_particle_mass(i_part, i_spec) &
                   / aero_comp_vol(i_part)
           end do
        end do

        deallocate(aero_particle_mass)
        deallocate(aero_comp_vol)
     end if

     ! output data
     write(out_unit, '(e30.15e3)', advance='no') time
     do i_spec = 1,n_aero_species
        write(out_unit, '(e30.15e3)', advance='no') &
             aero_conc(i_spec)
     end do
     write(out_unit, '(a)') ''

  end do

  if (n_time == 0) then
     write(*,'(a,a)') 'ERROR: no input file found matching: ', &
          trim(in_filename)
     stop 1
  end if

  close(out_unit)
  deallocate(aero_conc)

contains

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

  !> Check return status of NetCDF function calls.
  subroutine nc_check_msg(status, error_msg)

    !> Status return value.
    integer, intent(in) :: status
    !> Error message in case of failure.
    character(len=*), intent(in) :: error_msg

    if (status /= NF90_NOERR) then
       write(0,*) trim(error_msg) // " : " // trim(nf90_strerror(status))
       stop 1
    end if

  end subroutine nc_check_msg

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

#ifdef DEFINE_LOCAL_COMMAND_ARGUMENT
  integer function command_argument_count()
    command_argument_count = iargc()
  end function command_argument_count
  subroutine get_command_argument(i, arg)
    integer, intent(in) :: i
    character(len=*), intent(out) :: arg
    call getarg(i, arg)
  end subroutine get_command_argument
#endif
  
end program extract_aero_species
