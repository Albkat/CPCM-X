program COSMO
   use element_dict
   use globals
   use sort
   use initialize_cosmo
   use sigma_av
   use sac_mod
   use bonding
   use profile
   use pr
   use crs
   use mctc_env, only : wp
   use sdm
   implicit none
   integer :: oh_sol, nh_sol, near_sol
   real(8), dimension(:), allocatable :: solute_su, solute_area, solute_sv, solute_sv0,solvent_pot,solute_pot
   real(8), dimension(:), allocatable :: solvent_su, solvent_area, solvent_sv, solvent_sv0, solute_svt, solvent_svt
   real(8), dimension(:), allocatable :: sol_pot, solv_pot, solvent_ident, solute_ident
   real(8), dimension(:,:), allocatable :: solvent_xyz, solute_xyz, solvat_xyz, solat_xyz, solat2
   character(2), dimension(:), allocatable :: solute_elements, solvent_elements, solute_hb, solvent_hb
   logical, dimension(:,:), allocatable :: solute_bonds, solvent_bonds
   logical, dimension(:), allocatable :: solute_rings
   real(8), dimension(3,0:50) :: solvent_sigma3, solute_sigma3
   character(20) :: solvent, solute
   !real(8), dimension(10) :: param
   real(8) :: id_scr,gas_chem,chem_pot_sol, T, solute_volume, solvent_volume,&
      &solute_energy, solvent_energy, solvent_sigma(0:50), solute_sigma(0:50),sac_disp(2)
   logical :: gas,sig_in
   integer :: sol_nat, i
   integer, allocatable :: int_ident(:)
   real(wp), allocatable :: surface(:), dsdr(:,:,:)
  

   type(DICT_STRUCT), pointer :: r_cav, disp_con
  
   gas=.TRUE.
   !! ------------------------------------------------------------ 
   !! Read Command Line Arguments and set Parameters accordingly
   !! ------------------------------------------------------------

   Call getargs(solvent,solute,T,sig_in)
   Call initialize_param(r_cav,disp_con)
   Call init_pr

   if (ML) write(*,*) "Machine Learning Mode selected. Will Only Write an ML.data file." !! ML Mode deprecated

   !! ----------------------------------------------------------------------------------
   !! Read Sigma Profiles (--sigma) - Not the default case
   !! ----------------------------------------------------------------------------------
   T=SysTemp
   if (sig_in) then

      write(*,*) "Reading Sigma Profile"
      Call read_singlesig(solvent_sigma,trim(solvent)//".sigma",solvent_volume)
      Call read_singlesig(solute_sigma,trim(solute)//".sigma",solute_volume)
      
      Call read_triplesig(solvent_sigma3,trim(solvent)//".sigma",solvent_volume)
      Call read_triplesig(solute_sigma3,trim(solute)//".sigma",solute_volume)
   else
   !! ----------------------------------------------------------------------------------
   !! Create the Sigma Profile from COSMO files
   !! ----------------------------------------------------------------------------------

      write(*,*) "Creating Sigma Profile from COSMO data"

   !! ------------------------------------------------------------------------------------
   !! Read necessary COSMO Data
   !! ------------------------------------------------------------------------------------
      Call read_cosmo(trim(solvent)//".cosmo",solvent_elements,solvent_ident,solvent_xyz,solvent_su,&
          &solvent_area,solvent_pot,solvent_volume,solvent_energy,solvat_xyz)
      Call read_cosmo(trim(solute)//".cosmo",solute_elements,solute_ident, solute_xyz, solute_su,&
         &solute_area,solute_pot,solute_volume,solute_energy,solat_xyz)
 
   !! ------------------------------------------------------------------------------------
   !! Sigma Charge Averaging and creating of a single Sigma Profile for Solute and Solvent
   !! ------------------------------------------------------------------------------------

      Call average_charge(param(1), solvent_xyz,solvent_su,solvent_area,solvent_sv)
      Call average_charge(param(1), solute_xyz, solute_su, solute_area, solute_sv)
      Call single_sigma(solvent_sv,solvent_area,solvent_sigma,trim(solvent))
      Call single_sigma(solute_sv,solute_area,solute_sigma,trim(solute))

      allocate (int_ident(int(maxval(solute_ident))))
     ! write(*,*) size(int_ident)
     ! write(*,*) size(solute_elements)
     ! write(*,*) size(solat_xyz(1,:))
      do i=1,int(maxval(solute_ident))
         int_ident(i)=i
      end do
   
      Call get_surface_area(int_ident,solute_elements,solat_xyz,1.3_wp)

   !! ------------------------------------------------------------------------------------
   !! Determination of HB Grouping and marking of Atom that are able to form HBs.
   !! Determination of Atoms in Rings, necessary for the PR2018 EOS
   !! ------------------------------------------------------------------------------------

      Call det_bonds(solute_ident,solat_xyz,solute_elements,solute_bonds,oh_sol,nh_sol)
      Call hb_grouping(solute_ident,solute_elements,solute_bonds,solute_hb)
      Call det_bonds(solvent_ident,solvat_xyz,solvent_elements,solvent_bonds)
      Call hb_grouping(solvent_ident,solvent_elements,solvent_bonds,solvent_hb)
      
      Call det_rings(solute_ident,solute_bonds,solute_rings,near_sol)


   !! ------------------------------------------------------------------------------------
   !! Creation of a splitted Sigma Profile, necessary for sac2010/sac2013
   !! ------------------------------------------------------------------------------------

      if (.NOT. (model .EQ. "sac")) then
      Call split_sigma(solvent_sv,solvent_area,solvent_hb,solvent_ident,solvent_elements,&
            &solvent_sigma3,trim(solvent))
      Call split_sigma(solute_sv,solute_area,solute_hb,solute_ident,solute_elements,&
            &solute_sigma3,trim(solute))
      end if

   !! ------------------------------------------------------------------------------------
   !! Exit here if you only want Sigma Profiles to be created 
   !! ------------------------------------------------------------------------------------
      if (onlyprof) then;
         write(*,*) "Only Profile mode choosen, exiting."
         stop
      end if
   end if
   

   !! ------------------------------------------------------------------------------------
   !! Choice of the different post COSMO Models (sac,sac2010,sac2013,COSMO-RS)
   !! ------------------------------------------------------------------------------------

   select case (trim(model))
      case ("sac")
         !Calculation of the Gas Phase (ideal gas --> ideal conductor)
         Call sac_gas(solute_energy,id_scr,solute_area,solute_sv,solute_su,solute_pot)
         !Calculation of the Solvent Phase (ideal conductor --> real solution)
         Call sac_2005(solvent_sigma,solute_sigma,solvent_volume,solute_volume)
         !Calculation of NES contributions (real gas --> ideal gas?)
         if (ML) Call pr2018(solute_area,solute_elements,solute_ident,oh_sol,nh_sol,near_sol)

      case("sac2010")
         
         Call sac_gas(solute_energy,id_scr,solute_area,solute_sv,solute_su,solute_pot)
         Call sac_2010(solvent_sigma3,solute_sigma3,solvent_volume,solute_volume)
         Call pr2018(solute_area,solute_elements,solute_ident,oh_sol,nh_sol,near_sol)

   !! ------------------------------------------------------------------------------------
   !! The SAC 2013 Routine is not fully implemented and not supported anymore
   !! ------------------------------------------------------------------------------------
    !  case("sac2013")

     !    Call sac_gas(solute_energy,id_scr,solute_area,solute_sv,solute_su,solute_pot)
     !    Call sac2013_disp(trim(solvent),solvent_bonds,solvent_ident,solvent_elements,disp_con,sac_disp(1))
     !    Call sac2013_disp(trim(solute),solute_bonds,solute_ident,solute_elements,disp_con,sac_disp(2))
     !    Call sac_2013(solvent_sigma3,solute_sigma3,solvent_volume,solute_volume,sac_disp)
     !    Call pr2018(solute_area,solute_elements,solute_ident,oh_sol,nh_sol,near_sol)
      case ("crs")
   

         !! COSMO-RS calculation starts here !!

         ! Calculate sv0,svt for COSMO-RS

         Call average_charge(param(2), solvent_xyz,solvent_su,solvent_area,solvent_sv0)
         Call ortho_charge(solvent_sv,solvent_sv0,solvent_svt)
      
         Call average_charge(param(2), solute_xyz, solute_su, solute_area, solute_sv0)
         Call ortho_charge(solute_sv,solute_sv0,solute_svt)

         ! Calcualtion of Gas Phase energies

         if (gas) then
            Call calcgas(solute_energy,id_scr,gas_chem,solute_area,solute_sv,solute_su,&
               &solute_pot,solute_elements,solute_ident,disp_con, T,r_cav)
         end if

         ! Computation of COSMO-RS equations (here may be something wrong atm)

         Call compute_solvent(solv_pot,solvent_sv,solvent_svt,solvent_area,T,500,0.0001,solvent_ident,solvent_hb)
         Call compute_solute(sol_pot,solv_pot,solute_sv,solute_svt,solvent_sv,&
         &solvent_svt,solute_area,solvent_area,T,chem_pot_sol,solute_ident,solvent_ident,solute_elements,solvent_hb)
  
         write(*,*) "calc_gas_chem: ", gas_chem
         write(*,*) "calc_sol_chem: ", chem_pot_sol
         write(*,*) "G_solvshift: ", chem_pot_sol-gas_chem-4.28!-R*T*Jtokcal*log((solute_volume*(BtoA**3.0_8)*N_a*1000_8*10E-30)/22.414)
         deallocate(solute_su,solute_sv,solute_sv0,solvent_su,solvent_sv,&
         &solvent_sv0,solvent_area,solute_area,solvent_xyz,solute_xyz,&
         &solv_pot,sol_pot)
         stop
      end select
      if (ML) then
         write(*,*) "Writing ML data in ML.data"
         Call System("paste --delimiters='' ML.energy ML.gamma ML.pr > ML.data")
         Call System ("rm ML.energy ML.pr")
      else if (model .NE. "crs") then
         write(*,*) "Free Energy contributions:"
         write(*,*) "Ideal State (dG_is):", dG_is
         write(*,*) "Averaging correction (dG_cc):", dG_cc
         write(*,*) "restoring free energy (dG_res):", dG_res
         write(*,*) "SMD Contribution (dG_CDS):", dG_disp
         write(*,*) "conversion shift bar to mol/l: ", dG_shift
         write(*,*) "-------------------------------------------------"
         write(*,*) "solvation free energy: ", dG_is+dG_cc+dG_res+dG_disp+dG_shift
      end if


     ! deallocate(solute_su,solute_sv,solute_svt,solute_sv0,solvent_su,solvent_sv,&
     !    &solvent_svt,solvent_sv0,solvent_area,solute_area,solvent_xyz,solute_xyz,&
     !    &solv_pot,sol_pot)
   
end program COSMO

