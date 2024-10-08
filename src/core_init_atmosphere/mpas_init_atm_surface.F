! Copyright (c) 2013,  Los Alamos National Security, LLC (LANS)
! and the University Corporation for Atmospheric Research (UCAR).
!
! Unless noted otherwise source code is licensed under the BSD license.
! Additional copyright and license information can be found in the LICENSE file
! distributed with this code, or at http://mpas-dev.github.com/license.html
!
!==================================================================================================
 module mpas_init_atm_surface
 use mpas_derived_types
 use mpas_pool_routines
 use mpas_timekeeping
 use mpas_timer
 use mpas_log, only : mpas_log_write
 
 use init_atm_hinterp
 use init_atm_llxy
 use init_atm_read_met

 implicit none
 private
 public :: init_atm_case_sfc, interp_sfc_to_MPAS


 contains


!==================================================================================================
 subroutine init_atm_case_sfc(domain, dminfo, stream_manager, mesh, fg, state, dims, configs)
!==================================================================================================

 use mpas_stream_manager

 implicit none

!input arguments:
 type (domain_type), intent(inout) :: domain
 type (dm_info), intent(in)        :: dminfo
 type (MPAS_streamManager_type), intent(inout) :: stream_manager
 type (mpas_pool_type), intent(inout) :: mesh
 type (mpas_pool_type), intent(inout) :: fg
 type (mpas_pool_type), intent(inout) :: state
 type (mpas_pool_type), intent(in)    :: dims
 type (mpas_pool_type), intent(in)    :: configs

!local variables:
 type (MPAS_Time_type)  :: curr_time, stop_time, start_time
 type (MPAS_TimeInterval_type) :: time_since_start
 character(len=StrKIND) :: timeString
 real (kind=RKIND) :: dt

 character(len=StrKIND), pointer :: config_sfc_prefix
 character(len=StrKIND), pointer :: xtime
 real (kind=RKIND), pointer :: Time
 integer :: ierr


!==================================================================================================


 call mpas_pool_get_config(configs, 'config_sfc_prefix', config_sfc_prefix)

 call mpas_pool_get_array(state, 'xtime', xtime)
 call mpas_pool_get_array(state, 'Time', Time)

!loop over all times:
 curr_time = mpas_get_clock_time(domain % clock, MPAS_NOW) 
 stop_time = mpas_get_clock_time(domain % clock, MPAS_STOP_TIME) 
 start_time = mpas_get_clock_time(domain % clock, MPAS_START_TIME)

 do while (curr_time <= stop_time)
    call mpas_get_time(curr_time, dateTimeString=timeString)
    xtime = timeString

    time_since_start = curr_time - start_time
    call mpas_get_timeInterval(time_since_start, dt=dt)
    Time = dt

