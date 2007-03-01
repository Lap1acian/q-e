!
! Copyright (C) 2001-2005 Quantum-ESPRESSO group
! This file is distributed under the terms of the
! GNU General Public License. See the file `License'
! in the root directory of the present distribution,
! or http://www.gnu.org/copyleft/gpl.txt .
!
!-----------------------------------------------------------------------
PROGRAM phonon
  !-----------------------------------------------------------------------
  !
  ! ... This is the main driver of the phonon program. It controls
  ! ... the initialization routines and the self-consistent cycle.
  ! ... At the end of the self-consistent run the dynamical matrix is
  ! ... computed. In the case q=0 the dielectric constant and the effective
  ! ... charges are computed.
  !
  USE kinds,           ONLY : DP
  USE io_global,       ONLY : stdout, ionode, ionode_id
  USE wvfct,           ONLY : gamma_only
  USE klist,           ONLY : xk, wk, xqq, lgauss, nks, nkstot,            &
                              tot_magnetization,                           &
                              multiplicity, nelup, neldw, tot_charge,      &
                              two_fermi_energies
  USE relax,           ONLY : restart_bfgs
  USE basis,           ONLY : startingwfc, startingpot, startingconfig
  USE force_mod,       ONLY : force
  USE io_files,        ONLY : prefix, tmp_dir, nd_nmbr, delete_if_present
  USE mp,              ONLY : mp_bcast
  USE ions_base,       ONLY : nat
  USE lsda_mod,        ONLY : nspin
  USE noncollin_module, ONLY : noncolin
  USE gvect,           ONLY : nrx1, nrx2, nrx3
  USE control_flags,   ONLY : restart, lphonon, tr2, ethr, imix, nmix,  &
                              mixing_beta, lscf, lbands, david, isolve
  USE qpoint,          ONLY : xq, nksq
  USE disp,            ONLY : nqs, x_q
  USE control_ph,      ONLY : ldisp, lnscf, lgamma, lgamma_gamma, convt, &
                              epsil, trans, elph, zue, recover, maxirr, irr0, &
                              lnoloc, lrpa
  USE freq_ph
  USE output,          ONLY : fildyn, fildrho
  USE global_version,  ONLY : version_number
  USE ramanm,          ONLY : lraman, elop
  USE check_stop,      ONLY : check_stop_init
  !
  IMPLICIT NONE
  !
  INTEGER :: iq, iq_start, iustat, ierr, iu
  INTEGER :: nks_start
    ! number of initial k points
  REAL(DP), ALLOCATABLE :: wk_start(:)
    ! initial weight of k points
  REAL(DP), ALLOCATABLE :: xk_start(:,:)
    ! initial coordinates of k points
  LOGICAL :: exst
  CHARACTER (LEN=9)   :: code = 'PHONON'
  CHARACTER (LEN=256) :: auxdyn, filname, filint
  CHARACTER(LEN=6), EXTERNAL :: int_to_char
  !
  !
  CALL init_clocks( .TRUE. )
  !
  CALL start_clock( 'PHONON' )
  !
  gamma_only = .FALSE.
  !
  CALL startup( nd_nmbr, code, version_number )
  !
  WRITE( stdout, '(/5x,"Ultrasoft (Vanderbilt) Pseudopotentials")' )
  !
  ! ... and begin with the initialization part
  !
  CALL phq_readin()
  !
  CALL check_stop_init()
  !
  ! ... Checking the status of the calculation
  !
  iustat = 98
  !
  IF ( ionode ) THEN
     !
     CALL seqopn( iustat, 'stat', 'FORMATTED', exst )
     !
     IF ( exst ) THEN
        !
        READ( UNIT = iustat, FMT = *, IOSTAT = ierr ) iq_start
        !
        IF ( ierr /= 0 ) THEN
           !
           iq_start = 1
           !
        ELSE IF ( iq_start > 0 ) THEN
           !
           WRITE( UNIT = stdout, FMT = "(/,5X,'starting from an old run')")
           !
           WRITE( UNIT = stdout, &
                  FMT = "(5X,'Doing now the calculation ', &
                           & 'for q point nr ',I3)" ) iq_start
           !
        ELSE
           !
           iq_start = 1          
           !   
        END IF
        !
     ELSE
        !
        iq_start = 1
        !
     END IF
     !
     CLOSE( UNIT = iustat, STATUS = 'KEEP' )
     !
  END IF
  !   
  CALL mp_bcast( iq_start, ionode_id )
  !
  IF ( ldisp ) THEN
     !
     ! ... Calculate the q-points for the dispersion
     !
     CALL q_points()
     !
     ! ... Store the name of the matdyn file in auxdyn
     !
     auxdyn = fildyn
     !
     ! ... Save the starting k points 
     !
     nks_start = nkstot
     !
     IF ( .NOT. ALLOCATED( xk_start ) ) ALLOCATE( xk_start( 3, nks_start ) )
     IF ( .NOT. ALLOCATED( wk_start ) ) ALLOCATE( wk_start( nks_start ) )
     !
#ifdef __PARA
     CALL xk_wk_collect( xk_start, wk_start, xk, wk, nkstot, nks )
#else
     xk_start(:,1:nks_start) = xk(:,1:nks_start)
     wk_start(1:nks_start)   = wk(1:nks_start)
#endif
     !
     ! ... do always a non-scf calculation
     !
     lnscf = .TRUE.
     !
  ELSE IF ( lnscf ) THEN
     !
     ! ... xqq is the q-point for   phonon calculation (read from input)
     ! ... xq  is the q-point for the nscf calculation (read from data file)
     ! ... if the nscf calculation is to be performed, discard the latter
     !
     xqq = xq
     nqs = 1
     !
  ELSE
     !
     nqs = 1
     !
  END IF
  !
  IF ( lnscf ) CALL start_clock( 'PWSCF' )
  !
  DO iq = iq_start, nqs
     !
     IF ( ionode ) THEN
        !
        CALL seqopn( iustat, 'stat', 'FORMATTED', exst )
        !
        REWIND( iustat )
        !
        WRITE( iustat, * ) iq
        !
        CLOSE( UNIT = iustat, STATUS = 'KEEP' )
        !
     END IF
     !
     IF ( ldisp ) THEN
        !
        ! ... set the name for the output file
        !
        fildyn = TRIM( auxdyn ) // TRIM( int_to_char( iq ) )
        !
        ! ... set the q point
        !
        xqq(1:3) = x_q(1:3,iq)
        xq(1:3)  = x_q(1:3,iq)
        !
        lgamma = ( xqq(1) == 0.D0 .AND. xqq(2) == 0.D0 .AND. xqq(3) == 0.D0 )
        !
        ! ... in the case of an insulator one has to calculate 
        ! ... the dielectric constant and the Born eff. charges
        !
        IF ( lgamma .AND. .NOT. lgauss ) THEN
           !
           epsil = .TRUE.
           zue   = .TRUE.
           !
        END IF
        !
        ! ... for q != 0 no calculation of the dielectric tensor 
        ! ...           and Born eff. charges
        !
        IF ( .NOT. lgamma ) THEN
           !
           epsil = .FALSE.
           zue   = .FALSE.
           !
        END IF
        !
        CALL mp_bcast( epsil,  ionode_id )
        CALL mp_bcast( zue,    ionode_id )
        CALL mp_bcast( lgamma, ionode_id )
        !
        IF (.NOT. lgamma ) THEN
           !
           nkstot = nks_start
           xk(:,1:nks_start) = xk_start(:,1:nks_start)
           wk(1:nks_start)   = wk_start(1:nks_start)
        END IF
        !
     END IF
     !
     ! ... In the case of q != 0, we make first an non selfconsistent run
     !
     IF ( lnscf .AND. .NOT. lgamma ) THEN
        !
        WRITE( stdout, '(/,5X,"Calculation of q = ",3F8.4)') xqq
        !
        CALL clean_pw( .FALSE. )
        !
        CALL close_files()
        !
        ! ... Setting the values for the nscf run
        !
        lphonon           = .TRUE.
        lscf              = .FALSE.
        lbands            = .FALSE.
        restart           = .FALSE.
        restart_bfgs      = .FALSE.
        startingconfig    = 'input'
        startingpot       = 'file'
        startingwfc       = 'atomic'
        tot_magnetization = -1
        nelup             = 0.d0
        neldw             = 0.d0
        tot_charge        = 0.d0
        multiplicity      = 0
        two_fermi_energies= .FALSE.
        !
        ! ... the threshold for diagonalization ethr is calculated via
        ! ... the threshold on self-consistency tr2 - the value used
        ! ... here should be good enough for all cases
        !
        tr2 = 1.D-8
        ethr = 0.d0
        mixing_beta = 0.d0
        imix = 0
        nmix = 0
        !
        ! ... Assume davidson diagonalization
        !
        isolve = 0
        david = 4
        !
        IF ( .NOT. ALLOCATED( force ) ) ALLOCATE( force( 3, nat ) )
        !
        CALL init_run()
        !
        CALL electrons()
        !
        CALL close_files()
        !
     END IF
     !
     ! ... Setting nksq
     !
     IF ( lgamma ) THEN
        !
        nksq = nks
        !
     ELSE
        !
        nksq = nks / 2
        !
     END IF
     !
     ! ... Calculation of the dispersion: do all modes 
     !
     maxirr = 0
     !
     CALL allocate_phq()
     CALL phq_setup()
     CALL phq_recover()
     CALL phq_summary()
     !
     CALL openfilq()
     !
     CALL phq_init()
     !
     CALL print_clock( 'PHONON' )
     !
     IF ( trans .AND. .NOT. recover ) CALL dynmat0()
     !
     IF ( epsil .AND. irr0 <=  0 ) THEN
        !
        IF (noncolin) CALL errore('phonon','epsil and noncolin not programed',1)
        IF (fpol) THEN    ! calculate freq. dependent polarizability
           !
           WRITE( stdout, '(/,5X,"Frequency Dependent Polarizability Calculation",/)' )
           !
           iu = nfs
           !
           freq_loop : DO WHILE ( iu .gt. 0)
              !
              CALL solve_e_fpol( fiu(iu) )
              IF ( convt ) CALL polariz ( fiu(iu) )
              iu = iu - 1
              !
           END DO freq_loop
           !
           WRITE( stdout, '(/,5X,"End of Frequency Dependent Polarizability Calculation")' )
           !
        ENDIF
        !
        WRITE( stdout, '(/,5X,"Electric Fields Calculation")' )
        !
        CALL solve_e()
        !
        WRITE( stdout, '(/,5X,"End of electric fields calculation")' )
        !
        IF ( convt ) THEN
           !
           ! ... calculate the dielectric tensor epsilon
           !
           CALL dielec()
           !
           ! ... calculate the effective charges Z(E,Us) (E=scf,Us=bare)
           !
           IF (.NOT.(lrpa.OR.lnoloc).AND..NOT.noncolin) CALL zstar_eu()
           !
           IF ( fildrho /= ' ' ) CALL punch_plot_e()
           !
        ELSE
           !
           CALL stop_ph( .FALSE. )
           !
        END IF
        !
        IF (( lraman .OR. elop ).AND..NOT.noncolin) CALL raman()
        !
     END IF
     !
     IF ( trans ) THEN
        !
        CALL phqscf()
        CALL dynmatrix()
        !
        IF ( fildrho /= ' ' ) CALL punch_plot_ph()
        !
     END IF
     !
     IF ( elph ) THEN
        !
        IF (noncolin) CALL errore('phonon','e-ph and noncolin not programed',1)
        IF ( .NOT. trans ) THEN
           ! 
           CALL dvanqq()
           CALL elphon()
           !
        END IF
        !
        CALL elphsum()
        !
     END IF
     !
     ! ... cleanup of the variables
     !
     CALL clean_pw( .FALSE. )
     CALL deallocate_phq()
     !
     ! ... Close the files
     !
     CALL close_phq( .TRUE. )
     !
  END DO
  !
  IF ( ionode ) CALL delete_if_present( TRIM(tmp_dir)//TRIM(prefix)//".stat" )
  !
  IF ( ALLOCATED( xk_start ) ) DEALLOCATE( xk_start )
  IF ( ALLOCATED( wk_start ) ) DEALLOCATE( wk_start )
  !
  IF ( lnscf ) CALL print_clock_pw()
  !
  CALL stop_ph( .TRUE. )
  !
  STOP
  !
END PROGRAM phonon
