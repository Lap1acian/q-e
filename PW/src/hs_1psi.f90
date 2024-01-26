!
! Copyright (C) 2001 PWSCF group
! This file is distributed under the terms of the
! GNU General Public License. See the file `License'
! in the root directory of the present distribution,
! or http://www.gnu.org/copyleft/gpl.txt .
!
!----------------------------------------------------------------------------
SUBROUTINE hs_1psi( lda, n, psi, hpsi, spsi )
  !----------------------------------------------------------------------------
  !! This routine applies the Hamiltonian and the S matrix
  !! to a vector psi and puts the result in hpsi and spsi.  
  !! Wrapper routine - calls h_psi and s_psi.
  !
  ! ... No bgrp parallelization here !
  !
  USE kinds,            ONLY : DP
  USE control_flags,    ONLY : gamma_only
  USE bp,               ONLY : lelfield
  USE noncollin_module, ONLY : npol 
  USE realus,           ONLY : real_space, &
                               invfft_orbital_gamma, fwfft_orbital_gamma, s_psir_gamma, &
                               invfft_orbital_k,     fwfft_orbital_k,     s_psir_k
  !
  IMPLICIT NONE
  !
  INTEGER, INTENT(IN) :: lda, n
  COMPLEX(DP) :: psi(lda*npol,1), hpsi(lda*npol), spsi(n,1)
  !
  !
  CALL start_clock( 'hs_1psi' )
  !
#if defined(__OPENMP_GPU)
  !$omp target data map(alloc:psi,hpsi)
#endif
  !
  !OBM: I know this form is somewhat inelegant but, leaving the pre-real_space part intact
  !     makes it easier to debug probable errors, please do not "beautify" 
        if (real_space) then
           !$omp target update to(psi,hpsi)
           CALL h_psi( lda, n, 1, psi, hpsi )
           !$omp target update from(hpsi)
           if (gamma_only) then
             call invfft_orbital_gamma(psi,1,1) !transform the orbital to real space
             call s_psir_gamma(1,1)
             call fwfft_orbital_gamma(spsi,1,1)
           else
             call invfft_orbital_k(psi,1,1) !transform the orbital to real space
             call s_psir_k(1,1)
             call fwfft_orbital_k(spsi,1,1)
           end if
        else
#if defined(__OPENMP_GPU)
  !$omp target update to(psi,hpsi)
#endif
  CALL h_psi( lda, n, 1, psi, hpsi ) ! apply H to a single wfc (no bgrp parallelization here)
#if defined(__OPENMP_GPU)
  !$omp target update from(hpsi)
#endif
  CALL s_psi( lda, n, 1, psi, spsi ) ! apply S to a single wfc (no bgrp parallelization here)
       endif
  !
#if defined(__OPENMP_GPU)
  !$omp end target data
#endif
  !
  CALL stop_clock( 'hs_1psi' )
  !
  RETURN
  !
END SUBROUTINE hs_1psi