!   call mpas_log_write('Processing '//trim(config_sfc_prefix)//':'//timeString(1:13))

    !read the sea-surface temperature and sea-ice data from the surface file, and interpolate the
    !data to the MPAS grid:
    call interp_sfc_to_MPAS(timeString(1:13), mesh, fg, dims, dminfo, config_sfc_prefix)

    !write the interpolated SST/SKINTEMP field as a new time slice in the MPAS output file:
    call mpas_stream_mgr_write(stream_manager, streamID='surface', ierr=ierr)
    call mpas_stream_mgr_reset_alarms(stream_manager, streamID='surface', direction=MPAS_STREAM_OUTPUT, ierr=ierr)

    call mpas_advance_clock(domain % clock)
    curr_time = mpas_get_clock_time(domain % clock, MPAS_NOW) 

 end do

 !
 ! Ensure that no output alarms are still ringing for the 'surface' stream after
 ! we exit the time loop above; the main run routine may write out all other
 ! output streams with ringing alarms.
 !
 call mpas_stream_mgr_reset_alarms(stream_manager, streamID='surface', direction=MPAS_STREAM_OUTPUT, ierr=ierr)

 end subroutine init_atm_case_sfc

!==================================================================================================
 subroutine interp_sfc_to_MPAS(timeString, mesh, fg, dims, dminfo, config_sfc_prefix)
!==================================================================================================

 use mpas_dmpar 

 implicit none

!input arguments:
 character(len=*), intent(in) :: timeString
 type (mpas_pool_type), intent(in) :: mesh
 type (mpas_pool_type), intent(in) :: dims
 type (dm_info), intent(in)   :: dminfo
 character(len=*), intent(in) :: config_sfc_prefix

!inout arguments:
 type (mpas_pool_type), intent(inout) :: fg


!local variables:
 type(met_data) :: field !real*4 meteorological data.

 integer :: istatus
 integer :: masked
 integer, dimension(5) :: interp_list
 integer, dimension(:), pointer :: mask_array
 logical :: have_landmask

 real(kind=RKIND) :: fillval, maskval, msgval
 real(kind=RKIND), dimension(:,:), allocatable :: maskslab

 integer, dimension(:), pointer :: landmask
 integer :: global_max_landmask
 real(kind=RKIND), dimension(:), pointer :: destField1d
 real(kind=RKIND), dimension(:), pointer :: sst, xice

 integer, pointer :: nCells

!==================================================================================================

 call mpas_pool_get_array(mesh, 'landmask', mask_array)
 call mpas_pool_get_array(mesh, 'landmask', landmask)
 call mpas_pool_get_array(fg, 'sst', sst)
 call mpas_pool_get_array(fg, 'xice', xice)

 call mpas_pool_get_dimension(dims, 'nCells', nCells)

!
! Try to determine whether we have used a 'grid.nc' or a 'static.nc' file as input. 
! If we are working from a 'grid.nc', we expect that the global maximum of the landmask 
! will be 0.
!
 call mpas_dmpar_max_int(dminfo, maxval(landmask(1:nCells)), global_max_landmask)
 if (global_max_landmask == 0) then
    call mpas_log_write('*******************************************************************************', messageType=MPAS_LOG_ERR)
    call mpas_log_write('The global maximum of the ''landmask'' field is zero, which suggests that this',  messageType=MPAS_LOG_ERR)
    call mpas_log_write('field was not in the input file.  A ''landmask'' field is needed to properly',    messageType=MPAS_LOG_ERR)
    call mpas_log_write('interpolate surface fields.',                                                     messageType=MPAS_LOG_ERR)
    call mpas_log_write('Please rerun after specifying a static or initial conditions file as input in',   messageType=MPAS_LOG_ERR)
    call mpas_log_write('the ''streams.init_atmosphere'' file.',                                           messageType=MPAS_LOG_ERR)
    call mpas_log_write('*******************************************************************************', messageType=MPAS_LOG_CRIT)
 end if

!open intermediate file:
 call read_met_init(trim(config_sfc_prefix),.false.,timeString,istatus)
 if(istatus /= 0) then
    call mpas_log_write('********************************************************************************', messageType=MPAS_LOG_ERR)
    call mpas_log_write('Error opening surface file '//trim(config_sfc_prefix)//':'//timeString(1:13),      messageType=MPAS_LOG_ERR)
    call mpas_log_write('********************************************************************************', messageType=MPAS_LOG_CRIT)
 else
    call mpas_log_write('Processing file '//trim(config_sfc_prefix)//':'//timeString(1:13))
 end if

!scan through all fields in the file, looking for the LANDSEA field:
 have_landmask = .false.
 call read_next_met_field(field,istatus)
 do while (istatus == 0)
    if(trim(field % field) == 'LANDSEA') then
       have_landmask = .true.
       if(.not.allocated(maskslab)) allocate(maskslab(-2:field % nx+3, field % ny))
       maskslab(1:field % nx, 1:field % ny) = field % slab(1:field % nx, 1:field % ny)
       maskslab(0, 1:field % ny)  = field % slab(field % nx, 1:field % ny)
       maskslab(-1, 1:field % ny) = field % slab(field % nx-1, 1:field % ny)
       maskslab(-2, 1:field % ny) = field % slab(field % nx-2, 1:field % ny)
       maskslab(field % nx+1, 1:field % ny) = field % slab(1, 1:field % ny)
       maskslab(field % nx+2, 1:field % ny) = field % slab(2, 1:field % ny)
       maskslab(field % nx+3, 1:field % ny) = field % slab(3, 1:field % ny)
!      call mpas_log_write('minval, maxval of LANDSEA = $r $r', realArgs=(/minval(maskslab), maxval(maskslab)/))
    end if
    deallocate(field % slab)
    call read_next_met_field(field,istatus)
 end do
 call read_met_close()

!read sea-surface temperatures and seaice data. open intermediate file:
 call read_met_init(trim(config_sfc_prefix),.false.,timeString(1:13),istatus)
 if(istatus /= 0) then
    call mpas_log_write('********************************************************************************', messageType=MPAS_LOG_ERR)
    call mpas_log_write('Error opening surface file '//trim(config_sfc_prefix)//':'//timeString(1:13),      messageType=MPAS_LOG_ERR)
    call mpas_log_write('********************************************************************************', messageType=MPAS_LOG_CRIT)
 end if

 if(.not. have_landmask) then
    call mpas_log_write('********************************************************************************')
    call mpas_log_write('Landsea mask not available from the surface file ')
    call mpas_log_write('********************************************************************************')
 end if

!scan through all fields in the file, looking for the SST,SKINTEMP, or SEAICE field:
 call read_next_met_field(field,istatus)
 do while (istatus == 0)

    !sea-surface data:
    if((trim(field % field) == 'SKINTEMP') .or. (trim(field % field) ==  'SST')) then
!      call mpas_log_write('... Processing SST:')
       sst(1:nCells) = 0.0_RKIND
       destField1d => sst

       !interpolation to the MPAS grid:
       interp_list(1) = FOUR_POINT
       interp_list(2) = SEARCH
       interp_list(3) = 0
       msgval  = -1.0e30_R4KIND !missing value
       masked  = -1
       maskval = -1.0_RKIND
       fillval =  0.0_RKIND
       if(have_landmask) then
          call interp_to_MPAS(mesh,nCells,field,destField1d,interp_list,msgval,masked,maskval,fillval, &
                              mask_array,maskslab)
       else
          call interp_to_MPAS(mesh,nCells,field,destField1d,interp_list,msgval,masked,maskval,fillval, &
                              mask_array)
       end if

       !field%slab was allocated in the subroutine read_next_met_field
       deallocate(field%slab)

    !sea-ice data:
    else if(trim(field % field) == 'SEAICE') then
!      call mpas_log_write('... Processing SEAICE:')
       xice(1:nCells) = 0.0_RKIND
       destField1d => xice

       !interpolation to the MPAS grid:
       interp_list(1) = FOUR_POINT
       interp_list(2) = W_AVERAGE4
       interp_list(3) = SEARCH
       interp_list(4) = 0
       msgval  = -1.0e30_R4KIND  !missing value
       masked  = 1
       maskval = 1.0_RKIND
       fillval = 0.0_RKIND
       if(have_landmask) then
          call interp_to_MPAS(mesh,nCells,field,destField1d,interp_list,msgval,masked,maskval,fillval, &
                              mask_array,maskslab)
       else
          call interp_to_MPAS(mesh,nCells,field,destField1d,interp_list,msgval,masked,maskval,fillval, &
                              mask_array)
       end if

       !field%slab was allocated in the subroutine read_next_met_field
       deallocate(field%slab)
        
    else
       deallocate(field%slab)

    end if

    call read_next_met_field(field,istatus)
 end do

!close intermediate file:
 call read_met_close()
 if(allocated(maskslab)) deallocate(maskslab)

!freeze really cold oceans:
 where (sst < 271.0_RKIND .and. landmask == 0) xice = 1.0_RKIND

!limit XICE to values between 0 and 1. Although the input meteorological field is between 0. and 1.
!interpolation to the MPAS grid can yield values of XiCE less than 0. and greater than 1.:
 where (xice < 0._RKIND) xice = 0._RKIND
 where (xice > 1._RKIND) xice = 1._RKIND

 end subroutine interp_sfc_to_MPAS

!==================================================================================================
 subroutine interp_to_MPAS(mesh,nCells,field,destField1d,interp_list,msgval,masked,maskval,fillval, &
                           mask_array,maskslab)
!==================================================================================================

!input arguments:
 type (mpas_pool_type), intent(in) :: mesh
 integer, intent(in) :: nCells
 type (met_data), intent(in)  :: field !real*4 meteorological data.

 integer, intent(in) :: masked
 integer, dimension(5), intent(in) :: interp_list
 integer, dimension(:), intent(in), pointer :: mask_array

 real(kind=RKIND), intent(in) :: fillval, maskval, msgval
 real(kind=RKIND), intent(in), dimension(*), optional :: maskslab

!inout arguments:
 real(kind=RKIND), intent(inout), dimension(:), pointer :: destField1d

!local variables:
 type(proj_info) :: proj
 integer :: i, nInterpPoints
 real(kind=RKIND) :: lat,lon,x,y
 real(kind=RKIND), dimension(:,:), allocatable :: rslab

 real(kind=RKIND), dimension(:), pointer :: latPoints, lonPoints
 real(kind=RKIND), dimension(:), pointer :: latCell, lonCell
 
!--------------------------------------------------------------------------------------------------

 call mpas_pool_get_array(mesh, 'latCell', latCell)
 call mpas_pool_get_array(mesh, 'lonCell', lonCell)

 call map_init(proj)   
 if(field % iproj == PROJ_LATLON) then
    call map_set(PROJ_LATLON, proj, &
                 latinc = real(field % deltalat,RKIND), &
                 loninc = real(field % deltalon,RKIND), &
                 knowni = 1.0_RKIND, &
                 knownj = 1.0_RKIND, &
                 lat1 = real(field % startlat,RKIND), &
                 lon1 = real(field % startlon,RKIND))
!   call mpas_log_write('--- The projection is PROJ_LATLON.')
 else if(field % iproj == PROJ_GAUSS) then
    call map_set(PROJ_GAUSS, proj, &
                 nlat = nint(field % deltalat), &
                 loninc = 360.0_RKIND / real(field % nx,RKIND), &
                 lat1 = real(field % startlat,RKIND), &
                 lon1 = real(field % startlon,RKIND))
!   call mpas_log_write('--- The projection is PROJ_GAUSS.')
 else if(field % iproj == PROJ_PS) then
    call map_set(PROJ_PS, proj, &
                 dx = real(field % dx,RKIND), &
                 truelat1 = real(field % truelat1,RKIND), &
                 stdlon = real(field % xlonc,RKIND), &
                 knowni = real(field % nx / 2.0,RKIND), &
                 knownj = real(field % ny / 2.0,RKIND), &
                 lat1 = real(field % startlat,RKIND), &
                 lon1 = real(field % startlon,RKIND))
!   call mpas_log_write('--- The projection is PROJ_PS.')
 else if (field % iproj == PROJ_LC) then
    call map_set(PROJ_LC, proj, &
                 truelat1 = real(field % truelat1, kind=RKIND), &
                 truelat2 = real(field % truelat2, kind=RKIND), &
                 lat1 = real(field % startlat, kind=RKIND), &
                 lon1 = real(field % startlon, kind=RKIND), &
                 knowni = 1.0_RKIND, &
                 knownj = 1.0_RKIND, &
                 stdlon = real(field % xlonc, kind=RKIND), &
                 dx = real(field % dx, kind=RKIND))
!    call mpas_log_write('-- The projection is PROJ_CASSINI.')
 else if (field % iproj == PROJ_CASSINI ) then
    call map_set(PROJ_CASSINI, proj, &
                 latinc = real(field % deltalat,RKIND), &
                 loninc = real(field % deltalon,RKIND), &
                 lat1 = real(field % centerlat, RKIND), &
                 lon1 = real(field % centerlon, RKIND), &
                 lat0 = real(field % pole_lat, RKIND), &
                 lon0 = real(field % pole_lon, RKIND), &
                 knowni = real((field % ny +1)/2,RKIND), &
                 knownj = real((field % ny + 1)/2,RKIND), &
                 stdlon = real(field % xlonc, RKIND))
 else
    call mpas_log_write('********************************************************************************', &
                        messageType=MPAS_LOG_ERR)
    call mpas_log_write('Unhandled projection in interp_to_MPAS', &
                        messageType=MPAS_LOG_ERR)
    call mpas_log_write('********************************************************************************', &
                        messageType=MPAS_LOG_CRIT)
 end if

 nInterpPoints = nCells
 latPoints => latCell
 lonPoints => lonCell

 allocate(rslab(-2:field % nx+3, field % ny))
 rslab(1:field % nx, 1:field % ny) = field % slab(1:field % nx, 1:field % ny)
 rslab( 0, 1:field % ny) = field % slab(field % nx  , 1:field % ny)
 rslab(-1, 1:field % ny) = field % slab(field % nx-1, 1:field % ny)
 rslab(-2, 1:field % ny) = field % slab(field % nx-2, 1:field % ny)
 rslab(field % nx+1, 1:field % ny) = field % slab(1, 1:field % ny)
 rslab(field % nx+2, 1:field % ny) = field % slab(2, 1:field % ny)
 rslab(field % nx+3, 1:field % ny) = field % slab(3, 1:field % ny)

 do i = 1,nInterpPoints
    if(mask_array(i) /= masked) then
       lat = latPoints(i) * DEG_PER_RAD
       lon = lonPoints(i) * DEG_PER_RAD
       call latlon_to_ij(proj, lat, lon, x, y)
       if(y <= 0.5) then
          y = 1.0
       else if(y >= real(field%ny)+0.5) then
          y = real(field % ny)
       end if
       if(x < 0.5) then
          lon = lon + 360.0
          call latlon_to_ij(proj, lat, lon, x, y)
       else if (x >= real(field%nx)+0.5) then
          lon = lon - 360.0
          call latlon_to_ij(proj, lat, lon, x, y)
       end if
       if(present(maskslab)) then
          destField1d(i) = interp_sequence(x,y,1,rslab,-2,field%nx+3,1,field%ny,1,1, &
                           msgval,interp_list,1,maskval=maskval,mask_array=maskslab)
       else
          destField1d(i) = interp_sequence(x,y,1,rslab,-2,field%nx+3,1,field%ny,1,1, &
                           msgval,interp_list,1,maskval=maskval)
       end if
    else
       destField1d(i) = fillval
    end if
 end do
 deallocate(rslab)

 end subroutine interp_to_MPAS

!==================================================================================================
 end module mpas_init_atm_surface
!==================================================================================================

