!
! Copyright (C) Quantum ESPRESSO group
!
! This file is distributed under the terms of the
! GNU General Public License. See the file `License'
! in the root directory of the present distribution,
! or http://www.gnu.org/copyleft/gpl.txt .
!
!----------------------------------------------------------------------
! FFT base Module.
! Written by Carlo Cavazzoni, modified by Paolo Giannozzi
!----------------------------------------------------------------------
!
#ifdef __CUDA
!=----------------------------------------------------------------------=!
   MODULE fft_scatter_2d_gpu
!=----------------------------------------------------------------------=!

        USE fft_types, ONLY: fft_type_descriptor
        USE fft_param

        USE cudafor

        IMPLICIT NONE

        SAVE

        PRIVATE

        PUBLIC :: fft_scatter_gpu, fft_scatter_gpu_batch
        PUBLIC :: fft_scatter_many_columns_to_planes_send, &
                  fft_scatter_many_columns_to_planes_store, &
                  fft_scatter_many_planes_to_columns_send, &
                  fft_scatter_many_planes_to_columns_store

!=----------------------------------------------------------------------=!
      CONTAINS
!=----------------------------------------------------------------------=!

!----------------------------------------------------------------------------
SUBROUTINE fft_scatter_gpu ( dfft, f_in_d, f_in, nr3x, nxx_, f_aux_d, f_aux, ncp_, npp_, isgn )
  !
  USE cudafor
  IMPLICIT NONE
  !
  TYPE (fft_type_descriptor), TARGET, INTENT(in) :: dfft
  INTEGER, INTENT(in)           :: nr3x, nxx_, isgn, ncp_ (:), npp_ (:)
  COMPLEX (DP), DEVICE, INTENT(inout)   :: f_in_d (nxx_), f_aux_d (nxx_)
  COMPLEX (DP), INTENT(inout)   :: f_in (nxx_), f_aux (nxx_)
  INTEGER :: cuf_i, cuf_j, nswip
  INTEGER :: istat
  INTEGER, POINTER, DEVICE :: p_ismap_d(:)
#if defined(__MPI)

  INTEGER :: srh(2*dfft%nproc)
  INTEGER :: k, offset, proc, ierr, me, nprocp, gproc, gcomm, i, kdest, kfrom
  INTEGER :: me_p, nppx, mc, j, npp, nnp, ii, it, ip, ioff, sendsiz, ncpx, ipp, nblk, nsiz
  !
  INTEGER :: iter, dest, sorc
  INTEGER :: istatus(MPI_STATUS_SIZE)

  p_ismap_d => dfft%ismap_d
  !
  me     = dfft%mype + 1
  !
  nprocp = dfft%nproc
  !
  istat = cudaDeviceSynchronize()
  !
  ncpx = maxval(ncp_)
  nppx = maxval(npp_)

  ! This should never happend and should be removed: when the FFT of
  ! data not spread on multiple MPI processes should be performed by
  ! calling the scalar driver directly. It is still possible for debuggning
  ! purposes to call the parallel driver on local data.
  !
  IF ( dfft%nproc == 1 ) THEN
     nppx = dfft%nr3x
  END IF
  sendsiz = ncpx * nppx
  !

  ierr = 0
  IF (isgn.gt.0) THEN

     IF (nprocp==1) GO TO 10
     !
     ! "forward" scatter from columns to planes
     !
     ! step one: store contiguously the slices
     !
     offset = 0
     !f_aux = (0.d0, 0.d0)

     DO gproc = 1, nprocp
        !
        kdest = ( gproc - 1 ) * sendsiz
        kfrom = offset
        !
#ifdef __GPU_MPI

!$cuf kernel do(2) <<<*,*>>>
        DO k = 1, ncp_ (me)
           DO i = 1, npp_ ( gproc )
             f_aux_d( kdest + i + (k-1)*nppx ) = f_in_d( kfrom + i + (k-1)*nr3x )
           END DO
        END DO

#else
        istat = cudaMemcpy2D( f_aux(kdest + 1), nppx, f_in_d(kfrom + 1 ), nr3x, npp_(gproc), ncp_(me), cudaMemcpyDeviceToHost )
        if( istat ) CALL fftx_error__("fft_scatter", "ERROR cudaMemcpy2D failed : ", istat)
#endif

        offset = offset + npp_ ( gproc )
     ENDDO
     !
     ! maybe useless; ensures that no garbage is present in the output
     !
     !! f_in = 0.0_DP
     !
     ! step two: communication
     !
     gcomm = dfft%comm

     CALL start_clock ('a2a_fw')
#ifdef __GPU_MPI

     istat = cudaDeviceSynchronize()
     DO iter = 2, nprocp
        IF(IAND(nprocp, nprocp-1) == 0) THEN
          sorc = IEOR( me-1, iter-1 )
        ELSE
          sorc = MOD(me-1 - (iter-1) + nprocp, nprocp)
        ENDIF

        call MPI_IRECV( f_in_d((sorc)*sendsiz + 1), sendsiz, MPI_DOUBLE_COMPLEX, sorc, 0, gcomm, srh(iter-1), ierr )

     ENDDO

     DO iter = 2, nprocp
        IF(IAND(nprocp, nprocp-1) == 0) THEN
          dest = IEOR( me-1, iter-1 )
        ELSE
          dest = MOD(me-1 + (iter-1), nprocp)
        ENDIF

        call MPI_ISEND( f_aux_d((dest)*sendsiz + 1), sendsiz, MPI_DOUBLE_COMPLEX, dest, 0, gcomm, srh(iter+nprocp-2), ierr )

     ENDDO

     istat = cudaMemcpyAsync( f_in_d( (me-1)*sendsiz + 1), f_aux_d((me-1)*sendsiz + 1), sendsiz, stream=dfft%a2a_comp )

     call MPI_WAITALL(2*nprocp-2, srh, MPI_STATUSES_IGNORE, ierr)
     istat = cudaDeviceSynchronize()
#else
     CALL mpi_alltoall (f_aux(1), sendsiz, MPI_DOUBLE_COMPLEX, f_in(1), sendsiz, MPI_DOUBLE_COMPLEX, gcomm, ierr)
#endif
     CALL stop_clock ('a2a_fw')

     IF( abs(ierr) /= 0 ) CALL fftx_error__ ('fft_scatter', 'info<>0', abs(ierr) )

#ifndef __GPU_MPI
     f_in_d(1:sendsiz*dfft%nproc) = f_in(1:sendsiz*dfft%nproc)
#endif

     !
10   CONTINUE

     !f_aux_d = (0.d0, 0.d0)
     !$cuf kernel do (1) <<<*,*>>>
     do i = lbound(f_aux_d,1), ubound(f_aux_d,1)
       f_aux_d(i) = (0.d0, 0.d0)
     end do

     IF( isgn == 1 ) THEN

        npp = dfft%nr3p( me )
        nnp = dfft%nnp

        DO ip = 1, dfft%nproc
           ioff = dfft%iss( ip )
           nswip = dfft%nsp( ip )
!$cuf kernel do(2) <<<*,*>>>
           DO cuf_j = 1, npp
              DO cuf_i = 1, nswip
                 it = ( ip - 1 ) * sendsiz + (cuf_i-1)*nppx
                 mc = p_ismap_d( cuf_i + ioff )
                 f_aux_d( mc + ( cuf_j - 1 ) * nnp ) = f_in_d( cuf_j + it )
              ENDDO
           ENDDO
        ENDDO
     ELSE

        npp  = dfft%nr3p( me )
        nnp  = dfft%nnp
        !
        ip = 1
        !
        DO gproc = 1, dfft%nproc
           !
           ioff = dfft%iss( ip )
           nswip =  dfft%nsw( ip )
           !
!$cuf kernel do(2) <<<*,*>>>
           DO cuf_j = 1, npp
              DO cuf_i = 1, nswip
                 !
                 mc = p_ismap_d( cuf_i + ioff )
                 !
                 it = (cuf_i-1) * nppx + ( gproc - 1 ) * sendsiz
                 !
                 f_aux_d( mc + ( cuf_j - 1 ) * nnp ) = f_in_d( cuf_j + it )
                 !
              ENDDO
              !
           ENDDO
           !
           ip = ip + 1
           !
        ENDDO
     END IF
  ELSE
     !
     !  "backward" scatter from planes to columns
     !
     IF( isgn == -1 ) THEN

        npp = dfft%nr3p( me )
        nnp = dfft%nnp

        DO ip = 1, dfft%nproc
           ioff = dfft%iss( ip )
           nswip = dfft%nsp( ip )
!$cuf kernel do(2) <<<*,*>>>
           DO cuf_j = 1, npp
              DO cuf_i = 1, nswip
                 mc = p_ismap_d( cuf_i + ioff )
                 it = ( ip - 1 ) * sendsiz + (cuf_i-1)*nppx
                 f_in_d( cuf_j + it ) = f_aux_d( mc + ( cuf_j - 1 ) * nnp )
              ENDDO
           ENDDO

        ENDDO
     ELSE
        !
        npp  = dfft%nr3p( me )
        nnp  = dfft%nnp
        !
        DO gproc = 1, dfft%nproc
           !
           ioff = dfft%iss( gproc )
           !
           nswip = dfft%nsw( gproc )
           !
!$cuf kernel do(2) <<<*,*>>>
           DO cuf_j = 1, npp
              DO cuf_i = 1, nswip
                 !
                 mc = p_ismap_d( cuf_i + ioff )
                 !
                 it = (cuf_i-1) * nppx + ( gproc - 1 ) * sendsiz
                 !
                 f_in_d( cuf_j + it ) = f_aux_d( mc + ( cuf_j - 1 ) * nnp )
              ENDDO
              !
           ENDDO
           !
        ENDDO
        !
     END IF
     !
     IF( nprocp == 1 ) GO TO 20
     !
     !  step two: communication
     !
     gcomm = dfft%comm
     !
#ifndef __GPU_MPI
     f_in(1:sendsiz*dfft%nproc) = f_in_d(1:sendsiz*dfft%nproc)
#endif
     !
     ! CALL mpi_barrier (gcomm, ierr)  ! why barrier? for buggy openmpi over ib
     CALL start_clock ('a2a_bw')
#ifdef __GPU_MPI

     istat = cudaDeviceSynchronize()
     DO iter = 2, nprocp
        IF(IAND(nprocp, nprocp-1) == 0) THEN
          sorc = IEOR( me-1, iter-1 )
        ELSE
          sorc = MOD(me-1 - (iter-1) + nprocp, nprocp)
        ENDIF

        call MPI_IRECV( f_aux_d((sorc)*sendsiz + 1), sendsiz, MPI_DOUBLE_COMPLEX, sorc, 0, gcomm, srh(iter-1), ierr )

     ENDDO

     DO iter = 2, nprocp
        IF(IAND(nprocp, nprocp-1) == 0) THEN
          dest = IEOR( me-1, iter-1 )
        ELSE
          dest = MOD(me-1 + (iter-1), nprocp)
        ENDIF

        call MPI_ISEND( f_in_d((dest)*sendsiz + 1), sendsiz, MPI_DOUBLE_COMPLEX, dest, 0, gcomm, srh(iter+nprocp-2), ierr )

     ENDDO

     istat = cudaMemcpyAsync( f_aux_d( (me-1)*sendsiz + 1), f_in_d((me-1)*sendsiz + 1), sendsiz, stream=dfft%a2a_comp )

     call MPI_WAITALL(2*nprocp-2, srh, MPI_STATUSES_IGNORE, ierr)
     istat = cudaDeviceSynchronize()
#else
     CALL mpi_alltoall (f_in(1), sendsiz, MPI_DOUBLE_COMPLEX, f_aux(1), sendsiz, MPI_DOUBLE_COMPLEX, gcomm, ierr)
#endif
     CALL stop_clock ('a2a_bw')
     IF( abs(ierr) /= 0 ) CALL fftx_error__ ('fft_scatter', 'info<>0', abs(ierr) )
     !
     !  step one: store contiguously the columns
     !
     !! f_in = 0.0_DP
     !
     offset = 0

     DO gproc = 1, nprocp
        !
        kdest = ( gproc - 1 ) * sendsiz
        kfrom = offset
        !
#ifdef __GPU_MPI

!$cuf kernel do(2) <<<*,*>>>
        DO k = 1, ncp_ (me)
           DO i = 1, npp_ ( gproc )
             f_in_d( kfrom + i + (k-1)*nr3x ) = f_aux_d( kdest + i + (k-1)*nppx )
           END DO
        END DO

#else
        istat = cudaMemcpy2D( f_in_d(kfrom +1 ), nr3x, f_aux(kdest + 1), nppx, npp_(gproc), ncp_(me), cudaMemcpyHostToDevice )
#endif
        offset = offset + npp_ ( gproc )
     ENDDO

20   CONTINUE

  ENDIF

  istat = cudaDeviceSynchronize()

#endif

  RETURN

END SUBROUTINE fft_scatter_gpu

SUBROUTINE fft_scatter_gpu_batch ( dfft, f_in_d, f_in, nr3x, nxx_, f_aux_d, f_aux, ncp_, npp_, isgn, batchsize, srh )
  !
  ! This subroutine performs the same task as fft_scatter_gpu, but for
  ! batchsize wavefuctions or densities.
  !
  USE cudafor
  IMPLICIT NONE
  !
  TYPE (fft_type_descriptor), TARGET, INTENT(in) :: dfft
  INTEGER, INTENT(in)           :: nr3x, nxx_, isgn, ncp_ (:), npp_ (:)
  COMPLEX (DP), DEVICE, INTENT(inout)   :: f_in_d (batchsize * nxx_), f_aux_d (batchsize * nxx_)
  COMPLEX (DP), INTENT(inout)   :: f_in (batchsize * nxx_), f_aux (batchsize * nxx_)
  INTEGER, INTENT(IN) :: batchsize
  INTEGER, INTENT(INOUT) :: srh(2*dfft%nproc)
  INTEGER :: cuf_i, cuf_j, nswip
  INTEGER :: istat
  INTEGER, POINTER, DEVICE :: p_ismap_d(:)
#if defined(__MPI)

  INTEGER :: k, offset, proc, ierr, me, nprocp, gproc, gcomm, i, kdest, kfrom
  INTEGER :: me_p, nppx, mc, j, npp, nnp, nnr, ii, it, ip, ioff, sendsiz, ncpx, ipp, nblk, nsiz
  !
  INTEGER :: iter, dest, sorc
  INTEGER :: istatus(MPI_STATUS_SIZE)
  !
  !
  p_ismap_d => dfft%ismap_d
  !
  me     = dfft%mype + 1
  !
  nprocp = dfft%nproc
  !
  istat = cudaDeviceSynchronize()
  !
  ncpx = maxval(ncp_)
  nppx = maxval(npp_)
  !
  ! This should never happend and should be removed: when the FFT of
  ! data not spread on multiple MPI processes should be performed by
  ! calling the scalar driver directly. It is still possible for debuggning
  ! purposes to call the parallel driver on local data.
  IF ( dfft%nproc == 1 ) THEN
     nppx = dfft%nr3x
  END IF
  !
  sendsiz = batchsize * ncpx * nppx
  nnr     = dfft%nnr
  !
  ierr = 0
  IF (isgn.gt.0) THEN

     IF (nprocp==1) GO TO 10
     !
     ! "forward" scatter from columns to planes
     !
     ! step one: store contiguously the slices
     !
     offset = 0

     DO gproc = 1, nprocp
        !
        kdest = ( gproc - 1 ) * sendsiz
        kfrom = offset
        !
#ifdef __GPU_MPI
        !
!$cuf kernel do(2) <<<*,*>>>
        DO k = 1, batchsize * ncpx
           DO i = 1, npp_ ( gproc )
             f_aux_d( kdest + i + (k-1)*nppx ) = f_in_d( kfrom + i + (k-1)*nr3x )
           END DO
        END DO
        !
#else
        istat = cudaMemcpy2D( f_aux(kdest + 1), nppx, f_in_d(kfrom + 1 ), nr3x, npp_(gproc), batchsize * ncpx, cudaMemcpyDeviceToHost )
        IF( istat /= cudaSuccess ) CALL fftx_error__ ('fft_scatter', 'cudaMemcpy2D failed: ', istat)
#endif
        !
        offset = offset + npp_ ( gproc )
     ENDDO
     !
     ! maybe useless; ensures that no garbage is present in the output
     !
     !! f_in = 0.0_DP
     !
     ! step two: communication
     !
     gcomm = dfft%comm

     CALL start_clock ('a2a_fw')

     istat = cudaDeviceSynchronize()
     ! Here the data are sent to all processors involved in the FFT.
     ! We avoid sending the block of data to be transposed that we already own.
     DO iter = 2, nprocp
        IF(IAND(nprocp, nprocp-1) == 0) THEN
          sorc = IEOR( me-1, iter-1 )
        ELSE
          sorc = MOD(me-1 - (iter-1) + nprocp, nprocp)
        ENDIF

#ifdef __GPU_MPI
        CALL MPI_IRECV( f_in_d((sorc)*sendsiz + 1), sendsiz, MPI_DOUBLE_COMPLEX, sorc, 0, gcomm, srh(iter-1), ierr )
#else
        CALL MPI_IRECV( f_in((sorc)*sendsiz + 1), sendsiz, MPI_DOUBLE_COMPLEX, sorc, 0, gcomm, srh(iter-1), ierr )
#endif

     ENDDO

     DO iter = 2, nprocp
        IF(IAND(nprocp, nprocp-1) == 0) THEN
          dest = IEOR( me-1, iter-1 )
        ELSE
          dest = MOD(me-1 + (iter-1), nprocp)
        ENDIF

#ifdef __GPU_MPI
        CALL MPI_ISEND( f_aux_d((dest)*sendsiz + 1), sendsiz, MPI_DOUBLE_COMPLEX, dest, 0, gcomm, srh(iter+nprocp-2), ierr )
#else
        CALL MPI_ISEND( f_aux((dest)*sendsiz + 1), sendsiz, MPI_DOUBLE_COMPLEX, dest, 0, gcomm, srh(iter+nprocp-2), ierr )
#endif

     ENDDO
     !
     ! here we move to f_in the portion that we did not send (was already in our hands)
     ! this copy is overlapped with communication that is taking place at the same time
     ! and is eventually completed...
#ifdef __GPU_MPI
     istat = cudaMemcpyAsync( f_in_d( (me-1)*sendsiz + 1), f_aux_d((me-1)*sendsiz + 1), sendsiz, stream=dfft%a2a_comp )
     IF( istat /= cudaSuccess ) CALL fftx_error__ ('fft_scatter', 'cudaMemcpyAsync failed: ', istat)
#else
     f_in((me-1)*sendsiz + 1 : me*sendsiz) = f_aux((me-1)*sendsiz + 1 : me*sendsiz)
#endif
     !
     ! ...here, where we wait for it to finish.
     CALL MPI_WAITALL(2*nprocp-2, srh, MPI_STATUSES_IGNORE, ierr)
     IF( abs(ierr) /= 0 ) CALL fftx_error__ ('fft_scatter', 'MPI_WAITALL info<>0', abs(ierr) )
     istat = cudaDeviceSynchronize()

     CALL stop_clock ('a2a_fw')

#ifndef __GPU_MPI
     f_in_d(1:sendsiz*dfft%nproc) = f_in(1:sendsiz*dfft%nproc)
#endif

     !
10   CONTINUE

     ! Zero out f_aux_d
     !$cuf kernel do (1) <<<*,*>>>
     DO i = lbound(f_aux_d,1), ubound(f_aux_d,1)
       f_aux_d(i) = (0.d0, 0.d0)
     END DO

     IF( isgn == 1 ) THEN

        npp = dfft%nr3p( me )
        nnp = dfft%nnp

        DO ip = 1, dfft%nproc
           ioff = dfft%iss( ip )
           nswip = dfft%nsp( ip )
!$cuf kernel do(2) <<<*,*>>>
           DO cuf_j = 1, npp
              DO cuf_i = 1, nswip
                 it = ( ip - 1 ) * sendsiz + (cuf_i-1)*nppx
                 mc = p_ismap_d( cuf_i + ioff )
                 f_aux_d( mc + ( cuf_j - 1 ) * nnp ) = f_in_d( cuf_j + it )
              ENDDO
           ENDDO
        ENDDO
     ELSE

        npp  = dfft%nr3p( me )
        nnp  = dfft%nnp
        !
        ip = 1
        !
        DO gproc = 1,  dfft%nproc
           !
           ioff = dfft%iss( ip )
           nswip =  dfft%nsw( ip )
           !
!$cuf kernel do(3) <<<*,*>>>
           DO i = 0, batchsize-1
              DO cuf_j = 1, npp
                 DO cuf_i = 1, nswip
                    !
                    mc = p_ismap_d( cuf_i + ioff )
                    !
                    it = (cuf_i-1) * nppx + ( gproc - 1 ) * sendsiz + i*nppx*ncpx
                    !
                    f_aux_d( mc + ( cuf_j - 1 ) * nnp + i*nnr ) = f_in_d( cuf_j + it )
                 ENDDO
                 !
              ENDDO
           ENDDO
           !
           ip = ip + 1
           !
           !
        ENDDO
     END IF
  ELSE
     !
     !  "backward" scatter from planes to columns
     !
     IF( isgn == -1 ) THEN

        npp = dfft%nr3p( me )
        nnp = dfft%nnp

        DO ip = 1, dfft%nproc
           ioff = dfft%iss( ip )
           nswip = dfft%nsp( ip )
!$cuf kernel do(2) <<<*,*>>>
           DO cuf_j = 1, npp
              DO cuf_i = 1, nswip
                 mc = p_ismap_d( cuf_i + ioff )
                 it = ( ip - 1 ) * sendsiz + (cuf_i-1)*nppx
                    f_in_d( cuf_j + it ) = f_aux_d( mc + ( cuf_j - 1 ) * nnp )
              ENDDO
           ENDDO

        ENDDO
     ELSE

        npp  = dfft%nr3p( me )
        nnp  = dfft%nnp
        !
        DO ip = 1, dfft%nproc
           !
           !
           ioff = dfft%iss( ip )
           !
           nswip = dfft%nsw( ip )
!$cuf kernel do(3) <<<*,*>>>
           DO i = 0, batchsize-1
              DO cuf_j = 1, npp
                 DO cuf_i = 1, nswip
                    !
                    mc = p_ismap_d( cuf_i + ioff )
                    !
                    it = (cuf_i-1) * nppx + ( ip - 1 ) * sendsiz + i*nppx*ncpx
                    !
                    f_in_d( cuf_j + it ) = f_aux_d( mc + ( cuf_j - 1 ) * nnp + i*nnr )
                    !
                 ENDDO
                 !
              ENDDO
           ENDDO
           !
        ENDDO
     END IF
     !
     IF( nprocp == 1 ) GO TO 20
     !
     !  step two: communication
     !
     gcomm = dfft%comm

#ifndef __GPU_MPI
     f_in(1:sendsiz*dfft%nproc) = f_in_d(1:sendsiz*dfft%nproc)
#endif

     ! CALL mpi_barrier (gcomm, ierr)  ! why barrier? for buggy openmpi over ib
     CALL start_clock ('a2a_bw')

     istat = cudaDeviceSynchronize()
     DO iter = 2, nprocp
        IF(IAND(nprocp, nprocp-1) == 0) THEN
          sorc = IEOR( me-1, iter-1 )
        ELSE
          sorc = MOD(me-1 - (iter-1) + nprocp, nprocp)
        ENDIF

#ifdef __GPU_MPI
        call MPI_IRECV( f_aux_d((sorc)*sendsiz + 1), sendsiz, MPI_DOUBLE_COMPLEX, sorc, 0, gcomm, srh(iter-1), ierr )
#else
        call MPI_IRECV( f_aux((sorc)*sendsiz + 1), sendsiz, MPI_DOUBLE_COMPLEX, sorc, 0, gcomm, srh(iter-1), ierr )
#endif

     ENDDO

     DO iter = 2, nprocp
        IF(IAND(nprocp, nprocp-1) == 0) THEN
          dest = IEOR( me-1, iter-1 )
        ELSE
          dest = MOD(me-1 + (iter-1), nprocp)
        ENDIF

#ifdef __GPU_MPI
        call MPI_ISEND( f_in_d((dest)*sendsiz + 1), sendsiz, MPI_DOUBLE_COMPLEX, dest, 0, gcomm, srh(iter+nprocp-2), ierr )
#else
        call MPI_ISEND( f_in((dest)*sendsiz + 1), sendsiz, MPI_DOUBLE_COMPLEX, dest, 0, gcomm, srh(iter+nprocp-2), ierr )
#endif

     ENDDO

#ifdef __GPU_MPI
     istat = cudaMemcpyAsync( f_aux_d( (me-1)*sendsiz + 1), f_in_d((me-1)*sendsiz + 1), sendsiz, stream=dfft%a2a_comp )
     if( istat /= cudaSuccess ) CALL fftx_error__ ('fft_scatter', 'cudaMemcpyAsync failed: ', istat)
#else
     f_aux( (me-1)*sendsiz + 1:me*sendsiz) = f_in((me-1)*sendsiz + 1:me*sendsiz)
#endif

     call MPI_WAITALL(2*nprocp-2, srh, MPI_STATUSES_IGNORE, ierr)
     IF( abs(ierr) /= 0 ) CALL fftx_error__ ('fft_scatter', 'MPI_WAITALL info<>0', abs(ierr) )
     istat = cudaDeviceSynchronize()

     CALL stop_clock ('a2a_bw')
     !
     !  step one: store contiguously the columns
     !
     !! f_in = 0.0_DP
     !
     offset = 0

     DO gproc = 1, nprocp
        !
        kdest = ( gproc - 1 ) * sendsiz
        kfrom = offset
        !
#ifdef __GPU_MPI

!$cuf kernel do(2) <<<*,*>>>
        DO k = 1, batchsize * ncpx
           DO i = 1, npp_ ( gproc )
             f_in_d( kfrom + i + (k-1)*nr3x ) = f_aux_d( kdest + i + (k-1)*nppx )
           END DO
        END DO

#else
        istat = cudaMemcpy2D( f_in_d(kfrom +1 ), nr3x, f_aux(kdest + 1), nppx, npp_(gproc), batchsize * ncpx, cudaMemcpyHostToDevice )
        IF( istat /= cudaSuccess ) CALL fftx_error__ ('fft_scatter', 'cudaMemcpy2D failed: ', istat)
#endif
        offset = offset + npp_ ( gproc )
     ENDDO

20   CONTINUE

  ENDIF

  istat = cudaDeviceSynchronize()

#endif

  RETURN

END SUBROUTINE fft_scatter_gpu_batch

SUBROUTINE fft_scatter_many_columns_to_planes_store ( dfft, f_in_d, f_in, nr3x, nxx_, f_aux_d, f_aux, f_aux2_d, f_aux2, ncp_, npp_, isgn, batchsize, batch_id )
   !
   USE cudafor
   IMPLICIT NONE
   !
   TYPE (fft_type_descriptor), TARGET, INTENT(in) :: dfft
   INTEGER, INTENT(in)           :: nr3x, nxx_, isgn, ncp_ (:), npp_ (:)
   COMPLEX (DP), DEVICE, INTENT(inout)   :: f_in_d (batchsize * nxx_), f_aux_d (batchsize * nxx_), f_aux2_d(batchsize * nxx_)
   COMPLEX (DP), INTENT(inout)   :: f_in (batchsize * nxx_), f_aux (batchsize * nxx_), f_aux2(batchsize * nxx_)
   INTEGER, INTENT(IN) :: batchsize, batch_id
   INTEGER :: istat
   INTEGER, POINTER, DEVICE :: p_ismap_d(:)
#if defined(__MPI)
   INTEGER :: k, offset, proc, ierr, me, nprocp, gproc, gcomm, i, kdest, kfrom
   INTEGER :: me_p, nppx, mc, j, npp, nnp, nnr, ii, it, ip, ioff, sendsiz, ncpx, ipp, nblk, nsiz
   !
   INTEGER, ALLOCATABLE, DIMENSION(:) :: offset_proc
   INTEGER :: iter, dest, sorc
   INTEGER :: istatus(MPI_STATUS_SIZE)
   !
   p_ismap_d => dfft%ismap_d
   me     = dfft%mype + 1
   !
   nprocp = dfft%nproc
   !
   !istat = cudaDeviceSynchronize()
   !
#ifdef __IPC
#ifndef __GPU_MPI
  call get_ipc_peers( dfft%IPC_PEER )
#endif
#endif
   !
   ncpx = maxval(ncp_)
   nppx = maxval(npp_)
   !
   IF ( dfft%nproc == 1 ) THEN
      nppx = dfft%nr3x
   END IF
   !
   sendsiz = batchsize * ncpx * nppx
   nnr     = dfft%nnr
   ierr    = 0
   !
   IF (isgn.lt.0) CALL fftx_error__ ('fft_scatter_many_columns_to_planes_store', 'isign is wrong', isgn )
   !
   IF (nprocp==1) GO TO 10
   !
   ! "forward" scatter from columns to planes
   !
   ! step one: store contiguously the slices
   !
   ALLOCATE( offset_proc( nprocp ) )
   offset = 0
   DO proc = 1, nprocp
      offset_proc( proc ) = offset
      offset = offset + npp_ ( proc )
   ENDDO
   !
   DO iter = 2, nprocp
      IF(IAND(nprocp, nprocp-1) == 0) THEN
        dest = IEOR( me-1, iter-1 )
      ELSE
        dest = MOD(me-1 + (iter-1), nprocp)
      ENDIF
      proc = dest + 1
      !
      kdest = ( proc - 1 ) * sendsiz
      kfrom = offset_proc( proc )
      !
#ifdef __GPU_MPI
      istat = cudaMemcpy2DAsync( f_aux_d(kdest + 1), nppx, f_in_d(kfrom + 1 ), nr3x, npp_(proc), batchsize * ncpx,cudaMemcpyDeviceToDevice, dfft%bstreams(batch_id) )
      IF( istat /= cudaSuccess ) CALL fftx_error__ ('fft_scatter_many_columns_to_planes_store', 'cudaMemcpy2DAsync failed : ', istat)
#else
#ifdef __IPC
      IF(dfft%IPC_PEER( dest + 1 ) .eq. 1) THEN
         istat = cudaMemcpy2DAsync( f_aux_d(kdest + 1), nppx, f_in_d(kfrom + 1 ), nr3x, npp_(proc), batchsize * ncpx,cudaMemcpyDeviceToDevice, dfft%bstreams(batch_id) )
         IF( istat /= cudaSuccess ) CALL fftx_error__ ('fft_scatter_many_columns_to_planes_store', 'cudaMemcpy2DAsync failed : ', istat)
      ELSE
         istat = cudaMemcpy2DAsync( f_aux(kdest + 1), nppx, f_in_d(kfrom + 1 ), nr3x, npp_(proc), batchsize * ncpx,cudaMemcpyDeviceToHost, dfft%bstreams(batch_id) )
         IF( istat /= cudaSuccess ) CALL fftx_error__ ('fft_scatter_many_columns_to_planes_store', 'cudaMemcpy2DAsync failed : ', istat)
      ENDIF
#else
      istat = cudaMemcpy2DAsync( f_aux(kdest + 1), nppx, f_in_d(kfrom + 1 ), nr3x, npp_(proc), batchsize * ncpx,cudaMemcpyDeviceToHost, dfft%bstreams(batch_id) )
      IF( istat /= cudaSuccess ) CALL fftx_error__ ('fft_scatter_many_columns_to_planes_store', 'cudaMemcpy2DAsync failed : ', istat)
#endif
#endif
   ENDDO
   !
   istat = cudaEventRecord( dfft%bevents(batch_id), dfft%bstreams(batch_id) )
   DEALLOCATE( offset_proc )
   !
10 CONTINUE

#endif

  RETURN

END SUBROUTINE fft_scatter_many_columns_to_planes_store

SUBROUTINE fft_scatter_many_columns_to_planes_send ( dfft, f_in_d, f_in, nr3x, nxx_, f_aux_d, f_aux, f_aux2_d, f_aux2, ncp_, npp_, isgn, batchsize, batch_id )
   !
   USE cudafor
   IMPLICIT NONE
   !
   TYPE (fft_type_descriptor), TARGET, INTENT(in) :: dfft
   INTEGER, INTENT(in)           :: nr3x, nxx_, isgn, ncp_ (:), npp_ (:)
   COMPLEX (DP), DEVICE, INTENT(inout)   :: f_in_d (batchsize * nxx_), f_aux_d (batchsize * nxx_), f_aux2_d (batchsize * nxx_)
   COMPLEX (DP), INTENT(inout)   :: f_in (batchsize * nxx_), f_aux (batchsize * nxx_), f_aux2(batchsize * nxx_)
   INTEGER, INTENT(IN) :: batchsize, batch_id
   INTEGER :: cuf_i, cuf_j, nswip
   INTEGER :: istat
   INTEGER, POINTER, DEVICE :: p_ismap_d(:)
#if defined(__MPI)
   !
   INTEGER :: k, offset, proc, ierr, me, nprocp, gproc, gcomm, i, kdest, kfrom
   INTEGER :: me_p, nppx, mc, j, npp, nnp, nnr, ii, it, ip, ioff, sendsiz, ncpx, ipp, nblk, nsiz
   !
   INTEGER :: iter, dest, sorc, req_cnt
   INTEGER :: istatus(MPI_STATUS_SIZE)
   !
   p_ismap_d => dfft%ismap_d
   !
   me     = dfft%mype + 1
   !
   nprocp = dfft%nproc
   !
   !istat = cudaDeviceSynchronize()
   !
   ncpx = maxval(ncp_)
   nppx = maxval(npp_)
   !
   IF ( dfft%nproc == 1 ) THEN
      nppx = dfft%nr3x
   END IF
   !
   sendsiz = batchsize * ncpx * nppx
   nnr     = dfft%nnr
#ifdef __IPC
   call get_ipc_peers( dfft%IPC_PEER )
#endif
   !
   ierr = 0
   IF (isgn.lt.0) CALL fftx_error__ ('fft_scatter_many_columns_to_planes_send', 'isign is wrong', isgn )

   IF (nprocp==1) GO TO 10
   ! step two: communication
   !
   gcomm = dfft%comm
   !
   ! JR Note: Holding off staging receives until buffer is packed.
   istat = cudaEventSynchronize( dfft%bevents(batch_id) )
   CALL start_clock ('A2A')
#ifdef __IPC
   !TODO: possibly remove this barrier by ensuring recv buffer is not used by previous operation
   call MPI_Barrier( gcomm, ierr )
#endif
   req_cnt = 0

   DO iter = 2, nprocp
      IF(IAND(nprocp, nprocp-1) == 0) THEN
        sorc = IEOR( me-1, iter-1 )
      ELSE
        sorc = MOD(me-1 - (iter-1) + nprocp, nprocp)
      ENDIF
#ifdef __IPC
      IF(dfft%IPC_PEER( sorc + 1 ) .eq. 0) THEN
#endif
#ifdef __GPU_MPI
         CALL MPI_IRECV( f_aux2_d((sorc)*sendsiz + 1), sendsiz, MPI_DOUBLE_COMPLEX, sorc, 0, gcomm, dfft%srh(req_cnt+1, batch_id), ierr )
#else
         CALL MPI_IRECV( f_aux2((sorc)*sendsiz + 1), sendsiz, MPI_DOUBLE_COMPLEX, sorc, 0, gcomm, dfft%srh(req_cnt+1, batch_id), ierr )
#endif
         req_cnt = req_cnt + 1
#ifdef __IPC
      ENDIF
#endif
   ENDDO

   DO iter = 2, nprocp
      IF(IAND(nprocp, nprocp-1) == 0) THEN
         dest = IEOR( me-1, iter-1 )
      ELSE
         dest = MOD(me-1 + (iter-1), nprocp)
      ENDIF
#ifdef __IPC
      IF(dfft%IPC_PEER( dest + 1 ) .eq. 1) THEN
         CALL ipc_send( f_aux_d((dest)*sendsiz + 1), sendsiz, f_aux2_d((me-1)*sendsiz + 1), 1, dest, gcomm, ierr )
      ELSE
#endif
#ifdef __GPU_MPI
         CALL MPI_ISEND( f_aux_d((dest)*sendsiz + 1), sendsiz, MPI_DOUBLE_COMPLEX, dest, 0, gcomm, dfft%srh(req_cnt+1, batch_id), ierr )
#else
         CALL MPI_ISEND( f_aux((dest)*sendsiz + 1), sendsiz, MPI_DOUBLE_COMPLEX, dest, 0, gcomm, dfft%srh(req_cnt+1, batch_id), ierr )
#endif
         req_cnt = req_cnt + 1
#ifdef __IPC
      ENDIF
#endif
   ENDDO

   offset = 0
   DO proc = 1, me-1
      offset = offset + npp_ ( proc )
   ENDDO
   istat = cudaMemcpy2DAsync( f_aux2_d((me-1)*sendsiz + 1), nppx, f_in_d(offset + 1 ), nr3x, npp_(me), batchsize * ncpx,cudaMemcpyDeviceToDevice, dfft%bstreams(batch_id) )
   IF( istat /= cudaSuccess ) CALL fftx_error__ ('fft_scatter_many_columns_to_planes_store', 'cudaMemcpy2DAsync failed : ', istat)

   IF(req_cnt .gt. 0) THEN
      CALL MPI_WAITALL(req_cnt, dfft%srh(1:req_cnt, batch_id), MPI_STATUSES_IGNORE, ierr)
   ENDIF

#ifdef __IPC
   CALL sync_ipc_sends( gcomm )
   CALL MPI_Barrier( gcomm, ierr )
#endif
   CALL stop_clock ('A2A')

   IF( abs(ierr) /= 0 ) CALL fftx_error__ ('fft_scatter', 'info<>0', abs(ierr) )

#ifndef __GPU_MPI
   DO proc = 1, nprocp
      IF (proc .ne. me) THEN
#ifdef __IPC
         IF(dfft%IPC_PEER( proc ) .eq. 0) THEN
            kdest = ( proc - 1 ) * sendsiz
            istat = cudaMemcpyAsync( f_aux2_d(kdest+1), f_aux2(kdest+1), sendsiz, stream=dfft%bstreams(batch_id) )
         ENDIF
#else
         kdest = ( proc - 1 ) * sendsiz
         istat = cudaMemcpyAsync( f_aux2_d(kdest+1), f_aux2(kdest+1), sendsiz, stream=dfft%bstreams(batch_id) )
#endif
      ENDIF
   ENDDO
#endif
   !
   i = cudaEventRecord(dfft%bevents(batch_id), dfft%bstreams(batch_id))
   i = cudaStreamWaitEvent(dfft%a2a_comp, dfft%bevents(batch_id), 0)
   !
10 CONTINUE
   !
   ! Zero out f_aux_d
   !$cuf kernel do (1) <<<*,*,0,dfft%a2a_comp>>>
   do i = lbound(f_aux_d,1), ubound(f_aux_d,1)
     f_aux_d(i) = (0.d0, 0.d0)
   end do

   IF( isgn == 1 ) THEN

      npp = dfft%nr3p( me )
      nnp = dfft%nnp

      DO ip = 1, nprocp
         ioff = dfft%iss( ip )
         nswip = dfft%nsp( ip )
!$cuf kernel do(3) <<<*,*,0,dfft%a2a_comp>>>
         DO i = 0, batchsize-1
            DO cuf_j = 1, npp
               DO cuf_i = 1, nswip
                  it = ( ip - 1 ) * sendsiz + (cuf_i-1)*nppx + i*nppx*ncpx
                  mc = p_ismap_d( cuf_i + ioff )
                  f_aux_d( mc + ( cuf_j - 1 ) * nnp + i*nnr ) = f_aux2_d( cuf_j + it )
               ENDDO
            ENDDO
         ENDDO
      ENDDO
   ELSE
      !
      npp  = dfft%nr3p( me )
      nnp  = dfft%nnp
      !
      ip = 1
      !
      DO gproc = 1, nprocp
         !
         ioff = dfft%iss( ip )
         nswip =  dfft%nsw( ip )
         !
!$cuf kernel do(3) <<<*,*,0,dfft%a2a_comp>>>
         DO i = 0, batchsize-1
            DO cuf_j = 1, npp
              DO cuf_i = 1, nswip
                 !
                 mc = p_ismap_d( cuf_i + ioff )
                 !
                 it = (cuf_i-1) * nppx + ( gproc - 1 ) * sendsiz + i*nppx*ncpx
                 !
                 f_aux_d( mc + ( cuf_j - 1 ) * nnp + i*nnr ) = f_aux2_d( cuf_j + it )
               ENDDO
                 !
            ENDDO
         ENDDO
         !
         ip = ip + 1
         !
      ENDDO
   END IF

  !istat = cudaDeviceSynchronize()

#endif

  RETURN

END SUBROUTINE fft_scatter_many_columns_to_planes_send

SUBROUTINE fft_scatter_many_planes_to_columns_store ( dfft, f_in_d, f_in, nr3x, nxx_, f_aux_d, f_aux, f_aux2_d, f_aux2, ncp_, npp_, isgn, batchsize, batch_id )
   !
   USE cudafor
   IMPLICIT NONE
   !
   TYPE (fft_type_descriptor), TARGET, INTENT(in) :: dfft
   INTEGER, INTENT(in)           :: nr3x, nxx_, isgn, ncp_ (:), npp_ (:)
   COMPLEX (DP), DEVICE, INTENT(inout)   :: f_in_d (batchsize * nxx_), f_aux_d (batchsize * nxx_), f_aux2_d(batchsize * nxx_)
   COMPLEX (DP), INTENT(inout)   :: f_in (batchsize * nxx_), f_aux (batchsize * nxx_), f_aux2(batchsize * nxx_)
   INTEGER, INTENT(IN) :: batchsize, batch_id
   INTEGER :: cuf_i, cuf_j, nswip
   INTEGER :: istat
   INTEGER, POINTER, DEVICE :: p_ismap_d(:)
#if defined(__MPI)
   INTEGER :: k, offset, proc, ierr, me, nprocp, gproc, gcomm, i, kdest, kfrom
   INTEGER :: me_p, nppx, mc, j, npp, nnp, nnr, ii, it, ip, ioff, sendsiz, ncpx, ipp, nblk, nsiz
   !
   LOGICAL :: use_tg
   INTEGER :: iter, dest, sorc
   INTEGER :: istatus(MPI_STATUS_SIZE)

   p_ismap_d => dfft%ismap_d
   me     = dfft%mype + 1
   !
   nprocp = dfft%nproc
   !
   !istat = cudaDeviceSynchronize()
   !
#ifdef __IPC
#ifndef __GPU_MPI
   CALL get_ipc_peers( dfft%IPC_PEER )
#endif
#endif
   !
   ncpx = maxval(ncp_)
   nppx = maxval(npp_)
   !
   IF ( dfft%nproc == 1 ) THEN
      nppx = dfft%nr3x
   END IF
   !
   sendsiz = batchsize * ncpx * nppx
   nnr     = dfft%nnr
   !
   ierr = 0
   !
   IF (isgn.gt.0) CALL fftx_error__ ('fft_scatter_many_planes_to_columns_store', 'isign is wrong', isgn )
   !
   !
   !  "backward" scatter from planes to columns
   !
   IF( isgn == -1 ) THEN

      npp = dfft%nr3p( me )
      nnp = dfft%nnp

      DO iter = 1, nprocp
         IF(IAND(nprocp, nprocp-1) == 0) THEN
            dest = IEOR( me-1, iter-1 )
         ELSE
            dest = MOD(me-1 + (iter-1), nprocp)
         ENDIF

         ip = dest + 1
         ioff = dfft%iss( ip )
         nswip = dfft%nsp( ip )
!$cuf kernel do(3) <<<*,*,0,dfft%a2a_comp>>>
         DO i = 0, batchsize-1
            DO cuf_j = 1, npp
               DO cuf_i = 1, nswip
                  mc = p_ismap_d( cuf_i + ioff )
                  it = ( ip - 1 ) * sendsiz + (cuf_i-1)*nppx + i*nppx*ncpx
                  f_aux2_d( cuf_j + it ) = f_aux_d( mc + ( cuf_j - 1 ) * nnp + i*nnr )
               ENDDO
            ENDDO
         ENDDO
      ENDDO

   ELSE

      npp  = dfft%nr3p( me )
      nnp  = dfft%nnp
      !
      DO iter = 1, nprocp
         IF(IAND(nprocp, nprocp-1) == 0) THEN
            dest = IEOR( me-1, iter-1 )
         ELSE
            dest = MOD(me-1 + (iter-1), nprocp)
         ENDIF
         gproc = dest + 1
         !
         ioff = dfft%iss( gproc )
         !
         nswip = dfft%nsw( gproc )
!$cuf kernel do(3) <<<*,*, 0, dfft%a2a_comp>>>
         DO i = 0, batchsize-1
            DO cuf_j = 1, npp
               DO cuf_i = 1, nswip
                 !
                 mc = p_ismap_d( cuf_i + ioff )
                 !
                 it = (cuf_i-1) * nppx + ( gproc - 1 ) * sendsiz + i*nppx*ncpx
                 !
                 f_aux2_d( cuf_j + it ) = f_aux_d( mc + ( cuf_j - 1 ) * nnp + i*nnr )
               ENDDO
               !
            ENDDO
         ENDDO
         !
      ENDDO
   END IF

#ifndef __GPU_MPI
   i = cudaEventRecord(dfft%bevents(batch_id), dfft%a2a_comp)
   i = cudaStreamWaitEvent(dfft%bstreams(batch_id), dfft%bevents(batch_id), 0)

   DO proc = 1, nprocp
      IF (proc .ne. me) THEN
#ifdef __IPC
         IF(dfft%IPC_PEER( proc ) .eq. 0) THEN
            kdest = ( proc - 1 ) * sendsiz
            istat = cudaMemcpyAsync( f_aux2(kdest+1), f_aux2_d(kdest+1), sendsiz, stream=dfft%bstreams(batch_id) )
         ENDIF
#else
         kdest = ( proc - 1 ) * sendsiz
         istat = cudaMemcpyAsync( f_aux2(kdest+1), f_aux2_d(kdest+1), sendsiz, stream=dfft%bstreams(batch_id) )
#endif
      ENDIF
   ENDDO
#endif

#ifdef __GPU_MPI
   istat = cudaEventRecord( dfft%bevents(batch_id), dfft%a2a_comp )
#else
   istat = cudaEventRecord( dfft%bevents(batch_id), dfft%bstreams(batch_id) )
#endif

  !istat = cudaDeviceSynchronize()

#endif

  RETURN

END SUBROUTINE fft_scatter_many_planes_to_columns_store

SUBROUTINE fft_scatter_many_planes_to_columns_send ( dfft, f_in_d, f_in, nr3x, nxx_, f_aux_d, f_aux, f_aux2_d, f_aux2, ncp_, npp_, isgn, batchsize, batch_id )
   !
   USE cudafor
   IMPLICIT NONE
   !
   TYPE (fft_type_descriptor), TARGET, INTENT(in) :: dfft
   INTEGER, INTENT(in)           :: nr3x, nxx_, isgn, ncp_ (:), npp_ (:)
   COMPLEX (DP), DEVICE, INTENT(inout)   :: f_in_d (batchsize * nxx_), f_aux_d (batchsize * nxx_), f_aux2_d (batchsize * nxx_)
   COMPLEX (DP), INTENT(inout)   :: f_in (batchsize * nxx_), f_aux (batchsize * nxx_), f_aux2(batchsize * nxx_)
   INTEGER, INTENT(IN) :: batchsize, batch_id
   INTEGER :: istat
   INTEGER, POINTER, DEVICE :: p_ismap_d(:)
#if defined(__MPI)
   INTEGER :: k, offset, proc, ierr, me, nprocp, gproc, gcomm, i, kdest, kfrom
   INTEGER :: me_p, nppx, mc, j, npp, nnp, nnr, ii, it, ip, ioff, sendsiz, ncpx, ipp, nblk, nsiz

   INTEGER :: iter, dest, sorc, req_cnt
   INTEGER :: istatus(MPI_STATUS_SIZE)

   p_ismap_d => dfft%ismap_d

   me     = dfft%mype + 1
   !
   nprocp = dfft%nproc
   !
   !istat = cudaDeviceSynchronize()
   !
   ncpx = maxval(ncp_) ! max number of sticks among processors ( should be of wave func )
   nppx = maxval(npp_) ! max size of the "Z" section of each processor in the nproc3 group along Z
   !
   IF ( dfft%nproc == 1 ) THEN
      nppx = dfft%nr3x
   END IF
   !
   sendsiz = batchsize * ncpx * nppx
   nnr     = dfft%nnr
#ifdef __IPC
   CALL get_ipc_peers( dfft%IPC_PEER )
#endif
   !

   ierr = 0
   IF (isgn.gt.0) CALL fftx_error__ ('fft_scatter_many_planes_to_columns_send', 'isign is wrong', isgn )

   !
   !  "backward" scatter from planes to columns
   !
   IF( nprocp == 1 ) GO TO 20
   !
   ! Communication takes place here:
   !  fractions of sticks will be moved to form complete sticks
   !
   gcomm = dfft%comm
   !
   ! JR Note: Holding off staging receives until buffer is packed.
   istat = cudaEventSynchronize( dfft%bevents(batch_id) )
   CALL start_clock ('A2A')
#ifdef __IPC
   ! TODO: possibly remove this barrier
   CALL MPI_Barrier( gcomm, ierr )
#endif
   req_cnt = 0

   DO iter = 2, nprocp
      IF(IAND(nprocp, nprocp-1) == 0) THEN
        sorc = IEOR( me-1, iter-1 )
      ELSE
        sorc = MOD(me-1 - (iter-1) + nprocp, nprocp)
      ENDIF
#ifdef __IPC
      IF(dfft%IPC_PEER( sorc + 1 ) .eq. 0) THEN
#endif
#ifdef __GPU_MPI
         call MPI_IRECV( f_aux_d((sorc)*sendsiz + 1), sendsiz, MPI_DOUBLE_COMPLEX, sorc, 0, gcomm, dfft%srh(req_cnt+1, batch_id), ierr )
#else
         call MPI_IRECV( f_aux((sorc)*sendsiz + 1), sendsiz, MPI_DOUBLE_COMPLEX, sorc, 0, gcomm, dfft%srh(req_cnt+1, batch_id), ierr )
#endif
         req_cnt = req_cnt + 1
#ifdef __IPC
      ENDIF
#endif

   ENDDO

   DO iter = 2, nprocp
      IF(IAND(nprocp, nprocp-1) == 0) THEN
        dest = IEOR( me-1, iter-1 )
      ELSE
        dest = MOD(me-1 + (iter-1), nprocp)
      ENDIF
#ifdef __IPC
      IF(dfft%IPC_PEER( dest + 1 ) .eq. 1) THEN
         CALL ipc_send( f_aux2_d((dest)*sendsiz + 1), sendsiz, f_aux_d((me-1)*sendsiz + 1), 0, dest, gcomm, ierr )
      ELSE
#endif
#ifdef __GPU_MPI
         call MPI_ISEND( f_aux2_d((dest)*sendsiz + 1), sendsiz, MPI_DOUBLE_COMPLEX, dest, 0, gcomm, dfft%srh(req_cnt+1, batch_id), ierr )
#else
         call MPI_ISEND( f_aux2((dest)*sendsiz + 1), sendsiz, MPI_DOUBLE_COMPLEX, dest, 0, gcomm, dfft%srh(req_cnt+1, batch_id), ierr )
#endif
         req_cnt = req_cnt + 1
#ifdef __IPC
      ENDIF
#endif
   ENDDO

   ! move the data that we already have (and therefore doesn't to pass through MPI avove)
   ! directly from f_aux_2 to f_in. The rest will be done below.
   offset = 0
   DO proc = 1, me-1
      offset = offset + npp_ ( proc )
   ENDDO
   istat = cudaMemcpy2DAsync( f_in_d(offset + 1), nr3x, f_aux2_d((me-1)*sendsiz + 1), nppx, npp_(me), batchsize * ncpx, &
                              cudaMemcpyDeviceToDevice, dfft%bstreams(batch_id) )

   IF(req_cnt .gt. 0) then
      call MPI_WAITALL(req_cnt, dfft%srh(1:req_cnt, batch_id), MPI_STATUSES_IGNORE, ierr)
   ENDIF
#ifdef __IPC
   call sync_ipc_sends( gcomm )
   call MPI_Barrier( gcomm, ierr )
#endif
   CALL stop_clock ('A2A')

   IF( abs(ierr) /= 0 ) CALL fftx_error__ ('fft_scatter', 'info<>0', abs(ierr) )
   !
   !  Store contiguously the (remaining) columns (one already done above).
   !
   !! f_in = 0.0_DP
   !
   offset = 0

   DO gproc = 1, nprocp
      !
      kdest = ( gproc - 1 ) * sendsiz
      kfrom = offset
      !
      IF (gproc .ne. me) THEN ! (me already done above)
#ifdef __GPU_MPI
!         Columns are now stored in f_aux_d, but are separated by nppx.
!
!         This commented code is left here for helping understand the following calls to CUDA APIs
!
!         !$cuf kernel do(2) <<<*,*, 0, dfft%bstreams(batch_id)>>>
!         !DO k = 1, ncp_ (me)
!         DO k = 1, batchsize * ncpx
!            DO i = 1, npp_ ( gproc )
!              f_in_d( kfrom + i + (k-1)*nr3x ) = f_aux_d( kdest + i + (k-1)*nppx )
!            END DO
!         END DO
        istat = cudaMemcpy2DAsync( f_in_d(kfrom +1 ), nr3x, f_aux_d(kdest + 1), nppx, npp_(gproc), batchsize * ncpx, &
        cudaMemcpyDeviceToDevice, dfft%bstreams(batch_id) )
        IF( istat /= cudaSuccess ) CALL fftx_error__ ('fft_scatter_many_planes_to_columns_send', 'cudaMemcpy2DAsync failed : ', istat)

#else
#ifdef __IPC
        IF(dfft%IPC_PEER( gproc ) .eq. 1) THEN
             istat = cudaMemcpy2DAsync( f_in_d(kfrom +1 ), nr3x, f_aux_d(kdest + 1), nppx, npp_(gproc), batchsize * ncpx, &
                                        cudaMemcpyDeviceToDevice, dfft%bstreams(batch_id) )
        ELSE
             istat = cudaMemcpy2DAsync( f_in_d(kfrom +1 ), nr3x, f_aux(kdest + 1), nppx, npp_(gproc), batchsize * ncpx, &
                                        cudaMemcpyHostToDevice, dfft%bstreams(batch_id) )
        ENDIF
        IF( istat /= cudaSuccess ) CALL fftx_error__ ('fft_scatter_many_planes_to_columns_send', 'cudaMemcpy2DAsync failed : ', istat)
#else
        istat = cudaMemcpy2DAsync( f_in_d(kfrom +1 ), nr3x, f_aux(kdest + 1), nppx, npp_(gproc), batchsize * ncpx, &
                                   cudaMemcpyHostToDevice, dfft%bstreams(batch_id) )
        IF( istat /= cudaSuccess ) CALL fftx_error__ ('fft_scatter_many_planes_to_columns_send', 'cudaMemcpy2DAsync failed : ', istat)
#endif
#endif
      ENDIF
      offset = offset + npp_ ( gproc )
   ENDDO

20 CONTINUE

   !istat = cudaDeviceSynchronize()

#endif

   RETURN

END SUBROUTINE fft_scatter_many_planes_to_columns_send
!
!=----------------------------------------------------------------------=!
END MODULE fft_scatter_2d_gpu
!=----------------------------------------------------------------------=!
#elif __OPENMP_GPU
!=----------------------------------------------------------------------=!
   MODULE fft_scatter_2d_omp
!=----------------------------------------------------------------------=!

        USE fft_types, ONLY: fft_type_descriptor
        USE fft_param
        USE omp_lib
        USE iso_c_binding, ONLY: c_loc, c_int, c_size_t, c_ptr

        IMPLICIT NONE

        SAVE

        PRIVATE

        PUBLIC :: fft_scatter_omp, fft_scatter_omp_batch
        PUBLIC :: fft_scatter_many_columns_to_planes_send_omp, &
                  fft_scatter_many_columns_to_planes_store_omp, &
                  fft_scatter_many_planes_to_columns_send_omp, &
                  fft_scatter_many_planes_to_columns_store_omp

!=----------------------------------------------------------------------=!
      CONTAINS
!=----------------------------------------------------------------------=!

!----------------------------------------------------------------------------
SUBROUTINE fft_scatter_omp ( dfft, f_in, nr3x, nxx_, f_aux, ncp_, npp_, isgn )
  !
  IMPLICIT NONE
  !
  TYPE (fft_type_descriptor), TARGET, INTENT(in) :: dfft
  INTEGER, INTENT(in) :: nr3x, nxx_, isgn, ncp_(:), npp_(:)
  COMPLEX (DP), INTENT(inout), TARGET :: f_in(nxx_), f_aux(nxx_)
  COMPLEX(DP) :: dummy
  INTEGER :: omp_i, omp_j, nswip, nppt
  INTEGER :: istat
#if defined(__MPI)

  INTEGER :: srh(2*dfft%nproc)
  INTEGER :: k, proc, ierr, me, nprocp, gproc, gcomm, i, kdest, kfrom, offset
  INTEGER :: me_p, nppx, mc, j, npp, nnp, ii, it, ip, ioff, sendsiz, ncpx, ipp, nblk, nsiz
  !
  INTEGER :: iter, dest, sorc, ncp_me, npp_gproc
  INTEGER :: istatus(MPI_STATUS_SIZE)

  me     = dfft%mype + 1
  !
  nprocp = dfft%nproc
  !
  ncpx = maxval(ncp_)
  nppx = maxval(npp_)

  ! This should never happend and should go away
  IF ( dfft%nproc == 1 ) THEN
     nppx = dfft%nr3x
  END IF
  sendsiz = ncpx * nppx
  nppt = sum(npp_(1:nprocp))
  !
  ierr = 0
  IF (isgn.gt.0) THEN

     IF (nprocp==1) GO TO 10
     !
     ! "forward" scatter from columns to planes
     !
     ! step one: store contiguously the slices
     !
     offset = 0
     !
#ifdef __MEMCPY_RECT
     !
#if defined(__GPU_MPI) || defined(__GPU_MPI_OMP)
     !$omp target data use_device_addr(f_in,f_aux)
#else
     !$omp target data use_device_addr(f_in)
#endif
     DO gproc = 1, nprocp
        ncp_me = ncp_(me)
        npp_gproc = npp_(gproc)
        kdest = ( gproc - 1 ) * ncpx
        kfrom = sum(npp_(1:gproc-1))
        istat = int(omp_target_memcpy_rect(c_loc(f_aux), c_loc(f_in),                  &
                                           int(sizeof(dummy),c_size_t),                &
                                           int(2,c_int),                               &
                                           int((/      ncp_me, npp_gproc /),c_size_t), &
                                           int((/       kdest,         0 /),c_size_t), &
                                           int((/           0,     kfrom /),c_size_t), &
                                           int((/ (nxx_/nppx),      nppx /),c_size_t), &
                                           int((/ (nxx_/nr3x),      nppt /),c_size_t), &
#if defined(__GPU_MPI) || defined(__GPU_MPI_OMP)
                                           int(omp_get_default_device(),c_int),        &
#else
                                           int(omp_get_initial_device(),c_int),        &
#endif
                                           int(omp_get_default_device(),c_int)),       &
                    kind(istat))
     ENDDO
     !$omp end target data
     !
#else
     !
     DO gproc = 1, nprocp
        kdest = ( gproc - 1 ) * sendsiz
        kfrom = offset
        ncp_me = ncp_(me)
        npp_gproc = npp_(gproc)
        !$omp target teams distribute parallel do collapse(2)
        DO k = 1, ncp_me
           DO i = 1, npp_gproc
             f_aux( kdest + i + (k-1)*nppx ) = f_in( kfrom + i + (k-1)*nr3x )
           END DO
        END DO
        offset = offset + npp_gproc
     ENDDO
#if !defined(__GPU_MPI) && !defined(__GPU_MPI_OMP)
     !$omp target update from (f_aux)
#endif
     !
#endif
     !
     ! maybe useless; ensures that no garbage is present in the output
     !
     ! ! f_in = 0.0_DP
     !
     ! step two: communication
     !
     gcomm = dfft%comm

     CALL start_clock ('a2a_fw')
#if defined(__GPU_MPI) || defined(__GPU_MPI_OMP)

!$omp target data use_device_addr(f_in, f_aux)
     DO iter = 2, nprocp
        IF(IAND(nprocp, nprocp-1) == 0) THEN
          sorc = IEOR( me-1, iter-1 )
        ELSE
          sorc = MOD(me-1 - (iter-1) + nprocp, nprocp)
        ENDIF

        call MPI_IRECV( f_in((sorc)*sendsiz + 1), sendsiz, MPI_DOUBLE_COMPLEX, sorc, 0, gcomm, srh(iter-1), ierr )

     ENDDO

     DO iter = 2, nprocp
        IF(IAND(nprocp, nprocp-1) == 0) THEN
          dest = IEOR( me-1, iter-1 )
        ELSE
          dest = MOD(me-1 + (iter-1), nprocp)
        ENDIF

        call MPI_ISEND( f_aux((dest)*sendsiz + 1), sendsiz, MPI_DOUBLE_COMPLEX, dest, 0, gcomm, srh(iter+nprocp-2), ierr )

     ENDDO
!$omp end target data

!$omp target teams distribute parallel do
     DO i=(me-1)*sendsiz + 1, me*sendsiz
        f_in(i) = f_aux(i)
     ENDDO
!$omp end target teams distribute parallel do

     call MPI_WAITALL(2*nprocp-2, srh, MPI_STATUSES_IGNORE, ierr)
#else
     CALL mpi_alltoall (f_aux(1), sendsiz, MPI_DOUBLE_COMPLEX, f_in(1), sendsiz, MPI_DOUBLE_COMPLEX, gcomm, ierr)
     !$omp target update to (f_in(1:sendsiz*nprocp))
#endif
     CALL stop_clock ('a2a_fw')

     IF( abs(ierr) /= 0 ) CALL fftx_error__ ('fft_scatter', 'info<>0', abs(ierr) )
     !
10   CONTINUE

!$omp target teams distribute parallel do
     do i = 1, nxx_
       f_aux(i) = (0.d0, 0.d0)
     end do
!$omp end target teams distribute parallel do

     npp = dfft%nr3p( me )
     nnp = dfft%nnp
     IF( isgn == 1 ) THEN
        DO ip = 1, nprocp
           ioff = dfft%iss( ip )
           nswip = dfft%nsp( ip )
!$omp target teams distribute parallel do collapse(2)
           DO omp_j = 1, npp
              DO omp_i = 1, nswip
                 it = ( ip - 1 ) * sendsiz + (omp_i-1)*nppx
                 mc = dfft%ismap( omp_i + ioff )
                 f_aux( mc + ( omp_j - 1 ) * nnp ) = f_in( omp_j + it )
              ENDDO
           ENDDO
!$omp end target teams distribute parallel do
        ENDDO
     ELSE
        DO ip = 1, nprocp
           ioff = dfft%iss( ip )
           nswip =  dfft%nsw( ip )
!$omp target teams distribute parallel do collapse(2)
           DO omp_j = 1, npp
              DO omp_i = 1, nswip
                 it = (omp_i-1) * nppx + ( ip - 1 ) * sendsiz
                 mc = dfft%ismap( omp_i + ioff )
                 f_aux( mc + ( omp_j - 1 ) * nnp ) = f_in( omp_j + it )
              ENDDO
           ENDDO
!$omp end target teams distribute parallel do
        ENDDO
     END IF
  ELSE
     !
     !  "backward" scatter from planes to columns
     !
     npp = dfft%nr3p( me )
     nnp = dfft%nnp
     IF( isgn == -1 ) THEN
        DO ip = 1, nprocp
           ioff = dfft%iss( ip )
           nswip = dfft%nsp( ip )
           !$omp target teams distribute parallel do collapse(2)
           DO omp_j = 1, npp
              DO omp_i = 1, nswip
                 mc = dfft%ismap( omp_i + ioff )
                 it = ( ip - 1 ) * sendsiz + (omp_i-1)*nppx
                 f_in( omp_j + it ) = f_aux( mc + ( omp_j - 1 ) * nnp )
              ENDDO
           ENDDO
        ENDDO
     ELSE
        DO gproc = 1, nprocp
           ioff = dfft%iss( gproc )
           nswip = dfft%nsw( gproc )
           !$omp target teams distribute parallel do collapse(2)
           DO omp_j = 1, npp
              DO omp_i = 1, nswip
                 mc = dfft%ismap( omp_i + ioff )
                 it = (omp_i-1) * nppx + ( gproc - 1 ) * sendsiz
                 f_in( omp_j + it ) = f_aux( mc + ( omp_j - 1 ) * nnp )
              ENDDO
           ENDDO
        ENDDO
     END IF
     !
     IF( nprocp == 1 ) GO TO 20
     !
     !  step two: communication
     !
     gcomm = dfft%comm
     !
#if !defined(__GPU_MPI) && !defined(__GPU_MPI_OMP)
     !$omp target update from (f_in(1:sendsiz*nprocp))
#endif
     !
     CALL start_clock ('a2a_bw')
#if defined(__GPU_MPI) || defined(__GPU_MPI_OMP)
     !$omp target data use_device_addr(f_in, f_aux)
     DO iter = 2, nprocp
        IF(IAND(nprocp, nprocp-1) == 0) THEN
          sorc = IEOR( me-1, iter-1 )
        ELSE
          sorc = MOD(me-1 - (iter-1) + nprocp, nprocp)
        ENDIF

        call MPI_IRECV( f_aux((sorc)*sendsiz + 1), sendsiz, MPI_DOUBLE_COMPLEX, sorc, 0, gcomm, srh(iter-1), ierr )

     ENDDO

     DO iter = 2, nprocp
        IF(IAND(nprocp, nprocp-1) == 0) THEN
          dest = IEOR( me-1, iter-1 )
        ELSE
          dest = MOD(me-1 + (iter-1), nprocp)
        ENDIF

        call MPI_ISEND( f_in((dest)*sendsiz + 1), sendsiz, MPI_DOUBLE_COMPLEX, dest, 0, gcomm, srh(iter+nprocp-2), ierr )

     ENDDO
     !$omp end target data

     !$omp target teams distribute parallel do
     DO i=(me-1)*sendsiz + 1, me*sendsiz
        f_aux(i) = f_in(i)
     ENDDO

     call MPI_WAITALL(2*nprocp-2, srh, MPI_STATUSES_IGNORE, ierr)
#else
     CALL mpi_alltoall (f_in(1), sendsiz, MPI_DOUBLE_COMPLEX, f_aux(1), sendsiz, MPI_DOUBLE_COMPLEX, gcomm, ierr)
#ifndef __MEMCPY_RECT
     !$omp target update to(f_aux)
#endif
#endif
     CALL stop_clock ('a2a_bw')
     IF( abs(ierr) /= 0 ) CALL fftx_error__ ('fft_scatter', 'info<>0', abs(ierr) )
     !
     !  step one: store contiguously the columns
     !
     offset = 0
     !
#ifdef __MEMCPY_RECT
     !
#if defined(__GPU_MPI) || defined(__GPU_MPI_OMP)
     !$omp target data use_device_addr(f_in,f_aux)
#else
     !$omp target data use_device_addr(f_in)
#endif
     DO gproc = 1, nprocp
        ncp_me = ncp_(me)
        npp_gproc = npp_(gproc)
        kdest = ( gproc - 1 ) * ncpx
        kfrom = sum( npp_(1:gproc-1))
        istat = int(omp_target_memcpy_rect(c_loc(f_in), c_loc(f_aux),                  &
                                           int(sizeof(dummy),c_size_t),                &
                                           int(2,c_int),                               &
                                           int((/      ncp_me, npp_gproc /),c_size_t), &
                                           int((/           0,     kfrom /),c_size_t), &
                                           int((/       kdest,         0 /),c_size_t), &
                                           int((/ (nxx_/nr3x),      nr3x /),c_size_t), &
                                           int((/ (nxx_/nppx),      nppx /),c_size_t), &
                                           int(omp_get_default_device(),c_int),        &
#if defined(__GPU_MPI) || defined(__GPU_MPI_OMP)
                                           int(omp_get_default_device(),c_int)),       &
#else
                                           int(omp_get_initial_device(),c_int)),       &
#endif
                    kind(istat))
     ENDDO
     !$omp end target data
     !
#else
     !
     DO gproc = 1, nprocp
        kdest = ( gproc - 1 ) * sendsiz
        kfrom = offset
        ncp_me = ncp_(me)
        npp_gproc = npp_(gproc)
        !$omp target teams distribute parallel do collapse(2)
        DO k = 1, ncp_me
           DO i = 1, npp_gproc
             f_in( kfrom + i + (k-1)*nr3x ) = f_aux( kdest + i + (k-1)*nppx )
           END DO
        END DO
        offset = offset + npp_gproc
     ENDDO
     !
#endif

20   CONTINUE

  ENDIF

#endif

  RETURN

END SUBROUTINE fft_scatter_omp

SUBROUTINE fft_scatter_omp_batch ( dfft, f_in, nr3x, nxx_, f_aux, ncp_, npp_, isgn, batchsize, srh )
  !
  IMPLICIT NONE
  !
  TYPE (fft_type_descriptor), TARGET, INTENT(in) :: dfft
  INTEGER, INTENT(in)           :: nr3x, nxx_, isgn, ncp_ (:), npp_ (:)
  COMPLEX (DP), INTENT(inout)   :: f_in(:), f_aux(:)
  INTEGER, INTENT(IN) :: batchsize
  INTEGER, INTENT(INOUT) :: srh(2*dfft%nproc)
  INTEGER :: omp_i, omp_j, nswip
  INTEGER :: istat
#if defined(__MPI)

  INTEGER :: k, offset, proc, ierr, me, nprocp, gproc, gcomm, i, kdest, kfrom
  INTEGER :: me_p, nppx, mc, j, npp, nnp, nnr, ii, it, ip, ioff, sendsiz, ncpx, ipp, nblk, nsiz
  !
  INTEGER :: iter, dest, sorc
  INTEGER :: istatus(MPI_STATUS_SIZE)
  !
  !
  me     = dfft%mype + 1
  !
  nprocp = dfft%nproc
  !
  ncpx = maxval(ncp_)
  nppx = maxval(npp_)
  !
  IF ( dfft%nproc == 1 ) THEN
     nppx = dfft%nr3x
  END IF
  !
  sendsiz = batchsize * ncpx * nppx
  nnr     = dfft%nnr
  !
  ierr = 0
  IF (isgn.gt.0) THEN

     IF (nprocp==1) GO TO 10
     !
     ! "forward" scatter from columns to planes
     !
     ! step one: store contiguously the slices
     !
     offset = 0
     DO gproc = 1, nprocp
        kdest = ( gproc - 1 ) * sendsiz
        kfrom = offset
!$omp target teams distribute parallel do collapse(2)
        DO k = 1, batchsize * ncpx
           DO i = 1, npp_ ( gproc )
             f_aux( kdest + i + (k-1)*nppx ) = f_in( kfrom + i + (k-1)*nr3x )
           END DO
        END DO
!$omp end target teams distribute parallel do
        offset = offset + npp_ ( gproc )
     ENDDO
#ifndef __GPU_MPI
!$omp target update from (f_aux)
#endif
     !
     ! maybe useless; ensures that no garbage is present in the output
     !
     ! step two: communication
     !
     gcomm = dfft%comm

     CALL start_clock ('a2a_fw')

     DO iter = 2, nprocp
        IF(IAND(nprocp, nprocp-1) == 0) THEN
          sorc = IEOR( me-1, iter-1 )
        ELSE
          sorc = MOD(me-1 - (iter-1) + nprocp, nprocp)
        ENDIF

#ifdef __GPU_MPI
!$omp target data use_device_ptr(f_in)
        CALL MPI_IRECV( f_in((sorc)*sendsiz + 1), sendsiz, MPI_DOUBLE_COMPLEX, sorc, 0, gcomm, srh(iter-1), ierr )
!$omp end target data
#else
        CALL MPI_IRECV( f_in((sorc)*sendsiz + 1), sendsiz, MPI_DOUBLE_COMPLEX, sorc, 0, gcomm, srh(iter-1), ierr )
#endif

     ENDDO

     DO iter = 2, nprocp
        IF(IAND(nprocp, nprocp-1) == 0) THEN
          dest = IEOR( me-1, iter-1 )
        ELSE
          dest = MOD(me-1 + (iter-1), nprocp)
        ENDIF

#ifdef __GPU_MPI
!$omp target data use_device_ptr(f_aux)
        CALL MPI_ISEND( f_aux((dest)*sendsiz + 1), sendsiz, MPI_DOUBLE_COMPLEX, dest, 0, gcomm, srh(iter+nprocp-2), ierr )
!$omp end target data
#else
        CALL MPI_ISEND( f_aux((dest)*sendsiz + 1), sendsiz, MPI_DOUBLE_COMPLEX, dest, 0, gcomm, srh(iter+nprocp-2), ierr )
#endif

     ENDDO

#ifdef __GPU_MPI
!$omp target data use_device_ptr(f_in, f_aux)
!$omp target teams distribute parallel do
     DO i=(me-1)*sendsiz + 1, me*sendsiz
        f_in(i) = f_aux(i)
     ENDDO
!$omp end target teams distribute parallel do
!$omp end target data
#else
     f_in((me-1)*sendsiz + 1 : me*sendsiz) = f_aux((me-1)*sendsiz + 1 : me*sendsiz)
#endif

     CALL MPI_WAITALL(2*nprocp-2, srh, MPI_STATUSES_IGNORE, ierr)
     IF( abs(ierr) /= 0 ) CALL fftx_error__ ('fft_scatter', 'MPI_WAITALL info<>0', abs(ierr) )

     CALL stop_clock ('a2a_fw')

#ifndef __GPU_MPI
!$omp target update to (f_in(1:sendsiz*dfft%nproc))
#endif
     !
10   CONTINUE

     ! Zero out f_aux_d
!$omp target teams distribute parallel do
     DO i = lbound(f_aux,1), ubound(f_aux,1)
       f_aux(i) = (0.d0, 0.d0)
     END DO
!$omp end target teams distribute parallel do

     npp = dfft%nr3p( me )
     nnp = dfft%nnp
     IF( isgn == 1 ) THEN
        DO ip = 1, dfft%nproc
           ioff = dfft%iss( ip )
           nswip = dfft%nsp( ip )
!$omp target teams distribute parallel do collapse(2)
           DO omp_j = 1, npp
              DO omp_i = 1, nswip
                 it = ( ip - 1 ) * sendsiz + (omp_i-1)*nppx
                 mc = dfft%ismap( omp_i + ioff )
                 f_aux( mc + ( omp_j - 1 ) * nnp ) = f_in( omp_j + it )
              ENDDO
           ENDDO
!$omp end target teams distribute parallel do
        ENDDO
     ELSE
        DO gproc = 1,  dfft%nproc
           ioff = dfft%iss( gproc )
           nswip =  dfft%nsw( gproc )
!$omp target teams distribute parallel do collapse(3)
           DO i = 0, batchsize-1
              DO omp_j = 1, npp
                 DO omp_i = 1, nswip
                    mc = dfft%ismap( omp_i + ioff )
                    it = (omp_i-1) * nppx + ( gproc - 1 ) * sendsiz + i*nppx*ncpx
                    f_aux( mc + ( omp_j - 1 ) * nnp + i*nnr ) = f_in( omp_j + it )
                 ENDDO
              ENDDO
           ENDDO
!$omp end target teams distribute parallel do
        ENDDO
     END IF
  ELSE
     !
     !  "backward" scatter from planes to columns
     !
     npp = dfft%nr3p( me )
     nnp = dfft%nnp
     IF( isgn == -1 ) THEN
        DO ip = 1, dfft%nproc
           ioff = dfft%iss( ip )
           nswip = dfft%nsp( ip )
!$omp target teams distribute parallel do collapse(2)
           DO omp_j = 1, npp
              DO omp_i = 1, nswip
                 mc = dfft%ismap( omp_i + ioff )
                 it = ( ip - 1 ) * sendsiz + (omp_i-1)*nppx
                    f_in( omp_j + it ) = f_aux( mc + ( omp_j - 1 ) * nnp )
              ENDDO
           ENDDO
!$omp end target teams distribute parallel do
        ENDDO
     ELSE
        DO ip = 1, dfft%nproc
           ioff = dfft%iss( ip )
           nswip = dfft%nsw( ip )
!$omp target teams distribute parallel do collapse(3)
           DO i = 0, batchsize-1
              DO omp_j = 1, npp
                 DO omp_i = 1, nswip
                    mc = dfft%ismap( omp_i + ioff )
                    it = (omp_i-1) * nppx + ( ip - 1 ) * sendsiz + i*nppx*ncpx
                    f_in( omp_j + it ) = f_aux( mc + ( omp_j - 1 ) * nnp + i*nnr )
                 ENDDO
              ENDDO
           ENDDO
!$omp end target teams distribute parallel do
        ENDDO
     END IF
     !
     IF( nprocp == 1 ) GO TO 20
     !
     !  step two: communication
     !
     gcomm = dfft%comm

#ifndef __GPU_MPI
!$omp target update from (f_in(1:sendsiz*dfft%nproc))
#endif
     ! CALL mpi_barrier (gcomm, ierr)  ! why barrier? for buggy openmpi over ib
     CALL start_clock ('a2a_bw')

     DO iter = 2, nprocp
        IF(IAND(nprocp, nprocp-1) == 0) THEN
          sorc = IEOR( me-1, iter-1 )
        ELSE
          sorc = MOD(me-1 - (iter-1) + nprocp, nprocp)
        ENDIF
#ifdef __GPU_MPI
!$omp target data use_device_ptr(f_aux)
        call MPI_IRECV( f_aux((sorc)*sendsiz + 1), sendsiz, MPI_DOUBLE_COMPLEX, sorc, 0, gcomm, srh(iter-1), ierr )
!$omp end target data
#else
        call MPI_IRECV( f_aux((sorc)*sendsiz + 1), sendsiz, MPI_DOUBLE_COMPLEX, sorc, 0, gcomm, srh(iter-1), ierr )
#endif
     ENDDO

     DO iter = 2, nprocp
        IF(IAND(nprocp, nprocp-1) == 0) THEN
          dest = IEOR( me-1, iter-1 )
        ELSE
          dest = MOD(me-1 + (iter-1), nprocp)
        ENDIF
#ifdef __GPU_MPI
!$omp target data use_device_ptr(f_in)
        call MPI_ISEND( f_in((dest)*sendsiz + 1), sendsiz, MPI_DOUBLE_COMPLEX, dest, 0, gcomm, srh(iter+nprocp-2), ierr )
!$omp end target data
#else
        call MPI_ISEND( f_in((dest)*sendsiz + 1), sendsiz, MPI_DOUBLE_COMPLEX, dest, 0, gcomm, srh(iter+nprocp-2), ierr )
#endif
     ENDDO

#ifdef __GPU_MPI
!$omp target data use_device_ptr(f_in, f_aux)
!$omp target teams distribute parallel do
     DO i=(me-1)*sendsiz + 1, me*sendsiz
        f_aux(i) = f_in(i)
     ENDDO
!$omp end target teams distribute parallel do
!$omp end target data
#else
     f_aux( (me-1)*sendsiz + 1:me*sendsiz) = f_in((me-1)*sendsiz + 1:me*sendsiz)
     !$omp target update to(f_aux)
#endif

     call MPI_WAITALL(2*nprocp-2, srh, MPI_STATUSES_IGNORE, ierr)
     IF( abs(ierr) /= 0 ) CALL fftx_error__ ('fft_scatter', 'MPI_WAITALL info<>0', abs(ierr) )

     CALL stop_clock ('a2a_bw')
     !
     !  step one: store contiguously the columns
     !
     !! f_in = 0.0_DP
     !
     offset = 0

     DO gproc = 1, nprocp
        kdest = ( gproc - 1 ) * sendsiz
        kfrom = offset
!$omp target teams distribute parallel do collapse(2)
        DO k = 1, batchsize * ncpx
           DO i = 1, npp_ ( gproc )
             f_in( kfrom + i + (k-1)*nr3x ) = f_aux( kdest + i + (k-1)*nppx )
           END DO
        END DO
!$omp end target teams distribute parallel do
        offset = offset + npp_ ( gproc )
     ENDDO

20   CONTINUE

  ENDIF

#endif

  RETURN

END SUBROUTINE fft_scatter_omp_batch

SUBROUTINE fft_scatter_many_columns_to_planes_store_omp ( dfft, f_in, nr3x, nxx_, f_aux, ncp_, npp_, isgn, batchsize, batch_id )
   !
   USE hipfft, ONLY: hipEventRecord, hipMemcpy2DAsync, hipcheck, hipdevicesynchronize
   !
   IMPLICIT NONE
   !
   TYPE (fft_type_descriptor), TARGET, INTENT(in) :: dfft
   INTEGER, INTENT(in)           :: nr3x, nxx_, isgn, ncp_ (:), npp_ (:)
   COMPLEX (DP), INTENT(inout)   :: f_in(:), f_aux(:)
   INTEGER, INTENT(IN) :: batchsize, batch_id
   INTEGER :: istat
#if defined(__MPI)
   INTEGER :: k, offset, proc, ierr, me, nprocp, gcomm, i, kdest, kfrom
   INTEGER :: me_p, nppx, mc, j, npp, nnp, nnr, ii, it, ip, ioff, sendsiz, ncpx, &
              ipp, nblk, nsiz, npp_proc, ncp_me
   !
   INTEGER, ALLOCATABLE, DIMENSION(:) :: offset_proc
   INTEGER :: iter, dest, sorc
   INTEGER :: istatus(MPI_STATUS_SIZE)
   COMPLEX(DP) :: dummy
   !
#ifdef __GPU_MPI
   call fftx_error__('fft_scatter_many_', 'OMP batched FFT not enabled with gpu_mpi', abs(ierr))
#endif
   !
   me     = dfft%mype + 1
   !
   nprocp = dfft%nproc
#ifdef __IPC
#ifndef __GPU_MPI
  call get_ipc_peers( dfft%IPC_PEER )
#endif
#endif
   !
   ncpx = maxval(ncp_)
   nppx = maxval(npp_)
   !
   IF ( dfft%nproc == 1 ) nppx = dfft%nr3x
   !
   sendsiz = batchsize * ncpx * nppx
   nnr     = dfft%nnr
   ierr    = 0
   !
   IF (isgn.lt.0) CALL fftx_error__ ('fft_scatter_many_columns_to_planes_store', 'isign is wrong', isgn )
   !
   IF (nprocp==1) GO TO 10
   !
   ! "forward" scatter from columns to planes
   !
   ! step one: store contiguously the slices
   !
   ALLOCATE( offset_proc( nprocp ) )
   offset = 0
   DO proc = 1, nprocp
      offset_proc( proc ) = offset
      offset = offset + npp_(proc)
   ENDDO
   !
   !$omp target data use_device_ptr(f_in)
   DO iter = 2, nprocp
      IF(IAND(nprocp, nprocp-1) == 0) THEN
        dest = IEOR( me-1, iter-1 )
      ELSE
        dest = MOD(me-1 + (iter-1), nprocp)
      ENDIF
      proc = dest + 1
      !
      kdest = ( proc - 1 ) * sendsiz
      kfrom = offset_proc( proc )
      !
      npp_proc = npp_(proc)
      !
#ifdef __GPU_MPI
!$omp target data use_device_ptr(f_in, f_aux)
      DO k = 1, batchsize * ncpx
         DO i = 1, npp_proc
           f_aux( kdest + i + (k-1)*nppx ) = f_in( kfrom + i + (k-1)*nr3x )
         END DO
      END DO
!$omp end target data
#else
#ifdef __IPC
      IF(dfft%IPC_PEER( dest + 1 ) .eq. 1) THEN
!$omp taskgroup
!$omp target teams distribute parallel do collapse(2) nowait
         DO k = 1, batchsize * ncpx
            DO i = 1, npp_proc
              f_aux( kdest + i + (k-1)*nppx ) = f_in( kfrom + i + (k-1)*nr3x )
            END DO
         END DO
!$omp end target teams distribute parallel do
!$omp end taskgroup
      ELSE
!$omp taskgroup
!$omp target teams distribute parallel do collapse(2) nowait
         DO k = 1, batchsize * ncpx
            DO i = 1, npp_proc
              f_aux( kdest + i + (k-1)*nppx ) = f_in( kfrom + i + (k-1)*nr3x )
            END DO
         END DO
!$omp end target teams distribute parallel do
!$omp end taskgroup
      ENDIF
#else
      !
      ncp_me = batchsize*ncpx
      kdest = ncpx*(proc-1)*batchsize * nppx
      kfrom = offset_proc(proc)
      !
      istat = hipMemcpy2DAsync( int(sizeof(dummy)),      &
                                c_loc(f_aux(kdest+1)), &
                                c_loc(f_in(kfrom+1)),  &
                                nppx,                  &
                                nr3x,                  &
                                npp_proc,              &
                                ncp_me,                &
#if defined(__GPU_MPI) || defined(__GPU_MPI_OMP)
                                int(3,c_int),          &
#else
                                int(2,c_int),          &
#endif
                                dfft%bstreams(batch_id) )
#endif
#endif
   ENDDO
   !$omp end target data
   !
   istat = hipEventRecord( dfft%bevents(batch_id), dfft%bstreams(batch_id) )
   DEALLOCATE( offset_proc )
   !
10 CONTINUE

#endif
  !
  RETURN
  !
END SUBROUTINE fft_scatter_many_columns_to_planes_store_omp

SUBROUTINE fft_scatter_many_columns_to_planes_send_omp ( dfft, f_in, nr3x, nxx_, f_aux, f_aux2, ncp_, npp_, &
                                                         isgn, batchsize, batch_id, dfft_iss, dfft_nsw, dfft_nsp, dfft_ismap )
   !
   USE hipfft, ONLY: hipEventRecord, hipMemcpy2DAsync, hipMemcpy,hipMemcpyAsync, &
                     hipcheck, hipdevicesynchronize, hipStreamWaitEvent
   USE hip_kernels, ONLY: loop2d_scatter_hip
   !
   IMPLICIT NONE
   !
   TYPE (fft_type_descriptor), TARGET, INTENT(in) :: dfft
   INTEGER, INTENT(in)           :: nr3x, nxx_, isgn, ncp_ (:), npp_ (:)
   COMPLEX (DP), INTENT(inout)   :: f_in(:), f_aux(:), f_aux2(:)
   INTEGER, INTENT(IN) :: batchsize, batch_id
   INTEGER :: cuf_i, cuf_j, nswip
   INTEGER :: istat
   COMPLEX(DP) :: dummy

   INTEGER, INTENT(IN) :: dfft_iss(:), dfft_nsw(:), dfft_nsp(:), dfft_ismap(:)

#if defined(__MPI)
   !
   INTEGER :: k, offset, proc, ierr, me, nprocp, gproc, gcomm, i, kdest, kfrom
   INTEGER :: me_p, nppx, mc, j, npp, nnp, nnr, ii, it, ip, ioff, sendsiz, ncpx, &
              ipp, nblk, nsiz, npp_me
   !
   INTEGER :: iter, dest, sorc, req_cnt
   INTEGER :: istatus(MPI_STATUS_SIZE)
   !
#ifdef __GPU_MPI
   CALL fftx_error__('fft_scatter_many_', 'OMP batched FFT not enabled with gpu_mpi', abs(ierr))
#endif
   !
   me     = dfft%mype + 1
   !
   npp_me = npp_(me)
   !
   nprocp = dfft%nproc
   !
   ncpx = maxval(ncp_)
   nppx = maxval(npp_)

   !
   IF ( dfft%nproc == 1 ) nppx = dfft%nr3x
   !
   sendsiz = batchsize * ncpx * nppx
   nnr     = dfft%nnr
#ifdef __IPC
   call get_ipc_peers( dfft%IPC_PEER )
#endif
   !
   ierr = 0
   IF (isgn.lt.0) CALL fftx_error__ ('fft_scatter_many_columns_to_planes_send', 'isign is wrong', isgn )

   IF (nprocp==1) GO TO 10
   ! step two: communication
   !
   gcomm = dfft%comm
   !
   ! JR Note: Holding off staging receives until buffer is packed.
   CALL start_clock ('A2A')
#ifdef __IPC
   !TODO: possibly remove this barrier by ensuring recv buffer is not used by previous operation
   call MPI_Barrier( gcomm, ierr )
#endif
      req_cnt = 0

   DO iter = 2, nprocp
      IF(IAND(nprocp, nprocp-1) == 0) THEN
        sorc = IEOR( me-1, iter-1 )
      ELSE
        sorc = MOD(me-1 - (iter-1) + nprocp, nprocp)
      ENDIF
#ifdef __IPC
      IF(dfft%IPC_PEER( sorc + 1 ) .eq. 0) THEN
#endif
#ifdef __GPU_MPI
!$omp target data use_device_ptr(f_aux2)
         CALL MPI_IRECV( f_aux2((sorc)*sendsiz + 1), sendsiz, MPI_DOUBLE_COMPLEX, sorc, 0, gcomm, dfft%srh(req_cnt+1, batch_id), ierr )
!$omp end target data
#else
         CALL MPI_IRECV( f_aux2((sorc)*sendsiz + 1), sendsiz, MPI_DOUBLE_COMPLEX, sorc, 0, gcomm, dfft%srh(req_cnt+1, batch_id), ierr )
#endif
         req_cnt = req_cnt + 1
#ifdef __IPC
      ENDIF
#endif
   ENDDO

   DO iter = 2, nprocp
      IF(IAND(nprocp, nprocp-1) == 0) THEN
         dest = IEOR( me-1, iter-1 )
      ELSE
         dest = MOD(me-1 + (iter-1), nprocp)
      ENDIF
#ifdef __IPC
      IF(dfft%IPC_PEER( dest + 1 ) .eq. 1) THEN
         CALL ipc_send( f_aux_d((dest)*sendsiz + 1), sendsiz, f_aux2_d((me-1)*sendsiz + 1), 1, dest, gcomm, ierr )
      ELSE
#endif
#ifdef __GPU_MPI
!$omp target data use_device_ptr(f_aux)
         CALL MPI_ISEND( f_aux((dest)*sendsiz + 1), sendsiz, MPI_DOUBLE_COMPLEX, dest, 0, gcomm, dfft%srh(req_cnt+1, batch_id), ierr )
!$omp end target data
#else
         CALL MPI_ISEND( f_aux((dest)*sendsiz + 1), sendsiz, MPI_DOUBLE_COMPLEX, dest, 0, gcomm, dfft%srh(req_cnt+1, batch_id), ierr )
#endif
         req_cnt = req_cnt + 1
#ifdef __IPC
      ENDIF
#endif
   ENDDO
   !
   offset = 0
   DO proc = 1, me-1
      offset = offset + npp_( proc )
   ENDDO
   !
!!$omp target teams distribute parallel do collapse(2)
!   DO k = 1, batchsize * ncpx
!      DO i = 1, npp_me
!        f_aux2( (me-1)*sendsiz + i + (k-1)*nppx ) = f_in( offset + i + (k-1)*nr3x )
!      END DO
!   END DO
!!$omp end target teams distribute parallel do
   kdest = (me-1)*sendsiz
   kfrom = offset
   !
   !$omp target data use_device_addr(f_in,f_aux2)
   istat = hipMemcpy2DAsync( int(sizeof(dummy)),        &
                                c_loc(f_aux2(kdest+1)), &
                                c_loc(f_in(kfrom+1)),  &
                                nppx,                  &
                                nr3x,                  &
                                npp_me,                &
                                batchsize*ncpx,        &
                                int(3,c_int),          &
                                dfft%bstreams(batch_id) )
   !$omp end target data
   !
   CALL hipCheck(hipDeviceSynchronize())

   IF(req_cnt .gt. 0) CALL MPI_WAITALL(req_cnt, dfft%srh(1:req_cnt, batch_id), MPI_STATUSES_IGNORE, ierr)

#ifdef __IPC
   CALL sync_ipc_sends( gcomm )
   CALL MPI_Barrier( gcomm, ierr )
#endif
   CALL stop_clock ('A2A')

   IF( abs(ierr) /= 0 ) CALL fftx_error__ ('fft_scatter', 'info<>0', abs(ierr) )
#ifndef __GPU_MPI
   DO proc = 1, nprocp
      IF (proc .ne. me) THEN
#ifdef __IPC
         IF(dfft%IPC_PEER( proc ) .eq. 0) THEN
            kdest = ( proc - 1 ) * sendsiz
         ENDIF
#else
         kdest = ( proc - 1 ) * sendsiz
#endif
!        !$omp target update to (f_aux2(kdest+1:kdest+sendsiz))
         !
         !$omp target data use_device_ptr(f_aux)
         istat = hipMemcpyAsync( int(sizeof(dummy)), c_loc(f_aux(kdest+1)), c_loc(f_aux2(kdest+1)), sendsiz,int(1,c_int), dfft%bstreams(batch_id) )
         !$omp end target data
         !$omp target data use_device_ptr(f_aux2,f_aux)
         istat = hipMemcpyAsync( int(sizeof(dummy)), c_loc(f_aux2(kdest+1)), c_loc(f_aux(kdest+1)), sendsiz,int(3,c_int), dfft%bstreams(batch_id) )
         !$omp end target data
      ENDIF
   ENDDO
#endif
   !
   !i = cudaEventRecord(dfft%bevents(batch_id), dfft%bstreams(batch_id))
   !i = cudaStreamW(dfft%a2a_comp, dfft%bevents(batch_id), 0)
   !istat = hipEventRecord( dfft%bevents(batch_id), dfft%bstreams(batch_id) )
   !istat = hipStreamWaitEvent( dfft%a2a_comp, dfft%bstreams(batch_id), 0)
   !
   CALL hipCheck(hipDeviceSynchronize())
   !
   !
10 CONTINUE
   !
   ! Zero out f_aux_d
!$omp target teams distribute parallel do
   do i = lbound(f_aux,1), ubound(f_aux,1)
     f_aux(i) = (0.d0, 0.d0)
   end do
!$omp end target teams distribute parallel do

   npp = dfft%nr3p( me )
   nnp = dfft%nnp
   IF( isgn == 1 ) THEN
! $ omp taskgroup
      DO ip = 1, nprocp
         ioff = dfft_iss( ip )
         nswip = dfft_nsp( ip )
!!$omp target teams distribute parallel do collapse(3) nowait
!$omp target teams distribute parallel do collapse(3)
         DO i = 0, batchsize-1
            DO cuf_j = 1, npp
               DO cuf_i = 1, nswip
                  it = ( ip - 1 ) * sendsiz + (cuf_i-1)*nppx + i*nppx*ncpx
                  mc = dfft_ismap( cuf_i + ioff )
                  f_aux( mc + ( cuf_j - 1 ) * nnp + i*nnr ) = f_aux2( cuf_j + it )
               ENDDO
            ENDDO
         ENDDO
!$omp end target teams distribute parallel do
      ENDDO
      !
   ELSE
      !
      DO gproc = 1, nprocp
         ioff = dfft_iss( gproc )
         nswip =  dfft_nsw( gproc )
#if defined(__NO_HIPKERN)
!$omp target teams distribute parallel do collapse(3)
         DO i = 0, batchsize-1
            DO cuf_j = 1, npp
              DO cuf_i = 1, nswip
                 mc = dfft_ismap( cuf_i + ioff )
                 it = (cuf_i-1) * nppx + ( gproc - 1 ) * sendsiz + i*nppx*ncpx
                 f_aux( mc + ( cuf_j - 1 ) * nnp + i*nnr ) = f_aux2( cuf_j + it )
               ENDDO
            ENDDO
         ENDDO
!$omp end target teams distribute parallel do
#else
         DO i = 0, batchsize-1
            CALL loop2d_scatter_hip( f_aux2(:), f_aux(:), dfft_ismap(ioff+1:ioff+nswip), nppx, &
                                     nnp, 2*(gproc-1)*sendsiz+2*i*nppx*ncpx, 2*i*nnr, npp, nswip,&
                                     dfft%a2a_comp )
         ENDDO
#endif
      ENDDO
      !
      CALL hipCheck(hipDeviceSynchronize())
      !
   END IF
   !
#endif

  RETURN

END SUBROUTINE fft_scatter_many_columns_to_planes_send_omp

SUBROUTINE fft_scatter_many_planes_to_columns_store_omp ( dfft, nr3x, nxx_, f_aux, f_aux2, ncp_, npp_, isgn, batchsize, &
                                batch_id, dfft_iss, dfft_nsw, dfft_nsp, dfft_ismap )
   !
   IMPLICIT NONE
   !
   TYPE (fft_type_descriptor), TARGET, INTENT(in) :: dfft
   INTEGER, INTENT(in)           :: nr3x, nxx_, isgn, ncp_ (:), npp_ (:)
   COMPLEX (DP), INTENT(inout)   :: f_aux(:), f_aux2(:)
   INTEGER, INTENT(IN) :: batchsize, batch_id

!-----------------------------------
   INTEGER, INTENT(IN) :: dfft_iss(:), dfft_nsw(:), dfft_nsp(:), dfft_ismap(:)
!--------------------------------------------

   INTEGER :: cuf_i, cuf_j, nswip
   INTEGER :: istat
#if defined(__MPI)
   INTEGER :: k, proc, ierr, me, nprocp, gproc, gcomm, i, kdest, kfrom
   INTEGER :: me_p, nppx, mc, j, npp, nnp, nnr, ii, it, ip, ioff, sendsiz, ncpx, ipp, nblk, nsiz
   !
   LOGICAL :: use_tg
   INTEGER :: iter, dest, sorc
   INTEGER :: istatus(MPI_STATUS_SIZE)

   me     = dfft%mype + 1
   !
   nprocp = dfft%nproc
   !
#ifdef __IPC
#ifndef __GPU_MPI
   CALL get_ipc_peers( dfft%IPC_PEER )
#endif
#endif
   !
   ncpx = maxval(ncp_)
   nppx = maxval(npp_)
   !
   IF ( dfft%nproc == 1 ) nppx = dfft%nr3x
   !
   sendsiz = batchsize * ncpx * nppx
   nnr     = dfft%nnr
   !
   ierr = 0
   !
   IF (isgn.gt.0) CALL fftx_error__ ('fft_scatter_many_planes_to_columns_store', 'isign is wrong', isgn )
   !
   !
   !  "backward" scatter from planes to columns
   !
   npp = dfft%nr3p( me )
   nnp = dfft%nnp
   IF( isgn == -1 ) THEN
! $ omp taskgroup
      DO iter = 1, nprocp
         IF(IAND(nprocp, nprocp-1) == 0) THEN
            dest = IEOR( me-1, iter-1 )
         ELSE
            dest = MOD(me-1 + (iter-1), nprocp)
         ENDIF
         ip = dest + 1
         ioff = dfft_iss( ip )
         nswip = dfft_nsp( ip )
!!$omp target teams distribute parallel do collapse(3) nowait
!$omp target teams distribute parallel do collapse(3)
         DO i = 0, batchsize-1
            DO cuf_j = 1, npp
               DO cuf_i = 1, nswip
                  mc = dfft_ismap( cuf_i + ioff )
                  it = ( ip - 1 ) * sendsiz + (cuf_i-1)*nppx + i*nppx*ncpx
                  f_aux2( cuf_j + it ) = f_aux( mc + ( cuf_j - 1 ) * nnp + i*nnr )
               ENDDO
            ENDDO
         ENDDO
!$omp end target teams distribute parallel do
      ENDDO
! $ omp end taskgroup
   ELSE
! $ omp taskgroup
      DO iter = 1, nprocp
         IF(IAND(nprocp, nprocp-1) == 0) THEN
            dest = IEOR( me-1, iter-1 )
         ELSE
            dest = MOD(me-1 + (iter-1), nprocp)
         ENDIF
         gproc = dest + 1
         ioff = dfft_iss( gproc )
         nswip = dfft_nsw( gproc )
!!$omp target teams distribute parallel do collapse(3) nowait
!$omp target teams distribute parallel do collapse(3)
         DO i = 0, batchsize-1
            DO cuf_j = 1, npp
               DO cuf_i = 1, nswip
                 mc = dfft_ismap( cuf_i + ioff )
                 it = (cuf_i-1) * nppx + ( gproc - 1 ) * sendsiz + i*nppx*ncpx
                 f_aux2( cuf_j + it ) = f_aux( mc + ( cuf_j - 1 ) * nnp + i*nnr )
               ENDDO
            ENDDO
         ENDDO
!$omp end target teams distribute parallel do
      ENDDO
! $ omp end taskgroup
   END IF

#ifndef __GPU_MPI
   DO proc = 1, nprocp
      IF (proc .ne. me) THEN
#ifdef __IPC
         IF(dfft%IPC_PEER( proc ) .eq. 0) THEN
            kdest = ( proc - 1 ) * sendsiz
         ENDIF
#else
         kdest = ( proc - 1 ) * sendsiz
#endif
!$omp target update from (f_aux2(kdest+1:kdest+sendsiz))
      ENDIF
   ENDDO
#endif
#endif

  RETURN

END SUBROUTINE fft_scatter_many_planes_to_columns_store_omp

SUBROUTINE fft_scatter_many_planes_to_columns_send_omp ( dfft, f_in, nr3x, nxx_, f_aux, f_aux2, ncp_, npp_, isgn, batchsize, batch_id )
   !
   IMPLICIT NONE
   !
   TYPE (fft_type_descriptor), INTENT(in) :: dfft
   INTEGER, INTENT(in)           :: nr3x, nxx_, isgn, ncp_(:), npp_(:)
   COMPLEX (DP), INTENT(inout) :: f_in(:), f_aux(:), f_aux2(:)
   INTEGER, INTENT(IN) :: batchsize, batch_id
   INTEGER :: istat
#if defined(__MPI)
   INTEGER :: k, offset, proc, ierr, me, nprocp, gproc, gcomm, i, kdest, kfrom
   INTEGER :: me_p, nppx, mc, j, npp, nnp, nnr, ii, it, ip, ioff, sendsiz, ncpx, ipp, nblk, nsiz

   INTEGER :: iter, dest, sorc, req_cnt, npp_gproc, npp_me
   INTEGER :: istatus(MPI_STATUS_SIZE)

   me     = dfft%mype + 1
   !
   nprocp = dfft%nproc
   !
   ncpx = maxval(ncp_) ! max number of sticks among processors ( should be of wave func )
   nppx = maxval(npp_) ! max size of the "Z" section of each processor in the nproc3 group along Z
   !
   IF ( dfft%nproc == 1 ) nppx = dfft%nr3x
   !
   sendsiz = batchsize * ncpx * nppx
   nnr     = dfft%nnr
#ifdef __IPC
   CALL get_ipc_peers( dfft%IPC_PEER )
#endif
   !

   ierr = 0
   IF (isgn.gt.0) CALL fftx_error__ ('fft_scatter_many_planes_to_columns_send', 'isign is wrong', isgn )

   !
   !  "backward" scatter from planes to columns
   !
   IF( nprocp == 1 ) GO TO 20
   !
   ! Communication takes place here:
   !  fractions of sticks will be moved to form complete sticks
   !
   gcomm = dfft%comm
   !
   ! JR Note: Holding off staging receives until buffer is packed.
   CALL start_clock ('A2A')
#ifdef __IPC
   ! TODO: possibly remove this barrier
   CALL MPI_Barrier( gcomm, ierr )
#endif
   req_cnt = 0

   DO iter = 2, nprocp
      IF(IAND(nprocp, nprocp-1) == 0) THEN
        sorc = IEOR( me-1, iter-1 )
      ELSE
        sorc = MOD(me-1 - (iter-1) + nprocp, nprocp)
      ENDIF
#ifdef __IPC
      IF(dfft%IPC_PEER( sorc + 1 ) .eq. 0) THEN
#endif
#ifdef __GPU_MPI
!$omp target data use_device_ptr(f_aux)
         call MPI_IRECV( f_aux((sorc)*sendsiz + 1), sendsiz, MPI_DOUBLE_COMPLEX, sorc, 0, gcomm, dfft%srh(req_cnt+1, batch_id), ierr )
!$omp end target data
#else
         call MPI_IRECV( f_aux((sorc)*sendsiz + 1), sendsiz, MPI_DOUBLE_COMPLEX, sorc, 0, gcomm, dfft%srh(req_cnt+1, batch_id), ierr )
#endif
         req_cnt = req_cnt + 1
#ifdef __IPC
      ENDIF
#endif
   ENDDO

   DO iter = 2, nprocp
      IF(IAND(nprocp, nprocp-1) == 0) THEN
        dest = IEOR( me-1, iter-1 )
      ELSE
        dest = MOD(me-1 + (iter-1), nprocp)
      ENDIF
#ifdef __IPC
      IF(dfft%IPC_PEER( dest + 1 ) .eq. 1) THEN
         CALL ipc_send( f_aux2_d((dest)*sendsiz + 1), sendsiz, f_aux_d((me-1)*sendsiz + 1), 0, dest, gcomm, ierr )
      ELSE
#endif
#ifdef __GPU_MPI
!$omp target data use_device_ptr(f_aux2)
         call MPI_ISEND( f_aux2((dest)*sendsiz + 1), sendsiz, MPI_DOUBLE_COMPLEX, dest, 0, gcomm, dfft%srh(req_cnt+1, batch_id), ierr )
!$omp end target data
#else
         call MPI_ISEND( f_aux2((dest)*sendsiz + 1), sendsiz, MPI_DOUBLE_COMPLEX, dest, 0, gcomm, dfft%srh(req_cnt+1, batch_id), ierr )
#endif
         req_cnt = req_cnt + 1
#ifdef __IPC
      ENDIF
#endif
   ENDDO

   ! move the data that we already have (and therefore doesn't to pass through MPI avove)
   ! directly from f_aux_2 to f_in. The rest will be done below.
   offset = 0
   DO proc = 1, me-1
      offset = offset + npp_ ( proc )
   ENDDO
   npp_me=npp_(me)
!$omp target teams distribute parallel do collapse(2)
    DO k = 1, batchsize * ncpx
       DO i = 1, npp_me
         f_in( offset + i + (k-1)*nr3x ) = f_aux2( (me - 1) * sendsiz + i + (k-1)*nppx )
       END DO
    END DO
!$omp end target teams distribute parallel do
   IF(req_cnt .gt. 0) then
      call MPI_WAITALL(req_cnt, dfft%srh(1:req_cnt, batch_id), MPI_STATUSES_IGNORE, ierr)
   ENDIF
#ifdef __IPC
   call sync_ipc_sends( gcomm )
   call MPI_Barrier( gcomm, ierr )
#endif
   CALL stop_clock ('A2A')

   IF( abs(ierr) /= 0 ) CALL fftx_error__ ('fft_scatter', 'info<>0', abs(ierr) )
   !
   !  Store contiguously the (remaining) columns (one already done above).
   !
   !! f_in = 0.0_DP
   !
   offset = 0
!$omp target update to (f_aux)
! $ omp taskgroup
   DO gproc = 1, nprocp
      kdest = ( gproc - 1 ) * sendsiz
      kfrom = offset
      npp_gproc=npp_(gproc)
      IF (gproc .ne. me) THEN ! (me already done above)
#ifdef __GPU_MPI
!$omp target data use_device_ptr(f_in, f_aux)
        DO k = 1, batchsize * ncpx
           DO i = 1, npp_gproc
             f_in( kfrom + i + (k-1)*nr3x ) = f_aux( kdest + i + (k-1)*nppx )
           END DO
        END DO
!$omp end target data
#else
#ifdef __IPC
        IF(dfft%IPC_PEER( gproc ) .eq. 1) THEN
!$omp target teams distribute parallel do collapse(2) nowait
           DO k = 1, batchsize * ncpx
              DO i = 1, npp_gproc
                f_in( kfrom + (k-1)*nr3x + i ) = f_aux( kdest + (k-1)*nppx + i )
              END DO
           END DO
!$omp end target teams distribute parallel do
        ELSE
!$omp target teams distribute parallel do collapse(2) nowait
           DO k = 1, batchsize * ncpx
              DO i = 1, npp_gproc
                f_in( kfrom + (k-1)*nr3x + i ) = f_aux( kdest + (k-1)*nppx + i )
              END DO
           END DO
!$omp end target teams distribute parallel do
        ENDIF
#else
!!$omp target teams distribute parallel do collapse(2) nowait
!$omp target teams distribute parallel do collapse(2)
           DO k = 1, batchsize * ncpx
              DO i = 1, npp_gproc
                f_in( kfrom + (k-1)*nr3x + i ) = f_aux( kdest + (k-1)*nppx + i )
              END DO
           END DO
!$omp end target teams distribute parallel do
#endif
#endif
      ENDIF
      offset = offset + npp_gproc
   ENDDO
! $ omp end taskgroup

20 CONTINUE

#endif

   RETURN

END SUBROUTINE fft_scatter_many_planes_to_columns_send_omp
!
!=----------------------------------------------------------------------=!
END MODULE fft_scatter_2d_omp
!=----------------------------------------------------------------------=!
#endif
