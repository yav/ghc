%
% (c) The GRASP/AQUA Project, Glasgow University, 1992-1996
%
\section[PrelST]{The @ST@ monad}

\begin{code}
{-# OPTIONS -fno-implicit-prelude #-}

module PrelST where

import Monad
import PrelBase
import PrelGHC
\end{code}

%*********************************************************
%*							*
\subsection{The @ST@ monad}
%*							*
%*********************************************************

The state-transformer monad proper.  By default the monad is strict;
too many people got bitten by space leaks when it was lazy.

\begin{code}
newtype ST s a = ST (State# s -> (# State# s, a #))

instance Functor (ST s) where
    map f (ST m) = ST $ \ s ->
      case (m s) of { (# new_s, r #) ->
      (# new_s, f r #) }

instance Monad (ST s) where
    {-# INLINE return #-}
    {-# INLINE (>>)   #-}
    {-# INLINE (>>=)  #-}
    return x = ST $ \ s -> (# s, x #)
    m >> k   =  m >>= \ _ -> k

    (ST m) >>= k
      = ST $ \ s ->
	case (m s) of { (# new_s, r #) ->
	case (k r) of { ST k2 ->
	(k2 new_s) }}

data STret s a = STret (State# s) a

-- liftST is useful when we want a lifted result from an ST computation.  See
-- fixST below.
liftST :: ST s a -> State# s -> STret s a
liftST (ST m) = \s -> case m s of (# s', r #) -> STret s' r

fixST :: (a -> ST s a) -> ST s a
fixST k = ST $ \ s ->
    let ans       = liftST (k r) s
	STret _ r = ans
    in
    case ans of STret s' r -> (# s', r #)

{-# NOINLINE unsafeInterleaveST #-}
unsafeInterleaveST :: ST s a -> ST s a
unsafeInterleaveST (ST m) = ST ( \ s ->
    let
	r = case m s of (# _, res #) -> res
    in
    (# s, r #)
  )

instance  Show (ST s a)  where
    showsPrec p f  = showString "<<ST action>>"
    showList	   = showList__ (showsPrec 0)
\end{code}

Definition of runST
~~~~~~~~~~~~~~~~~~~

SLPJ 95/04: Why @runST@ must not have an unfolding; consider:
\begin{verbatim}
f x =
  runST ( \ s -> let
		    (a, s')  = newArray# 100 [] s
		    (_, s'') = fill_in_array_or_something a x s'
		  in
		  freezeArray# a s'' )
\end{verbatim}
If we inline @runST@, we'll get:
\begin{verbatim}
f x = let
	(a, s')  = newArray# 100 [] realWorld#{-NB-}
	(_, s'') = fill_in_array_or_something a x s'
      in
      freezeArray# a s''
\end{verbatim}
And now the @newArray#@ binding can be floated to become a CAF, which
is totally and utterly wrong:
\begin{verbatim}
f = let
    (a, s')  = newArray# 100 [] realWorld#{-NB-} -- YIKES!!!
    in
    \ x ->
	let (_, s'') = fill_in_array_or_something a x s' in
	freezeArray# a s''
\end{verbatim}
All calls to @f@ will share a {\em single} array!  End SLPJ 95/04.

\begin{code}
{-# NOINLINE runST #-}
runST :: (forall s. ST s a) -> a
runST st = 
  case st of
	ST m -> case m realWorld# of
      			(# _, r #) -> r
\end{code}

%*********************************************************
%*							*
\subsection{Ghastly return types}
%*							*
%*********************************************************

The @State@ type is the return type of a _ccall_ with no result.  It
never actually exists, since it's always deconstructed straight away;
the desugarer ensures this.

\begin{code}
data State	     s     = S#		     (State# s)
\end{code}
