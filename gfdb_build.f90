! $Id: gfdb_build.f90 658 2007-08-03 12:48:49Z sebastian $ 
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

module gfdb_build_

    use util
    use unit
    use gfdb
    use better_varying_string
    use sparse_trace
    use read_table
    use seismogram_io   
    
    implicit none
      
    private  
    public addentry, set_database, close_database
    
    type(t_gfdb), save :: db
    integer :: traces_added = 0
    
  contains
  
    subroutine set_database( basefn, nchunks, nx,nz,ng, dt,dx,dz, firstx, firstz )
        
        type(varying_string), intent(in) :: basefn
        integer, intent(in), optional :: nchunks, nx,nz,ng
        real, intent(in), optional :: dt, dx, dz
        real, intent(in), optional :: firstx, firstz
        
        if (present(nchunks) .and. present(nx) .and. present(nz) .and. &
            present(ng) .and. present(dt) .and. present(dx) .and. present(dz)) then
            call gfdb_init(db, basefn, nchunks, nx,nz,ng, dt,dx,dz, firstx, firstz )
        else 
            call gfdb_init(db, basefn)
        end if
        
    end subroutine
    
    subroutine close_database()
        call gfdb_destroy( db )
    end subroutine
    
    subroutine addentry( buffer, ok )
    
        character(len=*), intent(in) :: buffer
        logical, intent(out)         :: ok
        
        character(len=len(buffer)), dimension(max(1,(count_words(buffer)-3))) :: filename
        
        real, dimension(:,:), allocatable :: field
        integer :: iunit, ig, ifile, nfiles, ioffset, iostat, ix, iz
        real :: x, z
        type(t_strip) :: conti
        type(t_trace) :: tr, trold, tr2
        integer, dimension(2) :: span
                
        nfiles = size(filename)
        
        read (unit=buffer,fmt=*,iostat=iostat) x, z, ig, &
                                               (filename(ifile), ifile=1,nfiles)
        if (iostat == 0) then
            ok = .true.
            
            do ifile=1,nfiles
              ! suck file into table 'field'
                call claim_unit(iunit)
                open( unit=iunit, file=filename(ifile), status='old', iostat=iostat )
                if (iostat /= 0) call die( "gfdb_build: can't open file '" &
                                                // var_str(filename(ifile)) // "'" )
                call readtable( field, iunit=iunit )
                close( iunit ) 
                call release_unit(iunit)
                
                if (size(field,1) /= 2) then
                    call die("gfdb_build: expected exactly two columns in file '" & 
                                            // var_str(filename(ifile)) // "'" )
                end if
                
              ! convert field => strip
                ioffset = floor(field(1,1)/db%dt) + 1
              
                span(1) = ioffset
                span(2) = ioffset+size(field,2)-1
                call strip_init( span, field(2,:), conti )
                
              ! pack strip => sparse trace
                if (ifile == 1) then
                    call trace_pack( conti, tr )
                else 
                    call trace_pack( conti, tr2 ) ! horribly inefficient, but who cares...
                    call trace_copy( tr, trold )
                    call trace_join( trold, tr2, tr )
                end if
                
                if (allocated(field)) deallocate(field)
            end do
            
          ! put in database
            
            call gfdb_get_indices( db, x, z, ix, iz )
            call gfdb_save_trace( db, ix, iz, ig, tr )
            traces_added = traces_added + 1
            
          ! periodically close the gfdb, so that hdf is forced to deallocate
          ! all it's memory
            if (traces_added > 1000) then
                call gfdb_close( db )
                traces_added = 0
            end if
            
            do ifile=1,nfiles
                print *, filename(ifile)
                call flush(stdout)

            end do
        end if
       
        call strip_destroy( conti )
        call trace_destroy( tr )
        call trace_destroy( tr2 )
        call trace_destroy( trold )
        
    end subroutine 

end module

program gfdb_build
  
  ! This program is used to create and fill a Greens function database to be used with the invearthquake programs.
  !
  ! usage: gfdb_build database [ nchunks nx nz ng dt dx dz [ firstx firstz ] ] <<EOF
  ! x z ig 'filename1' ...
  ! ...
  ! EOF
  !
  ! Complete documentation is available on
  ! 
  !   http://kinherd.org/power/trac/wiki/GFDBBuildTool
  !
  
    use util
    use better_varying_string
    use varying_string_getarg
    use read_line
    use gfdb_build_
    
    ! use f90_unix_env
    
    implicit none
    
    integer              :: nchunks, nx, nz, ng
    real                 :: dt, dx, dz
    real                 :: firstx, firstz
    type(varying_string) :: basefn
    integer              :: iostat, iline
    logical              :: ok
    character, parameter :: eol = char(10)
    
    g_pn = 'gfdb_build'
    g_usage = 'usage: ' // g_pn // ' database [ nchunks nx nz ng dt dx dz [ firstx firstz ] ] <<EOF' // eol // & 
              "x z ig 'filename1' ..." // eol // &
              "..." // eol // &
              "EOF" // eol // eol // &
              "documentation:  " // &
              "http://kinherd.org/power/trac/wiki/GFDBBuildTool"
    
    if (iargc() /= 10 .and. iargc() /= 8 .and. iargc() /= 1) call usage()
    
    call vs_getarg( 1, basefn )
    if (iargc() == 8 .or. iargc() == 10) then
        call int_getarg( 2, 1, huge(nchunks), nchunks )
        call int_getarg( 3, 1, huge(nx), nx )
        call int_getarg( 4, 1, huge(nz), nz )
        call int_getarg( 5, 1, huge(ng), ng )
        call real_getarg( 6, tiny(dt), huge(dt), dt )
        call real_getarg( 7, tiny(dx), huge(dx), dx )
        call real_getarg( 8, tiny(dz), huge(dz), dz )
        firstx = 0.
        firstz = 0.
        if (iargc() == 10) then
            call real_getarg(  9, 0., huge(firstx), firstx )
            call real_getarg( 10, 0., huge(firstz), firstz )
        end if
        call set_database( basefn, nchunks, nx,nz,ng, dt,dx,dz, firstx, firstz )
    else
        call set_database( basefn )
    end if
    
    iline = 1
    line_loop : do
        call readline( addentry, iostat, ok )
        if (iostat == IOSTAT_EOF) exit line_loop
        if (.not. ok) call die( "gfdb_build: reading line "// iline &
                                 //" from standard input failed." )        
        iline = iline+1
    end do line_loop    
    
    call close_database()

    call cleanup()
    
end program