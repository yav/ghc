%
% (c) The GRASP/AQUA Project, Glasgow University, 1992-1998
%
\section[TcBinds]{TcBinds}

\begin{code}
module TcBinds ( tcBindsAndThen, tcTopBindsAndThen,
	         tcPragmaSigs, tcBindWithSigs ) where

#include "HsVersions.h"

import {-# SOURCE #-} TcGRHSs ( tcGRHSsAndBinds )
import {-# SOURCE #-} TcExpr  ( tcExpr )

import HsSyn		( HsExpr(..), HsBinds(..), MonoBinds(..), Sig(..), InPat(..), StmtCtxt(..),
			  collectMonoBinders, andMonoBindList, andMonoBinds
			)
import RnHsSyn		( RenamedHsBinds, RenamedSig, RenamedMonoBinds )
import TcHsSyn		( TcHsBinds, TcMonoBinds,
			  TcIdOcc(..), TcIdBndr, 
			  tcIdType, zonkId
			)

import TcMonad
import Inst		( Inst, LIE, emptyLIE, mkLIE, plusLIE, plusLIEs, InstOrigin(..),
			  newDicts, tyVarsOfInst, instToId,
			)
import TcEnv		( tcExtendLocalValEnv, tcExtendEnvWithPat, 
			  tcLookupLocalValueOK,
			  newSpecPragmaId,
			  tcGetGlobalTyVars, tcExtendGlobalTyVars
			)
import TcMatches	( tcMatchesFun )
import TcSimplify	( tcSimplify, tcSimplifyAndCheck )
import TcMonoType	( tcHsTcType, checkSigTyVars,
			  TcSigInfo(..), tcTySig, maybeSig, sigCtxt
			)
import TcPat		( tcVarPat, tcPat )
import TcSimplify	( bindInstsOfLocalFuns )
import TcType		( TcType, TcThetaType,
			  TcTyVar,
			  newTyVarTy, newTcTyVar, tcInstTcType,
			  zonkTcType, zonkTcTypes, zonkTcThetaType )
import TcUnify		( unifyTauTy, unifyTauTyLists )

import Id		( mkUserId )
import Var		( idType, idName, setIdInfo )
import IdInfo		( IdInfo, noIdInfo, setInlinePragInfo, InlinePragInfo(..) )
import Name		( Name )
import Type		( mkTyVarTy, tyVarsOfTypes,
			  splitSigmaTy, mkForAllTys, mkFunTys, getTyVar, 
			  mkDictTy, splitRhoTy, mkForAllTy, isUnLiftedType, 
			  isUnboxedType, openTypeKind, 
			  unboxedTypeKind, boxedTypeKind
			)
import Var		( TyVar, tyVarKind )
import VarSet
import Bag
import Util		( isIn )
import BasicTypes	( TopLevelFlag(..), RecFlag(..) )
import SrcLoc           ( SrcLoc )
import Outputable
\end{code}


%************************************************************************
%*									*
\subsection{Type-checking bindings}
%*									*
%************************************************************************

@tcBindsAndThen@ typechecks a @HsBinds@.  The "and then" part is because
it needs to know something about the {\em usage} of the things bound,
so that it can create specialisations of them.  So @tcBindsAndThen@
takes a function which, given an extended environment, E, typechecks
the scope of the bindings returning a typechecked thing and (most
important) an LIE.  It is this LIE which is then used as the basis for
specialising the things bound.

@tcBindsAndThen@ also takes a "combiner" which glues together the
bindings and the "thing" to make a new "thing".

The real work is done by @tcBindWithSigsAndThen@.

Recursive and non-recursive binds are handled in essentially the same
way: because of uniques there are no scoping issues left.  The only
difference is that non-recursive bindings can bind primitive values.

Even for non-recursive binding groups we add typings for each binder
to the LVE for the following reason.  When each individual binding is
checked the type of its LHS is unified with that of its RHS; and
type-checking the LHS of course requires that the binder is in scope.

At the top-level the LIE is sure to contain nothing but constant
dictionaries, which we resolve at the module level.

\begin{code}
tcTopBindsAndThen, tcBindsAndThen
	:: (RecFlag -> TcMonoBinds s -> thing -> thing)		-- Combinator
	-> RenamedHsBinds
	-> TcM s (thing, LIE s)
	-> TcM s (thing, LIE s)

tcTopBindsAndThen = tc_binds_and_then TopLevel
tcBindsAndThen    = tc_binds_and_then NotTopLevel

tc_binds_and_then top_lvl combiner EmptyBinds do_next
  = do_next
tc_binds_and_then top_lvl combiner (MonoBind EmptyMonoBinds sigs is_rec) do_next
  = do_next

tc_binds_and_then top_lvl combiner (ThenBinds b1 b2) do_next
  = tc_binds_and_then top_lvl combiner b1	$
    tc_binds_and_then top_lvl combiner b2	$
    do_next

tc_binds_and_then top_lvl combiner (MonoBind bind sigs is_rec) do_next
  = fixTc (\ ~(prag_info_fn, _, _) ->
	-- This is the usual prag_info fix; the PragmaInfo field of an Id
	-- is not inspected till ages later in the compiler, so there
	-- should be no black-hole problems here.

  	-- TYPECHECK THE SIGNATURES
      mapTc tcTySig [sig | sig@(Sig name _ _) <- sigs]	`thenTc` \ tc_ty_sigs ->
  
      tcBindWithSigs top_lvl bind 
		     tc_ty_sigs is_rec prag_info_fn	`thenTc` \ (poly_binds, poly_lie, poly_ids) ->
  
	  -- Extend the environment to bind the new polymorphic Ids
      tcExtendLocalValEnv (map idName poly_ids) poly_ids $
  
	  -- Build bindings and IdInfos corresponding to user pragmas
      tcPragmaSigs sigs		`thenTc` \ (prag_info_fn, prag_binds, prag_lie) ->

	-- Now do whatever happens next, in the augmented envt
      do_next			`thenTc` \ (thing, thing_lie) ->

	-- Create specialisations of functions bound here
	-- We want to keep non-recursive things non-recursive
	-- so that we desugar unboxed bindings correctly
      case (top_lvl, is_rec) of

		-- For the top level don't bother will all this bindInstsOfLocalFuns stuff
		-- All the top level things are rec'd together anyway, so it's fine to
		-- leave them to the tcSimplifyTop, and quite a bit faster too
	(TopLevel, _)
		-> returnTc (prag_info_fn, 
			     combiner Recursive (poly_binds `andMonoBinds` prag_binds) thing,
			     thing_lie `plusLIE` prag_lie `plusLIE` poly_lie)

	(NotTopLevel, NonRecursive) 
		-> bindInstsOfLocalFuns 
				(thing_lie `plusLIE` prag_lie)
				poly_ids			`thenTc` \ (thing_lie', lie_binds) ->

		   returnTc (
			prag_info_fn,
			combiner NonRecursive poly_binds $
			combiner NonRecursive prag_binds $
			combiner Recursive lie_binds  $
				-- NB: the binds returned by tcSimplify and bindInstsOfLocalFuns
				-- aren't guaranteed in dependency order (though we could change
				-- that); hence the Recursive marker.
			thing,

			thing_lie' `plusLIE` poly_lie
		   )

	(NotTopLevel, Recursive)
		-> bindInstsOfLocalFuns 
				(thing_lie `plusLIE` poly_lie `plusLIE` prag_lie) 
				poly_ids			`thenTc` \ (final_lie, lie_binds) ->

		   returnTc (
			prag_info_fn,
			combiner Recursive (
				poly_binds `andMonoBinds`
				lie_binds  `andMonoBinds`
				prag_binds) thing,
			final_lie
		  )
    )						`thenTc` \ (_, thing, lie) ->
    returnTc (thing, lie)
\end{code}

An aside.  The original version of @tcBindsAndThen@ which lacks a
combiner function, appears below.  Though it is perfectly well
behaved, it cannot be typed by Haskell, because the recursive call is
at a different type to the definition itself.  There aren't too many
examples of this, which is why I thought it worth preserving! [SLPJ]

\begin{pseudocode}
% tcBindsAndThen
% 	:: RenamedHsBinds
% 	-> TcM s (thing, LIE s, thing_ty))
% 	-> TcM s ((TcHsBinds s, thing), LIE s, thing_ty)
% 
% tcBindsAndThen EmptyBinds do_next
%   = do_next 		`thenTc` \ (thing, lie, thing_ty) ->
%     returnTc ((EmptyBinds, thing), lie, thing_ty)
% 
% tcBindsAndThen (ThenBinds binds1 binds2) do_next
%   = tcBindsAndThen binds1 (tcBindsAndThen binds2 do_next)
% 	`thenTc` \ ((binds1', (binds2', thing')), lie1, thing_ty) ->
% 
%     returnTc ((binds1' `ThenBinds` binds2', thing'), lie1, thing_ty)
% 
% tcBindsAndThen (MonoBind bind sigs is_rec) do_next
%   = tcBindAndThen bind sigs do_next
\end{pseudocode}


%************************************************************************
%*									*
\subsection{tcBindWithSigs}
%*									*
%************************************************************************

@tcBindWithSigs@ deals with a single binding group.  It does generalisation,
so all the clever stuff is in here.

* binder_names and mbind must define the same set of Names

* The Names in tc_ty_sigs must be a subset of binder_names

* The Ids in tc_ty_sigs don't necessarily have to have the same name
  as the Name in the tc_ty_sig

\begin{code}
tcBindWithSigs	
	:: TopLevelFlag
	-> RenamedMonoBinds
	-> [TcSigInfo s]
	-> RecFlag
	-> (Name -> IdInfo)
	-> TcM s (TcMonoBinds s, LIE s, [TcIdBndr s])

tcBindWithSigs top_lvl mbind tc_ty_sigs is_rec prag_info_fn
  = recoverTc (
	-- If typechecking the binds fails, then return with each
	-- signature-less binder given type (forall a.a), to minimise subsequent
	-- error messages
	newTcTyVar boxedTypeKind		`thenNF_Tc` \ alpha_tv ->
	let
	  forall_a_a    = mkForAllTy alpha_tv (mkTyVarTy alpha_tv)
          binder_names  = map fst (bagToList (collectMonoBinders mbind))
	  poly_ids      = map mk_dummy binder_names
	  mk_dummy name = case maybeSig tc_ty_sigs name of
			    Just (TySigInfo _ poly_id _ _ _ _ _ _) -> poly_id	-- Signature
			    Nothing -> mkUserId name forall_a_a          	-- No signature
	in
	returnTc (EmptyMonoBinds, emptyLIE, poly_ids)
    ) $

	-- TYPECHECK THE BINDINGS
    tcMonoBinds mbind tc_ty_sigs is_rec	`thenTc` \ (mbind', lie_req, binder_names, mono_ids) ->

    let
	mono_id_tys = map idType mono_ids
    in

	-- CHECK THAT THE SIGNATURES MATCH
	-- (must do this before getTyVarsToGen)
    checkSigMatch tc_ty_sigs				`thenTc` \ (sig_theta, lie_avail) ->	

	-- COMPUTE VARIABLES OVER WHICH TO QUANTIFY, namely tyvars_to_gen
	-- The tyvars_not_to_gen are free in the environment, and hence
	-- candidates for generalisation, but sometimes the monomorphism
	-- restriction means we can't generalise them nevertheless
    getTyVarsToGen is_unrestricted mono_id_tys lie_req	`thenNF_Tc` \ (tyvars_not_to_gen, tyvars_to_gen) ->

	-- DEAL WITH TYPE VARIABLE KINDS
	-- **** This step can do unification => keep other zonking after this ****
    mapTc defaultUncommittedTyVar (varSetElems tyvars_to_gen)	`thenTc` \ real_tyvars_to_gen_list ->
    let
	real_tyvars_to_gen = mkVarSet real_tyvars_to_gen_list
		-- It's important that the final list 
		-- (real_tyvars_to_gen and real_tyvars_to_gen_list) is fully
		-- zonked, *including boxity*, because they'll be included in the forall types of
		-- the polymorphic Ids, and instances of these Ids will be generated from them.
		-- 
		-- Also NB that tcSimplify takes zonked tyvars as its arg, hence we pass
		-- real_tyvars_to_gen
    in

	-- SIMPLIFY THE LIE
    tcExtendGlobalTyVars tyvars_not_to_gen (
	if null real_tyvars_to_gen_list then
		-- No polymorphism, so no need to simplify context
	    returnTc (lie_req, EmptyMonoBinds, [])
	else
	if null tc_ty_sigs then
		-- No signatures, so just simplify the lie
		-- NB: no signatures => no polymorphic recursion, so no
		-- need to use lie_avail (which will be empty anyway)
	    tcSimplify (text "tcBinds1" <+> ppr binder_names)
		       top_lvl real_tyvars_to_gen lie_req	`thenTc` \ (lie_free, dict_binds, lie_bound) ->
	    returnTc (lie_free, dict_binds, map instToId (bagToList lie_bound))

	else
	    zonkTcThetaType sig_theta			`thenNF_Tc` \ sig_theta' ->
	    newDicts SignatureOrigin sig_theta'		`thenNF_Tc` \ (dicts_sig, dict_ids) ->
		-- It's important that sig_theta is zonked, because
		-- dict_id is later used to form the type of the polymorphic thing,
		-- and forall-types must be zonked so far as their bound variables
		-- are concerned

	    let
		-- The "givens" is the stuff available.  We get that from
		-- the context of the type signature, BUT ALSO the lie_avail
		-- so that polymorphic recursion works right (see comments at end of fn)
		givens = dicts_sig `plusLIE` lie_avail
	    in

		-- Check that the needed dicts can be expressed in
		-- terms of the signature ones
	    tcAddErrCtxt  (bindSigsCtxt tysig_names) $
	    tcSimplifyAndCheck
		(ptext SLIT("type signature for") <+> pprQuotedList binder_names)
	    	real_tyvars_to_gen givens lie_req	`thenTc` \ (lie_free, dict_binds) ->

	    returnTc (lie_free, dict_binds, dict_ids)

    )						`thenTc` \ (lie_free, dict_binds, dicts_bound) ->

	-- GET THE FINAL MONO_ID_TYS
    zonkTcTypes mono_id_tys			`thenNF_Tc` \ zonked_mono_id_types ->


	-- CHECK FOR BOGUS UNPOINTED BINDINGS
    (if any isUnLiftedType zonked_mono_id_types then
		-- Unlifted bindings must be non-recursive,
		-- not top level, and non-polymorphic
	checkTc (case top_lvl of {TopLevel -> False; NotTopLevel -> True})
		(unliftedBindErr "Top-level" mbind)		`thenTc_`
	checkTc (case is_rec of {Recursive -> False; NonRecursive -> True})
		(unliftedBindErr "Recursive" mbind)		`thenTc_`
	checkTc (null real_tyvars_to_gen_list)
		(unliftedBindErr "Polymorphic" mbind)
     else
	returnTc ()
    )							`thenTc_`

    ASSERT( not (any ((== unboxedTypeKind) . tyVarKind) real_tyvars_to_gen_list) )
		-- The instCantBeGeneralised stuff in tcSimplify should have
		-- already raised an error if we're trying to generalise an 
		-- unboxed tyvar (NB: unboxed tyvars are always introduced 
		-- along with a class constraint) and it's better done there 
		-- because we have more precise origin information.
		-- That's why we just use an ASSERT here.


    	 -- BUILD THE POLYMORPHIC RESULT IDs
    mapNF_Tc zonkId mono_ids		`thenNF_Tc` \ zonked_mono_ids ->
    let
	exports  = zipWith mk_export binder_names zonked_mono_ids
	dict_tys = map tcIdType dicts_bound

	mk_export binder_name zonked_mono_id
	  = (tyvars, 
	     TcId (setIdInfo poly_id (prag_info_fn binder_name)), 
	     TcId zonked_mono_id)
	  where
	    (tyvars, poly_id) = 
		case maybeSig tc_ty_sigs binder_name of
		  Just (TySigInfo _ sig_poly_id sig_tyvars _ _ _ _ _) -> 
			(sig_tyvars, sig_poly_id)
		  Nothing -> (real_tyvars_to_gen_list, new_poly_id)

	    new_poly_id = mkUserId binder_name poly_ty
	    poly_ty = mkForAllTys real_tyvars_to_gen_list 
			$ mkFunTys dict_tys 
			$ idType (zonked_mono_id)
		-- It's important to build a fully-zonked poly_ty, because
		-- we'll slurp out its free type variables when extending the
		-- local environment (tcExtendLocalValEnv); if it's not zonked
		-- it appears to have free tyvars that aren't actually free 
		-- at all.
	
	pat_binders :: [Name]
	pat_binders = map fst $ bagToList $ collectMonoBinders $ 
		      (justPatBindings mbind EmptyMonoBinds)
    in
	-- CHECK FOR UNBOXED BINDERS IN PATTERN BINDINGS
    mapTc (\id -> checkTc (not (idName id `elem` pat_binders
				&& isUnboxedType (idType id)))
			  (unboxedPatBindErr id)) zonked_mono_ids
				`thenTc_`

	 -- BUILD RESULTS
    returnTc (
	 AbsBinds real_tyvars_to_gen_list
		  dicts_bound
		  exports
		  (dict_binds `andMonoBinds` mbind'),
	 lie_free,
	 [poly_id | (_, TcId poly_id, _) <- exports]
    )
  where
    tysig_names     = [name | (TySigInfo name _ _ _ _ _ _ _) <- tc_ty_sigs]
    is_unrestricted = isUnRestrictedGroup tysig_names mbind

justPatBindings bind@(PatMonoBind _ _ _) binds = bind `andMonoBinds` binds
justPatBindings (AndMonoBinds b1 b2) binds = 
	justPatBindings b1 (justPatBindings b2 binds) 
justPatBindings other_bind binds = binds
\end{code}

Polymorphic recursion
~~~~~~~~~~~~~~~~~~~~~
The game plan for polymorphic recursion in the code above is 

	* Bind any variable for which we have a type signature
	  to an Id with a polymorphic type.  Then when type-checking 
	  the RHSs we'll make a full polymorphic call.

This fine, but if you aren't a bit careful you end up with a horrendous
amount of partial application and (worse) a huge space leak. For example:

	f :: Eq a => [a] -> [a]
	f xs = ...f...

If we don't take care, after typechecking we get

	f = /\a -> \d::Eq a -> let f' = f a d
			       in
			       \ys:[a] -> ...f'...

Notice the the stupid construction of (f a d), which is of course
identical to the function we're executing.  In this case, the
polymorphic recursion isn't being used (but that's a very common case).
We'd prefer

	f = /\a -> \d::Eq a -> letrec
				 fm = \ys:[a] -> ...fm...
			       in
			       fm

This can lead to a massive space leak, from the following top-level defn
(post-typechecking)

	ff :: [Int] -> [Int]
	ff = f Int dEqInt

Now (f dEqInt) evaluates to a lambda that has f' as a free variable; but
f' is another thunk which evaluates to the same thing... and you end
up with a chain of identical values all hung onto by the CAF ff.

	ff = f Int dEqInt

	   = let f' = f Int dEqInt in \ys. ...f'...

	   = let f' = let f' = f Int dEqInt in \ys. ...f'...
		      in \ys. ...f'...

Etc.
Solution: when typechecking the RHSs we always have in hand the
*monomorphic* Ids for each binding.  So we just need to make sure that
if (Method f a d) shows up in the constraints emerging from (...f...)
we just use the monomorphic Id.  We achieve this by adding monomorphic Ids
to the "givens" when simplifying constraints.  That's what the "lies_avail"
is doing.


%************************************************************************
%*									*
\subsection{getTyVarsToGen}
%*									*
%************************************************************************

@getTyVarsToGen@ decides what type variables generalise over.

For a "restricted group" -- see the monomorphism restriction
for a definition -- we bind no dictionaries, and
remove from tyvars_to_gen any constrained type variables

*Don't* simplify dicts at this point, because we aren't going
to generalise over these dicts.  By the time we do simplify them
we may well know more.  For example (this actually came up)
	f :: Array Int Int
	f x = array ... xs where xs = [1,2,3,4,5]
We don't want to generate lots of (fromInt Int 1), (fromInt Int 2)
stuff.  If we simplify only at the f-binding (not the xs-binding)
we'll know that the literals are all Ints, and we can just produce
Int literals!

Find all the type variables involved in overloading, the
"constrained_tyvars".  These are the ones we *aren't* going to
generalise.  We must be careful about doing this:

 (a) If we fail to generalise a tyvar which is not actually
	constrained, then it will never, ever get bound, and lands
	up printed out in interface files!  Notorious example:
		instance Eq a => Eq (Foo a b) where ..
	Here, b is not constrained, even though it looks as if it is.
	Another, more common, example is when there's a Method inst in
	the LIE, whose type might very well involve non-overloaded
	type variables.

 (b) On the other hand, we mustn't generalise tyvars which are constrained,
	because we are going to pass on out the unmodified LIE, with those
	tyvars in it.  They won't be in scope if we've generalised them.

So we are careful, and do a complete simplification just to find the
constrained tyvars. We don't use any of the results, except to
find which tyvars are constrained.

\begin{code}
getTyVarsToGen is_unrestricted mono_id_tys lie
  = tcGetGlobalTyVars			`thenNF_Tc` \ free_tyvars ->
    zonkTcTypes mono_id_tys		`thenNF_Tc` \ zonked_mono_id_tys ->
    let
	tyvars_to_gen = tyVarsOfTypes zonked_mono_id_tys `minusVarSet` free_tyvars
    in
    if is_unrestricted
    then
	returnNF_Tc (emptyVarSet, tyvars_to_gen)
    else
	-- This recover and discard-errs is to avoid duplicate error
	-- messages; this, after all, is an "extra" call to tcSimplify
	recoverNF_Tc (returnNF_Tc (emptyVarSet, tyvars_to_gen))		$
	discardErrsTc							$

	tcSimplify (text "getTVG") NotTopLevel tyvars_to_gen lie    `thenTc` \ (_, _, constrained_dicts) ->
	let
	  -- ASSERT: dicts_sig is already zonked!
	    constrained_tyvars    = foldrBag (unionVarSet . tyVarsOfInst) emptyVarSet constrained_dicts
	    reduced_tyvars_to_gen = tyvars_to_gen `minusVarSet` constrained_tyvars
        in
        returnTc (constrained_tyvars, reduced_tyvars_to_gen)
\end{code}


\begin{code}
isUnRestrictedGroup :: [Name]		-- Signatures given for these
		    -> RenamedMonoBinds
		    -> Bool

is_elem v vs = isIn "isUnResMono" v vs

isUnRestrictedGroup sigs (PatMonoBind (VarPatIn v) _ _) = v `is_elem` sigs
isUnRestrictedGroup sigs (PatMonoBind other      _ _)	= False
isUnRestrictedGroup sigs (VarMonoBind v _)	        = v `is_elem` sigs
isUnRestrictedGroup sigs (FunMonoBind _ _ _ _)		= True
isUnRestrictedGroup sigs (AndMonoBinds mb1 mb2)		= isUnRestrictedGroup sigs mb1 &&
							  isUnRestrictedGroup sigs mb2
isUnRestrictedGroup sigs EmptyMonoBinds			= True
\end{code}

@defaultUncommittedTyVar@ checks for generalisation over unboxed
types, and defaults any TypeKind TyVars to BoxedTypeKind.

\begin{code}
defaultUncommittedTyVar tyvar
  | tyVarKind tyvar == openTypeKind
  = newTcTyVar boxedTypeKind					`thenNF_Tc` \ boxed_tyvar ->
    unifyTauTy (mkTyVarTy tyvar) (mkTyVarTy boxed_tyvar)	`thenTc_`
    returnTc boxed_tyvar

  | otherwise
  = returnTc tyvar
\end{code}


%************************************************************************
%*									*
\subsection{tcMonoBind}
%*									*
%************************************************************************

@tcMonoBinds@ deals with a single @MonoBind@.  
The signatures have been dealt with already.

\begin{code}
tcMonoBinds :: RenamedMonoBinds 
	    -> [TcSigInfo s]
	    -> RecFlag
	    -> TcM s (TcMonoBinds s, 
		      LIE s,		-- LIE required
		      [Name],		-- Bound names
		      [TcIdBndr s])	-- Corresponding monomorphic bound things

tcMonoBinds mbinds tc_ty_sigs is_rec
  = tc_mb_pats mbinds		`thenTc` \ (complete_it, lie_req_pat, tvs, ids, lie_avail) ->
    let
	tv_list		  = bagToList tvs
	(names, mono_ids) = unzip (bagToList ids)
    in
	-- Don't know how to deal with pattern-bound existentials yet
    checkTc (isEmptyBag tvs && isEmptyBag lie_avail) 
	    (existentialExplode mbinds)			`thenTc_` 

	-- *Before* checking the RHSs, but *after* checking *all* the patterns, 
	-- extend the envt with bindings for all the bound ids;
	--   and *then* override with the polymorphic Ids from the signatures
	-- That is the whole point of the "complete_it" stuff.
    tcExtendEnvWithPat ids (tcExtendEnvWithPat sig_ids 
		complete_it
    )						`thenTc` \ (mbinds', lie_req_rhss) ->
    returnTc (mbinds', lie_req_pat `plusLIE` lie_req_rhss, names, mono_ids)
  where
    sig_fn name = case maybeSig tc_ty_sigs name of
			Nothing				       -> Nothing
			Just (TySigInfo _ _ _ _ _ mono_id _ _) -> Just mono_id

    sig_ids = listToBag [(name,poly_id) | TySigInfo name poly_id _ _ _ _ _ _ <- tc_ty_sigs]

    kind = case is_rec of
	     Recursive    -> boxedTypeKind	-- Recursive, so no unboxed types
	     NonRecursive -> openTypeKind	-- Non-recursive, so we permit unboxed types

    tc_mb_pats EmptyMonoBinds
      = returnTc (returnTc (EmptyMonoBinds, emptyLIE), emptyLIE, emptyBag, emptyBag, emptyLIE)

    tc_mb_pats (AndMonoBinds mb1 mb2)
      = tc_mb_pats mb1		`thenTc` \ (complete_it1, lie_req1, tvs1, ids1, lie_avail1) ->
        tc_mb_pats mb2		`thenTc` \ (complete_it2, lie_req2, tvs2, ids2, lie_avail2) ->
	let
	   complete_it = complete_it1	`thenTc` \ (mb1', lie1) ->
			 complete_it2	`thenTc` \ (mb2', lie2) ->
			 returnTc (AndMonoBinds mb1' mb2', lie1 `plusLIE` lie2)
	in
	returnTc (complete_it,
		  lie_req1 `plusLIE` lie_req2,
		  tvs1 `unionBags` tvs2,
		  ids1 `unionBags` ids2,
		  lie_avail1 `plusLIE` lie_avail2)

    tc_mb_pats (FunMonoBind name inf matches locn)
      = newTyVarTy boxedTypeKind	`thenNF_Tc` \ pat_ty ->
	tcVarPat sig_fn name pat_ty	`thenTc` \ bndr_id ->
	let
	   complete_it = tcAddSrcLoc locn			$
			 tcMatchesFun name pat_ty matches	`thenTc` \ (matches', lie) ->
			 returnTc (FunMonoBind (TcId bndr_id) inf matches' locn, lie)
	in
	returnTc (complete_it, emptyLIE, emptyBag, unitBag (name, bndr_id), emptyLIE)

    tc_mb_pats bind@(PatMonoBind pat grhss_and_binds locn)
      = tcAddSrcLoc locn	 	$
	newTyVarTy kind			`thenNF_Tc` \ pat_ty ->
	tcPat sig_fn pat pat_ty	  	`thenTc` \ (pat', lie_req, tvs, ids, lie_avail) ->
	let
	   complete_it = tcAddSrcLoc locn		 		$
			 tcAddErrCtxt (patMonoBindsCtxt bind)		$
			 tcGRHSsAndBinds grhss_and_binds pat_ty PatBindRhs	`thenTc` \ (grhss_and_binds', lie) ->
			 returnTc (PatMonoBind pat' grhss_and_binds' locn, lie)
	in
	returnTc (complete_it, lie_req, tvs, ids, lie_avail)
\end{code}

%************************************************************************
%*									*
\subsection{Signatures}
%*									*
%************************************************************************

@checkSigMatch@ does the next step in checking signature matching.
The tau-type part has already been unified.  What we do here is to
check that this unification has not over-constrained the (polymorphic)
type variables of the original signature type.

The error message here is somewhat unsatisfactory, but it'll do for
now (ToDo).

\begin{code}
checkSigMatch []
  = returnTc (error "checkSigMatch", emptyLIE)

checkSigMatch tc_ty_sigs@( sig1@(TySigInfo _ id1 _ theta1 _ _ _ _) : all_sigs_but_first )
  = 	-- CHECK THAT THE SIGNATURE TYVARS AND TAU_TYPES ARE OK
	-- Doesn't affect substitution
    mapTc check_one_sig tc_ty_sigs	`thenTc_`

	-- CHECK THAT ALL THE SIGNATURE CONTEXTS ARE UNIFIABLE
	-- The type signatures on a mutually-recursive group of definitions
	-- must all have the same context (or none).
	--
	-- We unify them because, with polymorphic recursion, their types
	-- might not otherwise be related.  This is a rather subtle issue.
	-- ToDo: amplify
    mapTc check_one_cxt all_sigs_but_first		`thenTc_`

    returnTc (theta1, sig_lie)
  where
    sig1_dict_tys	= mk_dict_tys theta1
    n_sig1_dict_tys	= length sig1_dict_tys
    sig_lie 		= mkLIE [inst | TySigInfo _ _ _ _ _ _ inst _ <- tc_ty_sigs]

    check_one_cxt sig@(TySigInfo _ id _ theta _ _ _ src_loc)
       = tcAddSrcLoc src_loc	$
	 tcAddErrCtxt (sigContextsCtxt id1 id) $
	 checkTc (length this_sig_dict_tys == n_sig1_dict_tys)
				sigContextsErr 		`thenTc_`
	 unifyTauTyLists sig1_dict_tys this_sig_dict_tys
      where
	 this_sig_dict_tys = mk_dict_tys theta

    check_one_sig (TySigInfo _ id sig_tyvars _ sig_tau _ _ src_loc)
      = tcAddSrcLoc src_loc					$
	tcAddErrCtxtM (sigCtxt (quotes (ppr id)) sig_tau)	$
	checkSigTyVars sig_tyvars

    mk_dict_tys theta = [mkDictTy c ts | (c,ts) <- theta]
\end{code}


%************************************************************************
%*									*
\subsection{SPECIALIZE pragmas}
%*									*
%************************************************************************


@tcPragmaSigs@ munches up the "signatures" that arise through *user*
pragmas.  It is convenient for them to appear in the @[RenamedSig]@
part of a binding because then the same machinery can be used for
moving them into place as is done for type signatures.

\begin{code}
tcPragmaSigs :: [RenamedSig]		-- The pragma signatures
	     -> TcM s (Name -> IdInfo,	-- Maps name to the appropriate IdInfo
		       TcMonoBinds s,
		       LIE s)

tcPragmaSigs sigs
  = mapAndUnzip3Tc tcPragmaSig sigs	`thenTc` \ (maybe_info_modifiers, binds, lies) ->
    let
	prag_fn name = foldr ($) noIdInfo [f | Just (n,f) <- maybe_info_modifiers, n==name]
    in
    returnTc (prag_fn, andMonoBindList binds, plusLIEs lies)
\end{code}

The interesting case is for SPECIALISE pragmas.  There are two forms.
Here's the first form:
\begin{verbatim}
	f :: Ord a => [a] -> b -> b
	{-# SPECIALIZE f :: [Int] -> b -> b #-}
\end{verbatim}

For this we generate:
\begin{verbatim}
	f* = /\ b -> let d1 = ...
		     in f Int b d1
\end{verbatim}

where f* is a SpecPragmaId.  The **sole** purpose of SpecPragmaIds is to
retain a right-hand-side that the simplifier will otherwise discard as
dead code... the simplifier has a flag that tells it not to discard
SpecPragmaId bindings.

In this case the f* retains a call-instance of the overloaded
function, f, (including appropriate dictionaries) so that the
specialiser will subsequently discover that there's a call of @f@ at
Int, and will create a specialisation for @f@.  After that, the
binding for @f*@ can be discarded.

The second form is this:
\begin{verbatim}
	f :: Ord a => [a] -> b -> b
	{-# SPECIALIZE f :: [Int] -> b -> b = g #-}
\end{verbatim}

Here @g@ is specified as a function that implements the specialised
version of @f@.  Suppose that g has type (a->b->b); that is, g's type
is more general than that required.  For this we generate
\begin{verbatim}
	f@Int = /\b -> g Int b
	f* = f@Int
\end{verbatim}

Here @f@@Int@ is a SpecId, the specialised version of @f@.  It inherits
f's export status etc.  @f*@ is a SpecPragmaId, as before, which just serves
to prevent @f@@Int@ from being discarded prematurely.  After specialisation,
if @f@@Int@ is going to be used at all it will be used explicitly, so the simplifier can
discard the f* binding.

Actually, there is really only point in giving a SPECIALISE pragma on exported things,
and the simplifer won't discard SpecIds for exporte things anyway, so maybe this is
a bit of overkill.

\begin{code}
tcPragmaSig :: RenamedSig -> TcM s (Maybe (Name, IdInfo -> IdInfo), TcMonoBinds s, LIE s)
tcPragmaSig (Sig _ _ _)       = returnTc (Nothing, EmptyMonoBinds, emptyLIE)
tcPragmaSig (SpecInstSig _ _) = returnTc (Nothing, EmptyMonoBinds, emptyLIE)

tcPragmaSig (InlineSig name loc)
  = returnTc (Just (name, setInlinePragInfo IWantToBeINLINEd), EmptyMonoBinds, emptyLIE)

tcPragmaSig (NoInlineSig name loc)
  = returnTc (Just (name, setInlinePragInfo IMustNotBeINLINEd), EmptyMonoBinds, emptyLIE)

tcPragmaSig (SpecSig name poly_ty maybe_spec_name src_loc)
  = 	-- SPECIALISE f :: forall b. theta => tau  =  g
    tcAddSrcLoc src_loc		 		$
    tcAddErrCtxt (valSpecSigCtxt name poly_ty)	$

	-- Get and instantiate its alleged specialised type
    tcHsTcType poly_ty				`thenTc` \ sig_ty ->

	-- Check that f has a more general type, and build a RHS for
	-- the spec-pragma-id at the same time
    tcExpr (HsVar name) sig_ty			`thenTc` \ (spec_expr, spec_lie) ->

    case maybe_spec_name of
	Nothing -> 	-- Just specialise "f" by building a SpecPragmaId binding
			-- It is the thing that makes sure we don't prematurely 
			-- dead-code-eliminate the binding we are really interested in.
		   newSpecPragmaId name sig_ty		`thenNF_Tc` \ spec_id ->
		   returnTc (Nothing, VarMonoBind (TcId spec_id) spec_expr, spec_lie)

	Just g_name ->	-- Don't create a SpecPragmaId.  Instead add some suitable IdIfo
		
		panic "Can't handle SPECIALISE with a '= g' part"

	{-  Not yet.  Because we're still in the TcType world we
	    can't really add to the SpecEnv of the Id.  Instead we have to
	    record the information in a different sort of Sig, and add it to
	    the IdInfo after zonking.

	    For now we just leave out this case

			-- Get the type of f, and find out what types
			--  f has to be instantiated at to give the signature type
		    tcLookupLocalValueOK "tcPragmaSig" name	`thenNF_Tc` \ f_id ->
		    tcInstTcType (idType f_id)		`thenNF_Tc` \ (f_tyvars, f_rho) ->

		    let
			(sig_tyvars, sig_theta, sig_tau) = splitSigmaTy sig_ty
			(f_theta, f_tau)                 = splitRhoTy f_rho
			sig_tyvar_set			 = mkVarSet sig_tyvars
		    in
		    unifyTauTy sig_tau f_tau		`thenTc_`

		    tcPolyExpr str (HsVar g_name) (mkSigmaTy sig_tyvars f_theta sig_tau)	`thenTc` \ (_, _, 
	-}

tcPragmaSig other = pprTrace "tcPragmaSig: ignoring" (ppr other) $
		    returnTc (Nothing, EmptyMonoBinds, emptyLIE)
\end{code}


%************************************************************************
%*									*
\subsection[TcBinds-errors]{Error contexts and messages}
%*									*
%************************************************************************


\begin{code}
patMonoBindsCtxt bind
  = hang (ptext SLIT("In a pattern binding:")) 4 (ppr bind)

-----------------------------------------------
valSpecSigCtxt v ty
  = sep [ptext SLIT("In a SPECIALIZE pragma for a value:"),
	 nest 4 (ppr v <+> ptext SLIT(" ::") <+> ppr ty)]

-----------------------------------------------
notAsPolyAsSigErr sig_tau mono_tyvars
  = hang (ptext SLIT("A type signature is more polymorphic than the inferred type"))
	4  (vcat [text "Can't for-all the type variable(s)" <+> 
		  pprQuotedList mono_tyvars,
		  text "in the type" <+> quotes (ppr sig_tau)
	   ])

-----------------------------------------------
badMatchErr sig_ty inferred_ty
  = hang (ptext SLIT("Type signature doesn't match inferred type"))
	 4 (vcat [hang (ptext SLIT("Signature:")) 4 (ppr sig_ty),
		      hang (ptext SLIT("Inferred :")) 4 (ppr inferred_ty)
	   ])

-----------------------------------------------
unboxedPatBindErr id
  = ptext SLIT("variable in a lazy pattern binding has unboxed type: ")
	 <+> quotes (ppr id)

-----------------------------------------------
bindSigsCtxt ids
  = ptext SLIT("When checking the type signature(s) for") <+> pprQuotedList ids

-----------------------------------------------
sigContextsErr
  = ptext SLIT("Mismatched contexts")
sigContextsCtxt s1 s2
  = hang (hsep [ptext SLIT("When matching the contexts of the signatures for"), 
		quotes (ppr s1), ptext SLIT("and"), quotes (ppr s2)])
	 4 (ptext SLIT("(the signature contexts in a mutually recursive group should all be identical)"))

-----------------------------------------------
unliftedBindErr flavour mbind
  = hang (text flavour <+> ptext SLIT("bindings for unlifted types aren't allowed"))
	 4 (ppr mbind)

existentialExplode mbinds
  = hang (vcat [text "My brain just exploded.",
	        text "I can't handle pattern bindings for existentially-quantified constructors.",
		text "In the binding group"])
	4 (ppr mbinds)
\end{code}
