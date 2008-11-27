program x_code

  use m_openmpi
  use m_io
  use m_parameters
  use m_fields
  use m_work
  use x_fftw
  use m_stats
  use m_timing
  use m_force
  use m_rand_knuth
  use m_particles
  use m_filter_xfftw

  implicit none

  integer :: n


  call m_openmpi_init
  call m_timing_init   ! Setting the time zero
  call m_io_init
  call m_parameters_init
  call m_fields_init
  call m_work_init


  ! allocating and initializing FFTW arrays
  call x_fftw_allocate(1)
  call x_fftw_init

  call m_stats_init
  call m_force_init

  ! allocating and initializing particles
  if (task.eq.'parts') then
     call particles_init
  end if

  write(out,*) "IN THE PROGRAM."
  call flush(out)


  ! initializing the random number generator
!  call rand_knuth_init

  ! getting the wallclock runlimit for the job
  call get_job_runlimit


!-----------------------------------------------------------------------
!     Starting from the beginning or from the saved flowfield
!-----------------------------------------------------------------------
  if(ITMIN.eq.0) then
     call begin_new
  else
     call begin_restart
  endif

  if (task.eq.'hydro') call divergence


  ! indicators whether to use first-order in time 
  ! for velocities and scalars
  fov = .true.
  fos = .true.


  if (task.eq.'hydro') call dealias_all


!================================================================================
!  MAIN CYCLE
!================================================================================

  do 100 ITIME=ITMIN+1,ITMAX

     ! getting the file extension for current iteration
     call get_file_ext

     select case (task)

!--------------------------------------------------------------------------------
!                             HYDRO PART
!--------------------------------------------------------------------------------
     case ('hydro')


        ! RHS for passive scalars (write)
        call rhs_scalars

        ! now the velocities in x-space are contained in wrk1...3
        ! if we are moving particles, then we want to send the velocity field
        ! to the "parts" part of the code
        call fields_to_parts


        ! advance scalars - either Euler or Adams-Bashforth
        if (int_scalars) then
           call flush(out)
           n = 3 + n_scalars
           if (fos) then
              rhs_old(:,:,:,4:n) = wrk(:,:,:,4:n)
              fields(:,:,:,4:n) = fields(:,:,:,4:n) + dt * rhs_old(:,:,:,4:n)
              fos = .false.
           else
              fields(:,:,:,4:n) = fields(:,:,:,4:n) + &
                   dt * ( 1.5d0 * wrk(:,:,:,4:n)  - 0.5d0 * rhs_old(:,:,:,4:n) )
              rhs_old(:,:,:,4:n) = wrk(:,:,:,4:n)
           end if
        end if

        ! RHS for velocities
        call rhs_velocity

        ! adding forcing, if computing a forced flow
        if (flow_type.eq.1) call force_velocity

        ! advance velocity - either Euler or Adams-Bashforth
        if (fov) then
           rhs_old(:,:,:,1:3) = wrk(:,:,:,1:3)
           fields(:,:,:,1:3) = fields(:,:,:,1:3) + dt * rhs_old(:,:,:,1:3)
           fov = .false.
        else
           fields(:,:,:,1:3) = fields(:,:,:,1:3) + &
                dt * ( 1.5d0 * wrk(:,:,:,1:3)  - 0.5d0 * rhs_old(:,:,:,1:3) )
           rhs_old(:,:,:,1:3) = wrk(:,:,:,1:3)
        end if

        call dealias_all

        ! solve for pressure and update velocities so they are incompressible
        call pressure


        ! advance the time
        TIME = TIME + DT

        if (mod(itime,IPRINT2).eq.0) call restart_write


        ! change the timestep
        if (variable_dt) call my_dt

        ! CPU usage statistics
        if (mod(itime,iprint1).eq.0) then
           call m_timing_check
           write(out,9000) itime,time,dt,courant,cpu_hrs,cpu_min,cpu_sec
           call flush(out)
        end if

        ! send the velocities to the "stats" part of the code for statistics
        if (mod(itime,iprint1).eq.0 .or. mod(itime,iwrite4).eq.0) then
           call fields_to_stats
           ! checking if we need to stop the calculations due to simulation time
           if (TIME.gt.TMAX) call my_exit(1)

           ! checking if we need to start advancing scalars
           if (n_scalars.gt.0 .and. .not.int_scalars .and. time.gt.TSCALAR) then
              int_scalars = .true.
              call init_scalars
              write(out,*) "Starting to move the scalars."
              call flush(out)
           end if

        end if

!--------------------------------------------------------------------------------
!                             STATISTICS PART
!--------------------------------------------------------------------------------
     case ('stats')

        if (mod(itime,iprint1).eq.0 .or. mod(itime,iwrite4).eq.0) then
           call fields_to_stats
           if (mod(itime,iprint1).eq.0) call stat_main
           if (mod(itime,iwrite4).eq.0) call io_write_4

           ! checking if we need to stop the calculations due to simulation time
           if (TIME.gt.TMAX) call my_exit(1)


           ! checking if we need to start advancing scalars
           if (.not. int_scalars .and. time .gt. TSCALAR) then
              int_scalars = .true.
              write(out,*) "Starting to move the scalars."
              call flush(out)
           end if

        end if

!--------------------------------------------------------------------------------
!                             PARTICLE PARTS
!--------------------------------------------------------------------------------
     case ('parts')
        call fields_to_parts

        if (int_particles) then
           call particles_move
           if (mod(itime,iwrite4).eq.0) call particles_restart_write_binary
        end if

        if (mod(itime,iprint1).eq.0 .or. mod(itime,iwrite4).eq.0) then
           if (TIME.gt.TMAX) call my_exit(1)
        end if

!--------------------------------------------------------------------------------
!                             OTHER PARTS
!--------------------------------------------------------------------------------

     case default

        write(out,*) "skipping the time step",ITIME
        call flush(out)

     end select

!--------------------------------------------------------------------------------
!                             COMMON PARTS
!--------------------------------------------------------------------------------


     ! checking for the run time every 10 iterations
     if (mod(ITIME,10).eq.0) then

        ! synchronize all processors, hard
        call MPI_BARRIER(MPI_COMM_WORLD,mpi_err)

        if (myid_world.eq.0) call m_timing_check
        count = 1
        call MPI_BCAST(cpu_min_total,count,MPI_INTEGER4,0,MPI_COMM_WORLD,mpi_err)
        if (cpu_min_total+30 .gt. job_runlimit) call my_exit(2)

        ! user termination.  If the file "stop" is in the directory, stop
	inquire(file='stop',exist=there)
	if (there) call my_exit(3)
     end if



100  continue
!================================================================================

     ITIME = ITIME-1
     if (task.eq.'hydro') call restart_write

!  checking the writing restart in parallel
     file_ext = 'xxxxxx'
     last_dump = 0
     if (task.eq.'hydro') call restart_write_parallel
     

     call my_exit(0)


9000 format('ITIME=',i6,3x,'TIME=',f8.4,4x,'DT=',f8.5,3x,'Courn= ',f6.4, &
          2x,'CPU:(',i4.4,':',i2.2,':',i2.2,')')

!================================================================================
!!$     call x_fftw_allocate(-1)
!!$     call m_work_exit
!!$     call m_fields_exit
!!$     call m_io_exit
     call m_openmpi_exit

     stop
   end program x_code