! $Id: receiver.f90 687 2008-02-13 14:39:42Z sebastian $ 
! ------------------------------------------------------------------------------
! 
!    Copyright 2007 Sebastian Heimann
! 
!    Licensed under the Apache License, Version 2.0 (the "License");
!    you may not use this file except in compliance with the License.
!    You may obtain a copy of the License at
! 
!        http://www.apache.org/licenses/LICENSE-2.0
! 
!    Unless required by applicable law or agreed to in writing, software
!    distributed under the License is distributed on an "AS IS" BASIS,
!    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
!    See the License for the specific language governing permissions and
!    limitations under the License.
!


module receiver

    use better_varying_string
    use util
    use orthodrome
    use sparse_trace
    use piecewise_linear_function
    use comparator
    use seismogram_io
    
    implicit none
    
    private
    
  ! This module groups methods to handle multi-component receivers, and
  ! to calculate misfits.
      
    integer, parameter, public :: C_AWAY   =  1   ! a
    integer, parameter, public :: C_COMING = -1   ! c
    
    integer, parameter, public :: C_RIGHT  =  2   ! r
    integer, parameter, public :: C_LEFT   = -2   ! l
    
    integer, parameter, public :: C_DOWN   =  3   ! d
    integer, parameter, public :: C_UP     = -3   ! u
    
    integer, parameter, public :: C_NORTH  =  4   ! n
    integer, parameter, public :: C_SOUTH  = -4   ! s
    
    integer, parameter, public :: C_EAST   =  5   ! e
    integer, parameter, public :: C_WEST   = -5   ! w
    
  ! probe ids
    integer, parameter, public :: REFERENCES = 1
    integer, parameter, public :: SYNTHETICS = 2
  
    
    character, public, dimension(-5:5) :: component_names = (/ 'w', 's', 'u', 'l', 'c', '?', 'a', 'r', 'd', 'n', 'e' /)
    
    type, public :: t_receiver
    
      ! sampling rate
        real                                       :: dt
    
      ! location of the receiver
        type(t_geo_coords)                         :: origin
        
      ! number of components (must be in sync with size(components))
        integer                                    :: ncomponents
        
      ! what component is what
        integer, dimension(:), allocatable         :: components
      
      ! displacement for each component
        type(t_strip),dimension(:), allocatable    :: displacement
      
      ! misfit between synthetic and reference for every component
        real, dimension(:), allocatable            :: misfits

        real, dimension(:), allocatable            :: misfits_norm_factors
        
      ! cross-correlation between synthetics and reference for every component
        real, dimension(:,:), allocatable          :: cross_corr

      ! probes for each component of reference and sythetics
      ! (these are used to compare references to synthetics in comparator.f90)
        type(t_probe), dimension(:), allocatable   :: ref_probes, syn_probes

    end type

    public receiver_init
    public receiver_destroy
    public receiver_component_index
    public receiver_component_sign
    public receiver_set_filter
    public receiver_set_taper
    public receiver_output_seismogram
    public receiver_output_seismogram_spectra
    public receiver_set_ref_seismogram
    public receiver_shift_ref_seismogram
    public receiver_autoshift_ref_seismogram
    public receiver_calculate_misfits
    public receiver_calculate_cross_correlations
    public receiver_output_cross_correlations

    public character_to_id
    
  contains
 
    subroutine receiver_init( self, origin, components_str, dt, ok )
    
        type(t_receiver), intent(inout)  :: self
        type(t_geo_coords), intent(in)   :: origin          ! location of receiver 
        character(len=*), intent(in)     :: components_str  ! componenents at this receiver
        real, intent(in)                 :: dt              ! sampling rate
        logical, intent(out)             :: ok              ! exit status
        
      ! initialize a receiver object
        
        integer id, i,j, ncomponents,icomponent
        
        call receiver_destroy( self )
        ok = .false.
        
        self%dt = dt
        
      ! parse and check components string
      
        ncomponents = len_trim( components_str )
        if (ncomponents .eq. 0) return
        allocate( self%components(ncomponents) )
        do i=1,ncomponents
            id = character_to_id( components_str(i:i) )
            
            if (id .eq. 0) then
                deallocate( self%components )
                return
            end if
            
          ! check for forbidden combinations
            if (i>1) then
                do j=1,i-1
                    if (abs(self%components(j)) == abs(id)) then
                        deallocate( self%components )
                        return
                    end if
                end do
            end if
            
            self%components(i) = id
            
        end do
        
        ok = .true.
        
      ! initialize the contents
      
        self%ncomponents = ncomponents
        self%origin = origin
        
        allocate( self%displacement(ncomponents) )
        allocate( self%ref_probes(ncomponents) )
        allocate( self%syn_probes(ncomponents) )
        allocate( self%misfits(ncomponents) )
        allocate( self%misfits_norm_factors(ncomponents) )
        
        do icomponent=1,ncomponents
            call probe_init( self%ref_probes(icomponent), dt )
            call probe_init( self%syn_probes(icomponent), dt )
        end do
        
    end subroutine
    
    subroutine receiver_destroy( self )
    
        type(t_receiver), intent(inout)  :: self
        
      ! deallocate everything attached to this receiver object
      ! this does not fail when called more then once or the object has not been initialized.
        
        integer ::  icomponent
        
        if (allocated(self%ref_probes)) then
            do icomponent=1,self%ncomponents
                call probe_destroy( self%ref_probes(icomponent) )
            end do
            deallocate( self%ref_probes )
        end if
        
        if (allocated(self%syn_probes)) then
            do icomponent=1,self%ncomponents
                call probe_destroy( self%syn_probes(icomponent) )
            end do
            deallocate( self%syn_probes )
        end if
        
        if (allocated(self%displacement)) then
            do icomponent=1,self%ncomponents
                call strip_destroy( self%displacement(icomponent) )
            end do
            deallocate( self%displacement )
        end if
        
        if (allocated(self%components)) then
            deallocate(self%components)
        end if
        
        if (allocated(self%misfits)) then
            deallocate(self%misfits)
        end if
        
        if (allocated(self%misfits_norm_factors)) then
            deallocate(self%misfits_norm_factors)
        end if
        
        self%ncomponents = 0
        self%origin%lat = 0.0
        self%origin%lon = 0.0
        self%dt = 0.0
        
    end subroutine
    
    pure function character_to_id( ch )
    
        character, intent(in) :: ch
        integer :: character_to_id
        
      ! lookup id of component character
        
        integer :: i
        
        do i=lbound(component_names,1),ubound(component_names,1)
            character_to_id = i
            if (ch .eq. component_names(i)) return
        end do
        character_to_id = 0
    
    end function
  
    function receiver_component_index( self, component  ) result( ind )
        
        type(t_receiver), intent(in) :: self
        integer, intent(in) :: component
        integer :: ind
        
      ! get index of a specific component or zero if it is not available
        
        integer :: i
        
        ind = 0
        if (.not. allocated(self%components)) return
        
        do i=1,size(self%components,1)
            if (abs(self%components(i)) == abs(component)) then
               ind = i
               return
            end if
        end do
        
    end function
    
    function receiver_component_sign( self, component  ) result( sig )
        
        type(t_receiver), intent(in) :: self
        integer, intent(in) :: component
        real :: sig
        
      ! get sign of a specific component or zero if component not available
        
        integer :: i
        
        sig = 0.
        if (.not. allocated(self%components)) return
        
        do i=1,size(self%components,1)
            if (abs(self%components(i)) == abs(component)) then
               sig = sign(1.,real(self%components(i)))
               return
            end if
        end do
        
    end function
    
    subroutine receiver_set_filter( self, filter )
    
        type(t_receiver), intent(inout) :: self
        type(t_plf), intent(in) :: filter
        
      ! turn on filtering on all components of this receiver
       
        integer :: icomponent
        
        do icomponent=1,self%ncomponents
            call probe_set_filter( self%ref_probes(icomponent), filter )
            call probe_set_filter( self%syn_probes(icomponent), filter )
        end do
        
    end subroutine
    
    subroutine receiver_set_taper( self, taper )
    
        type(t_receiver), intent(inout) :: self
        type(t_plf), intent(in) :: taper
      
      ! turn on tapering on all components of this receiver 
       
        integer :: icomponent
        
        do icomponent=1,self%ncomponents
            call probe_set_taper( self%ref_probes(icomponent), taper )
            call probe_set_taper( self%syn_probes(icomponent), taper )
        end do
        
    end subroutine
    
    subroutine receiver_calculate_misfits( self, misfit_method )
    
        type(t_receiver), intent(inout) :: self
        integer, intent(in)             :: misfit_method
        
      ! calculate misfits between synthetics and references for all components of this receiver
        
        integer :: icomponent
        
        do icomponent=1,self%ncomponents
            call probe_set_array( self%syn_probes(icomponent), self%displacement(icomponent) )
        
            self%misfits(icomponent) = probes_norm( self%ref_probes(icomponent), &
                                                    self%syn_probes(icomponent), &
                                                    misfit_method )
            self%misfits_norm_factors(icomponent) = &
                                       probe_norm( self%ref_probes(icomponent), &
                                                    misfit_method )
        end do
    
    end subroutine

    subroutine receiver_calculate_cross_correlations( self, shiftrange )
    
        type(t_receiver), intent(inout)    :: self
        integer, intent(in), dimension(2)  :: shiftrange
        
      ! calculate cross-correlation between synthetics and references for all components of this receiver
        
        integer :: icomponent
        
        if (allocated(self%cross_corr)) then
            deallocate( self%cross_corr )
        end if
        allocate( self%cross_corr(shiftrange(1):shiftrange(2),self%ncomponents) )

        do icomponent=1,self%ncomponents
            call probe_set_array( self%syn_probes(icomponent), self%displacement(icomponent) )
            call probes_windowed_cross_corr( self%syn_probes(icomponent), self%ref_probes(icomponent), &
                                             shiftrange, self%cross_corr(:,icomponent) )
        end do
    
    end subroutine
    
    subroutine receiver_output_seismogram( self, filenamebase, fileformat, which_probe, which_processing, ok )
    
        type(t_receiver), intent(inout)   :: self
        type(varying_string), intent(in)  :: filenamebase, fileformat
        integer, intent(in)               :: which_probe, which_processing
        logical, intent(out)              :: ok
        
        type(varying_string)        :: outfn
        integer                     :: icomponent
        integer                     :: nerr
        type(t_strip)               :: strip
        integer, dimension(2)       :: span
 
        real :: dt
        
        dt = self%dt
        
        ok = .true.
        do icomponent=1, self%ncomponents
            outfn = filenamebase // "-" // component_names(self%components(icomponent)) // "." // fileformat
            
            if (which_probe == SYNTHETICS .and. which_processing == PLAIN) then ! shortcut avoiding some copying
                span = strip_span(self%displacement(icomponent))
                call writeseismogram( char(outfn), "*", &
                                      self%displacement(icomponent)%data, &
                                      (span(1)-1)*dt, dt, nerr )
            else 
                if (which_probe == SYNTHETICS) then
                    call probe_set_array( self%syn_probes(icomponent), self%displacement(icomponent) )
                    call probe_get( self%syn_probes(icomponent), strip, which_processing )
                else 
                    call probe_get( self%ref_probes(icomponent), strip, which_processing )
                end if
                span = strip_span( strip )
                call writeseismogram( char(outfn), "*", &
                            strip%data, &
                            (span(1)-1)*dt, dt, nerr )
            end if
            if (nerr /= 0) then
                ok = .false.
                call error( "failed to write output file: " // outfn )
                call strip_destroy(strip)
                return
            end if
            
        end do
        call strip_destroy( strip )
        
    end subroutine
    
    subroutine receiver_output_seismogram_spectra( self, filenamebase, which_probe, which_processing, ok )
    
        type(t_receiver), intent(inout)   :: self
        type(varying_string), intent(in)  :: filenamebase
        integer, intent(in)               :: which_probe, which_processing
        logical, intent(out)              :: ok
        
        type(varying_string)        :: outfn
        integer                     :: icomponent
        integer                     :: nerr
        type(t_strip)               :: strip
 
        real :: df
        
        ok = .true.
        
        do icomponent=1, self%ncomponents
            outfn = filenamebase // "-" // component_names(self%components(icomponent)) // ".table"
            
            if (which_probe == SYNTHETICS) then
                call probe_set_array( self%syn_probes(icomponent), self%displacement(icomponent) )
                call probe_get_amp_spectrum( self%syn_probes(icomponent), strip, df, which_processing )
            else
                call probe_get_amp_spectrum( self%ref_probes(icomponent), strip, df, which_processing )
            end if
                
            call writeseismogram( char(outfn), "*", &
                                  strip%data, &
                                  0.0, df, nerr )
            if (nerr /= 0) then
                ok = .false.
                call error( "failed to write output file: " // outfn )
                call strip_destroy( strip )
                return
            end if
            
        end do
        call strip_destroy( strip )
        
    end subroutine

    subroutine receiver_output_cross_correlations( self, filenamebase, ok )
    
        type(t_receiver), intent(inout)   :: self
        type(varying_string), intent(in)  :: filenamebase
        logical, intent(out)              :: ok

        type(varying_string)        :: outfn
        integer                     :: icomponent
        integer                     :: nerr

        ok = .true.

        if (.not. allocated(self%cross_corr)) then
            ok = .false.
            call error( "no cross-correlations have been calculated yet" )
            return
        end if

        ok = .true.
        do icomponent=1, self%ncomponents
            outfn = filenamebase // "-" // component_names(self%components(icomponent)) // ".table"
            call writeseismogram( char(outfn), "*", &
                                  self%cross_corr(:,icomponent), &
                                  lbound(self%cross_corr,1)*self%dt, self%dt, nerr )
            if (nerr /= 0) then
                ok = .false.
                call error( "failed to write output file: " // outfn )
                return
            end if
        end do

    end subroutine
    
    subroutine receiver_set_ref_seismogram( self, reffnbase, refformat, ok )
    
        type(t_receiver), intent(inout)    :: self
        type(varying_string), intent(in)   :: reffnbase, refformat
        logical, intent(out) :: ok

      ! read a set of reference seismograms from ascii or sac files
        
        integer                         :: icomponent, nerr
        real                            :: toffset, deltat
        type(varying_string)            :: reffn
        type(t_strip)                   :: strip
        real, dimension(:), allocatable :: temp_seismogram
        
        ok = .true.
        
        do icomponent=1,self%ncomponents
            reffn = reffnbase // "-" // component_names(self%components(icomponent)) // "." // refformat
            call readseismogram( char(reffn), "*", temp_seismogram, toffset, &
                                deltat, nerr )
            if (nerr /= 0) call die("failed to read seismogram from file " // reffn)
            
            
            if (abs(deltat - self%dt)>self%dt/10000.) then
                call die("sampling rate in file " // reffn // " is " // deltat //&
                            " but required sampling rate is " // self%dt )
            end if
            
            call seismogram_to_strip( temp_seismogram, toffset, self%dt, &
                                    strip )
            
            call probe_set_array( self%ref_probes(icomponent), strip )
            
        end do
        
        call strip_destroy( strip )
        if ( allocated(temp_seismogram) ) deallocate(temp_seismogram)
    
    end subroutine
    
    subroutine receiver_shift_ref_seismogram( self, ishift )

        type(t_receiver), intent(inout)    :: self
        integer, intent(in) :: ishift

        integer :: icomponent

        do icomponent=1,self%ncomponents
            call probe_shift( self%ref_probes(icomponent), ishift )
        end do

    end subroutine

    subroutine receiver_autoshift_ref_seismogram( self, ishiftrange, ishift )

        type(t_receiver), intent(inout)    :: self
        integer, dimension(2), intent(in)  :: ishiftrange
        integer, intent(out) :: ishift

        integer :: imax
        
        call receiver_calculate_cross_correlations( self, ishiftrange )

        imax = maxloc( sum(max(self%cross_corr/max(1.,maxval(self%cross_corr)),0.)**2,2),1 )
        !imax = minloc( sum(max(self%cross_corr/max(1.,maxval(self%cross_corr)),0.),2),1 )
        ishift = imax+ishiftrange(1)-1
        call receiver_shift_ref_seismogram( self, ishift )

    end subroutine

    subroutine seismogram_to_strip( seismogram, tbegin, deltat, strip )
    
        real, dimension(:), intent(in) :: seismogram
        real, intent(in) :: tbegin, deltat
        type(t_strip), intent(inout) :: strip
        
        integer :: ibeg,nlen
        
        ibeg = nint(tbegin/deltat)
        nlen = size(seismogram,1)
      !  if (abs(ibeg*deltat - tbegin) > deltat/100.) then
      !      call die( "time of first sample of seismogram not "// &
      !                 "divideable by sampling distance" )
      !  end if
        
        call strip_init( (/ibeg+1,ibeg+nlen/), seismogram, strip )
    
    end subroutine
 
    
end module