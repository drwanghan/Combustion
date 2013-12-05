module chemterm_module

  use meth_params_module, only : NVAR, URHO, UEDEN, UMX, UMY, UMZ, UTEMP, UFS, NSPEC, &
       do_cc_burning, split_burning
  use burner_module, only : burn, compute_rhodYdt, init_burn_linear, burn_linear
  use eos_module, only : eos_get_T

  implicit none

  private

  public :: chemterm, dUdt_chem

contains

  subroutine chemterm(lo, hi, U, Ulo, Uhi, dt)
    integer, intent(in) :: lo(3), hi(3), Ulo(3), Uhi(3)
    double precision, intent(inout) :: U(Ulo(1):Uhi(1),Ulo(2):Uhi(2),Ulo(3):Uhi(3),NVAR)
    double precision, intent(in) :: dt

    if (split_burning) then
       call chemterm_split(lo, hi, U, Ulo, Uhi, dt)
    else if (do_cc_burning) then
       call chemterm_cellcenter(lo, hi, U, Ulo, Uhi, dt)
    else
       call chemterm_gauss(lo, hi, U, Ulo, Uhi, dt)
    end if

  end subroutine chemterm

  subroutine chemterm_gauss(lo, hi, U, Ulo, Uhi, dt)
    use weno_module, only : cellavg2gausspt_3d
    integer, intent(in) :: lo(3), hi(3), Ulo(3), Uhi(3)
    double precision, intent(inout) :: U(Ulo(1):Uhi(1),Ulo(2):Uhi(2),Ulo(3):Uhi(3),NVAR)
    double precision, intent(in) :: dt

    integer :: i, j, k, n, g
    logical :: force_new_J
    double precision :: rhot(8), rhoinv, ei
    double precision :: Yt0(nspec+1,8), Yt(nspec+1,8), dry(nspec)
    double precision, allocatable :: UG(:,:,:,:,:)

    allocate(UG(lo(1):hi(1),lo(2):hi(2),lo(3):hi(3),8,NVAR))

    !$omp parallel private(i,j,k,n,g,rhot,rhoinv,ei,Yt0,Yt,dry,force_new_J)

    !$omp do
    do n=1,NVAR
       call cellavg2gausspt_3d(lo,hi, U(:,:,:,n), Ulo,Uhi, UG(:,:,:,:,n), lo,hi)
    end do
    !$omp end do

    force_new_J = .true.  ! always recompute Jacobina when a new FAB starts

    !$omp do collapse(2)
    do k=lo(3),hi(3)
       do j=lo(2),hi(2)
          do i=lo(1),hi(1)

             do g=1,8

                rhot = 0.d0
                do n=1,NSPEC
                   Yt(n,g) = UG(i,j,k,g,UFS+n-1)
                   rhot(g) = rhot(g) + Yt(n,g)
                end do
                rhoinv = 1.d0/rhot(g)

                Yt(1:nspec,g) = Yt(1:nspec,g) * rhoinv
                Yt(nspec+1,g) = UG(i,j,k,g,UTEMP)

                ei = rhoinv*( UG(i,j,k,g,UEDEN) - 0.5d0*rhoinv*(UG(i,j,k,g,UMX)**2 &
                     + UG(i,j,k,g,UMY)**2 + UG(i,j,k,g,UMZ)**2) )

                call eos_get_T(Yt(nspec+1,g), ei, Yt(1:nspec,g))

             end do

             Yt0 = Yt
             call burn(8, rhot, Yt, dt, force_new_J)

             force_new_J = .false.

             dry = 0.d0
             do g=1,8
                do n=1,nspec
                   dry(n) = dry(n) + rhot(g)*(Yt(n,g)-Yt0(n,g))
                end do
             end do
             
             ! note that the sum of dry is zero
             do n=1,nspec
                U(i,j,k,UFS+n-1) = U(i,j,k,UFS+n-1) + 0.125d0*dry(n)
             end do

          end do
       end do
    end do
    !$omp end do
    !$omp end parallel

    deallocate(UG)

  end subroutine chemterm_gauss


  subroutine chemterm_cellcenter(lo, hi, U, Ulo, Uhi, dt)
    use convert_3d_module, only : cellavg2cc_3d, cc2cellavg_3d
    integer, intent(in) :: lo(3), hi(3), Ulo(3), Uhi(3)
    double precision, intent(inout) :: U(Ulo(1):Uhi(1),Ulo(2):Uhi(2),Ulo(3):Uhi(3),NVAR)
    double precision, intent(in) :: dt

    integer :: i, j, k, n
    logical :: force_new_J
    double precision :: rhot(1), rhoinv, ei, fac
    double precision :: Yt(nspec+1)
    double precision, allocatable :: Ucc(:,:,:,:)

    allocate(Ucc(lo(1)-1:hi(1)+1,lo(2)-1:hi(2)+1,lo(3)-1:hi(3)+1,NVAR))

    !$omp parallel private(i,j,k,n,rhot,rhoinv,ei,fac,Yt,force_new_J)

    !$omp do
    do n=1,NVAR
       call cellavg2cc_3d(lo-1,hi+1, U(:,:,:,n), Ulo,Uhi, Ucc(:,:,:,n), lo-1,hi+1)
    end do
    !$omp end do

    force_new_J = .true.  ! always recompute Jacobina when a new FAB starts

    !$omp do collapse(2)
    do k=lo(3)-1,hi(3)+1
       do j=lo(2)-1,hi(2)+1
          do i=lo(1)-1,hi(1)+1

             rhot = 0.d0
             do n=1,NSPEC
                Yt(n) = Ucc(i,j,k,UFS+n-1)
                rhot(1) = rhot(1) + Yt(n)
             end do
             rhoinv = 1.d0/rhot(1)

             Yt(1:nspec) = Yt(1:nspec) * rhoinv
             Yt(nspec+1) = Ucc(i,j,k,UTEMP)

             ei = rhoinv*( Ucc(i,j,k,UEDEN) - 0.5d0*rhoinv*(Ucc(i,j,k,UMX)**2 &
                  + Ucc(i,j,k,UMY)**2 + Ucc(i,j,k,UMZ)**2) )

             call eos_get_T(Yt(nspec+1), ei, Yt(1:nspec))

             call burn(1, rhot, Yt, dt, force_new_J)

             force_new_J = .false.

             do n=1,nspec
                Ucc(i,j,k,UFS+n-1) = rhot(1)*Yt(n)
             end do
             U(i,j,k,UTEMP) = Yt(nspec+1)

          end do
       end do
    end do
    !$omp end do

    !$omp do
    do n=UFS,UFS+nspec-1
       call cc2cellavg_3d(lo,hi, Ucc(:,:,:,n), lo-1,hi+1, U(:,:,:,n), Ulo,Uhi)
    end do
    !$omp end do

    !$omp do collapse(2)
    do k=lo(3),hi(3)
       do j=lo(2),hi(2)
          do i=lo(1),hi(1)
             rhot = 0.d0
             do n=1,NSPEC
                rhot(1) = rhot(1) + U(i,j,k,UFS+n-1)
             end do
             fac = U(i,j,k,URHO)/rhot(1)
             do n=1,NSPEC
                U(i,j,k,UFS+n-1) = U(i,j,k,UFS+n-1) * fac
             end do
          end do
       end do
    end do
    !$omp end do

    !$omp end parallel

    deallocate(Ucc)

  end subroutine chemterm_cellcenter


  subroutine dUdt_chem(lo, hi, U, Ulo, Uhi, Ut, Utlo, Uthi)
    use weno_module, only : cellavg2gausspt_3d
    integer, intent(in) :: lo(3), hi(3), Ulo(3), Uhi(3), Utlo(3), Uthi(3)
    double precision, intent(in ) ::  U( Ulo(1): Uhi(1), Ulo(2): Uhi(2), Ulo(3): Uhi(3),NVAR)
    double precision, intent(out) :: Ut(Utlo(1):Uthi(1),Utlo(2):Uthi(2),Utlo(3):Uthi(3),NVAR)

    integer :: i, j, k, n, g, np
    double precision :: rhoinv, ei
    double precision :: rho(lo(1):hi(1)), T(lo(1):hi(1))
    double precision :: Ytmp(nspec)
    double precision :: Y(lo(1):hi(1),nspec), rdYdt(lo(1):hi(1),nspec)
    double precision, allocatable :: UG(:,:,:,:,:)

    np = hi(1)-lo(1)+1

    allocate(UG(lo(1):hi(1),lo(2):hi(2),lo(3):hi(3),8,NVAR))

    !$omp parallel private(i,j,k,n,g,rhoinv,ei,rho,T,Ytmp,Y,rdYdt)

    !$omp do
    do n=1,NVAR
       do k=lo(3),hi(3)
       do j=lo(2),hi(2)
       do i=lo(1),hi(1)
          Ut(i,j,k,n) = 0.d0
       end do
       end do
       end do
    end do
    !$omp end do

    !$omp do
    do n=1,NVAR
       call cellavg2gausspt_3d(lo,hi, U(:,:,:,n), Ulo,Uhi, UG(:,:,:,:,n), lo,hi)
    end do
    !$omp end do

    do g=1,8
       !$omp do collapse(2)
       do k=lo(3),hi(3)
       do j=lo(2),hi(2)

          do i=lo(1),hi(1)
             rho(i) = 0.d0
             do n=1,nspec
                Y(i,n) = UG(i,j,k,g,UFS+n-1)
                rho(i) = rho(i) + Y(i,n)
             end do
             rhoinv = 1.d0/rho(i)

             do n=1,nspec
                Y(i,n) = Y(i,n) * rhoinv
                Ytmp(n) = Y(i,n)
             end do

             ei = rhoinv*( UG(i,j,k,g,UEDEN) - 0.5d0*rhoinv*(UG(i,j,k,g,UMX)**2 &
                  + UG(i,j,k,g,UMY)**2 + UG(i,j,k,g,UMZ)**2) )

             T(i) = UG(i,j,k,g,UTEMP)
             call eos_get_T(T(i), ei, Ytmp)
          end do

          call compute_rhodYdt(np,rho,T,Y,rdYdt)

          do n=1,nspec
             do i=lo(1),hi(1)
                Ut(i,j,k,UFS+n-1) = Ut(i,j,k,UFS+n-1) + 0.125d0*rdYdt(i,n)
             end do
          end do

       end do
       end do
       !$omp end do
    end do

    !$omp end parallel

    deallocate(UG)

  end subroutine dUdt_chem


  subroutine chemterm_split(lo, hi, U, Ulo, Uhi, dt)
    use weno_module, only : cellavg2gausspt_3d
    integer, intent(in) :: lo(3), hi(3), Ulo(3), Uhi(3)
    double precision, intent(inout) :: U(Ulo(1):Uhi(1),Ulo(2):Uhi(2),Ulo(3):Uhi(3),NVAR)
    double precision, intent(in) :: dt

    integer :: i, j, k, n, g
    logical :: force_new_J
    double precision :: rhot(8), rhoinv, ei, rho0(1)
    double precision :: Yt0(nspec+1,8), Yt(nspec+1,8), Y0(nspec+1), dry(nspec)
    double precision, allocatable :: UG(:,:,:,:,:)

    allocate(UG(lo(1):hi(1),lo(2):hi(2),lo(3):hi(3),8,NVAR))

    !$omp parallel private(i,j,k,n,g,rhot,rhoinv,ei,Yt0,Yt,dry,force_new_J,rho0,Y0)

    !$omp do
    do n=1,NVAR
       call cellavg2gausspt_3d(lo,hi, U(:,:,:,n), Ulo,Uhi, UG(:,:,:,:,n), lo,hi)
    end do
    !$omp end do

    force_new_J = .true.  ! always recompute Jacobina when a new FAB starts

    !$omp do collapse(2)
    do k=lo(3),hi(3)
       do j=lo(2),hi(2)
          do i=lo(1),hi(1)

             Y0 = 0.d0
             rho0(1) = 0.d0

             do g=1,8

                rhot = 0.d0
                do n=1,NSPEC
                   Yt(n,g) = UG(i,j,k,g,UFS+n-1)
                   rhot(g) = rhot(g) + Yt(n,g)
                end do
                rhoinv = 1.d0/rhot(g)

                Yt(1:nspec,g) = Yt(1:nspec,g) * rhoinv
                Yt(nspec+1,g) = UG(i,j,k,g,UTEMP)

                ei = rhoinv*( UG(i,j,k,g,UEDEN) - 0.5d0*rhoinv*(UG(i,j,k,g,UMX)**2 &
                     + UG(i,j,k,g,UMY)**2 + UG(i,j,k,g,UMZ)**2) )

                call eos_get_T(Yt(nspec+1,g), ei, Yt(1:nspec,g))

                Y0 = Y0 + 0.125d0*Yt(:,g)
                rho0(1) = rho0(1) + 0.125d0*rhot(g)

             end do

             do g=1,8
                do n=1,nspec+1
                   Yt0(n,g) = Yt(n,g)
                   Yt(n,g) = Yt(n,g) - Y0(n)
                end do
             end do

             call burn(1, rho0(1), Y0, dt, force_new_J)

             force_new_J = .false.

             call init_burn_linear(rho0(1), Y0, dt)

             do g=1,8
                call burn_linear(Yt(1:nspec,g))
                Yt(:,g) = Yt(:,g) + Y0
             end do

             dry = 0.d0
             do g=1,8
                do n=1,nspec
                   dry(n) = dry(n) + rhot(g)*(Yt(n,g)-Yt0(n,g))
                end do
             end do

             ! note that the sum of dry is zero
             do n=1,nspec
                U(i,j,k,UFS+n-1) = U(i,j,k,UFS+n-1) + 0.125d0*dry(n)
             end do

          end do
       end do
    end do
    !$omp end do
    !$omp end parallel

    deallocate(UG)

  end subroutine chemterm_split

end module chemterm_module
