/* -----------------------------------------------------------------------------
 * $Id: Updates.h,v 1.2 1998/12/02 13:21:47 simonm Exp $
 *
 * Definitions related to updates.
 *
 * ---------------------------------------------------------------------------*/

#ifndef UPDATES_H
#define UPDATES_H

/*
  ticky-ticky wants to use permanent indirections when it's doing
  update entry counts.
 */

#ifndef TICKY_TICKY
# define Ind_info_TO_USE &IND_info
#else
# define Ind_info_TO_USE ((AllFlags.doUpdEntryCounts) ? &IND_PERM_info : &IND_info
)
#endif

/* -----------------------------------------------------------------------------
   Update a closure with an indirection.  This may also involve waking
   up a queue of blocked threads waiting on the result of this
   computation.
   -------------------------------------------------------------------------- */

/* ToDo: overwrite slop words with something safe in case sanity checking 
 *       is turned on.  
 *       (I think the fancy version of the GC is supposed to do this too.)
 */

#define UPD_IND(updclosure, heapptr)                            \
        TICK_UPDATED_SET_UPDATED(updclosure);		        \
        AWAKEN_BQ(updclosure);                                  \
        SET_INFO((StgInd*)updclosure,Ind_info_TO_USE);          \
        ((StgInd *)updclosure)->indirectee   = (StgClosure *)(heapptr)

/* -----------------------------------------------------------------------------
   Update a closure inplace with an infotable that expects 1 (closure)
   argument.
   Also may wake up BQs.
   -------------------------------------------------------------------------- */

#define UPD_INPLACE1(updclosure,info,c0)                        \
        TICK_UPDATED_SET_UPDATED(updclosure);		        \
        AWAKEN_BQ(updclosure);                                  \
        SET_INFO(updclosure,info);                              \
        payloadCPtr(updclosure,0) = (c0)

/* -----------------------------------------------------------------------------
   Awaken any threads waiting on this computation
   -------------------------------------------------------------------------- */

extern void awaken_blocked_queue(StgTSO *q);

#define AWAKEN_BQ(closure)						\
     	if (closure->header.info == &BLACKHOLE_info) {			\
		StgTSO *bq = ((StgBlackHole *)closure)->blocking_queue;	\
		if (bq != (StgTSO *)&END_TSO_QUEUE_closure) {		\
			STGCALL1(awaken_blocked_queue, bq);		\
		}							\
	}


/* -----------------------------------------------------------------------------
   Push an update frame on the stack.
   -------------------------------------------------------------------------- */

#if defined(PROFILING)
#define PUSH_STD_CCCS(frame) frame->header.prof.ccs = CCCS
#else
#define PUSH_STD_CCCS(frame)
#endif

extern const StgPolyInfoTable Upd_frame_info; 

#define PUSH_UPD_FRAME(target, Sp_offset)			\
	{							\
		StgUpdateFrame *__frame;			\
		TICK_UPDF_PUSHED();  			        \
		__frame = stgCast(StgUpdateFrame*,Sp + (Sp_offset)) - 1; \
		SET_INFO(__frame,stgCast(StgInfoTable*,&Upd_frame_info));   \
		__frame->link = Su;				\
		__frame->updatee = (StgClosure *)(target);	\
		PUSH_STD_CCCS(__frame);				\
		Su = __frame;					\
	}

/* -----------------------------------------------------------------------------
   Entering CAFs

   When a CAF is first entered, it creates a black hole in the heap,
   and updates itself with an indirection to this new black hole.

   We update the CAF with an indirection to a newly-allocated black
   hole in the heap.  We also set the blocking queue on the newly
   allocated black hole to be empty.

   Why do we make a black hole in the heap when we enter a CAF?
      
       - for a  generational garbage collector, which needs a fast
         test for whether an updatee is in an old generation or not

       - for the parallel system, which can implement updates more
         easily if the updatee is always in the heap. (allegedly).
   -------------------------------------------------------------------------- */
   
EI_(Caf_info);
EF_(Caf_entry);

/* ToDo: only call newCAF when debugging. */

extern void newCAF(StgClosure*);

#define UPD_CAF(cafptr, bhptr)					\
  {								\
    SET_INFO((StgInd *)cafptr,&IND_STATIC_info);	        \
    ((StgInd *)cafptr)->indirectee   = (StgClosure *)(bhptr);	\
    ((StgBlackHole *)(bhptr))->blocking_queue = 		\
          (StgTSO *)&END_TSO_QUEUE_closure; 			\
    STGCALL1(newCAF,(StgClosure *)cafptr);			\
  }

/* -----------------------------------------------------------------------------
   Update-related prototypes
   -------------------------------------------------------------------------- */

extern STGFUN(Upd_frame_entry);

extern const StgInfoTable PAP_info;
STGFUN(PAP_entry);

EXTFUN(stg_update_PAP);

extern const StgInfoTable AP_UPD_info;
STGFUN(AP_UPD_entry);

extern const StgInfoTable raise_info;

#endif /* UPDATES_H */
