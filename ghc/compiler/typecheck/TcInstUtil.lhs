%
% (c) The GRASP/AQUA Project, Glasgow University, 1992-1998
%
\section[TcInstUtil]{Utilities for typechecking instance declarations}

The bits common to TcInstDcls and TcDeriv.

\begin{code}
module TcInstUtil (
	InstInfo(..),
	buildInstanceEnvs,
	classDataCon
    ) where

#include "HsVersions.h"

import RnHsSyn		( RenamedMonoBinds, RenamedSig )

import CmdLineOpts	( opt_AllowOverlappingInstances )
import TcMonad
import Inst		( InstanceMapper )

import Bag		( bagToList, Bag )
import Class		( ClassInstEnv, Class )
import Var		( TyVar, Id )
import SpecEnv		( emptySpecEnv, addToSpecEnv )
import Maybes		( MaybeErr(..), mkLookupFunDef )
import Name		( getSrcLoc )
import SrcLoc		( SrcLoc )
import Type		( ThetaType, Type )
import PprType		( pprConstraint )
import Class		( classTyCon )
import DataCon		( DataCon )
import TyCon		( tyConDataCons )
import Util		( equivClasses, assertPanic )
import Outputable
\end{code}

    instance c => k (t tvs) where b

\begin{code}
data InstInfo
  = InstInfo
      Class	        -- Class, k
      [TyVar]		-- Type variables, tvs
      [Type]		-- The types at which the class is being instantiated
      ThetaType		-- inst_decl_theta: the original context, c, from the
			--   instance declaration.  It constrains (some of)
			--   the TyVars above
      Id		-- The dfun id
      RenamedMonoBinds	-- Bindings, b
      SrcLoc		-- Source location assoc'd with this instance's defn
      [RenamedSig]	-- User pragmas recorded for generating specialised instances
\end{code}


%************************************************************************
%*									*
\subsection{Creating instance related Ids}
%*									*
%************************************************************************

A tiny function which doesn't belong anywhere else.
It makes a nasty mutual-recursion knot if you put it in Class.

\begin{code}
classDataCon :: Class -> DataCon
classDataCon clas = case tyConDataCons (classTyCon clas) of
		      (dict_constr:no_more) -> ASSERT( null no_more ) dict_constr 
\end{code}		      

%************************************************************************
%*									*
\subsection{Converting instance info into suitable InstEnvs}
%*									*
%************************************************************************

\begin{code}
buildInstanceEnvs :: Bag InstInfo
		  -> NF_TcM s InstanceMapper

buildInstanceEnvs info
  = let
    	icmp :: InstInfo -> InstInfo -> Ordering
    	(InstInfo c1 _ _ _ _ _ _ _) `icmp` (InstInfo c2 _ _ _ _ _ _ _)
	  = c1 `compare` c2

	info_by_class = equivClasses icmp (bagToList info)
    in
    mapNF_Tc buildInstanceEnv info_by_class    `thenNF_Tc` \ inst_env_entries ->
    let
	class_lookup_fn = mkLookupFunDef (==) inst_env_entries emptySpecEnv
    in
    returnNF_Tc class_lookup_fn
\end{code}

\begin{code}
buildInstanceEnv :: [InstInfo]		-- Non-empty, and all for same class
		 -> NF_TcM s (Class, ClassInstEnv)

buildInstanceEnv inst_infos@((InstInfo clas _ _ _ _ _ _ _) : _)
  = foldrNF_Tc addClassInstance
	    emptySpecEnv
	    inst_infos				`thenNF_Tc` \ class_inst_env ->
    returnNF_Tc (clas, class_inst_env)
\end{code}

@addClassInstance@ adds the appropriate stuff to the @ClassInstEnv@
based on information from a single instance declaration.  It complains
about any overlap with an existing instance.

\begin{code}
addClassInstance
    :: InstInfo
    -> ClassInstEnv
    -> NF_TcM s ClassInstEnv

addClassInstance 
    (InstInfo clas inst_tyvars inst_tys _
	      dfun_id _ src_loc _)
    class_inst_env
  = 	-- Add the instance to the class's instance environment
    case addToSpecEnv opt_AllowOverlappingInstances 
		      class_inst_env inst_tyvars inst_tys dfun_id of
	Failed (ty', dfun_id')    -> addErrTc (dupInstErr clas (inst_tys, src_loc) 
							       (ty', getSrcLoc dfun_id'))
						`thenNF_Tc_`
				     returnNF_Tc class_inst_env

	Succeeded class_inst_env' -> returnNF_Tc class_inst_env'
\end{code}

\begin{code}
dupInstErr clas info1@(tys1, locn1) info2@(tys2, locn2)
	-- Overlapping/duplicate instances for given class; msg could be more glamourous
  = hang (ptext SLIT("Duplicate or overlapping instance declarations"))
         4 (sep [ptext SLIT("for") <+> quotes (pprConstraint clas tys1),
		 nest 4 (sep [ptext SLIT("at")  <+> ppr locn1,
		    	      ptext SLIT("and") <+> ppr locn2])])
\end{code}
