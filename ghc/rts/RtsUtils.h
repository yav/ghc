/* -----------------------------------------------------------------------------
 * $Id: RtsUtils.h,v 1.2 1998/12/02 13:28:42 simonm Exp $
 *
 * General utility functions used in the RTS.
 *
 * ---------------------------------------------------------------------------*/

extern void *stgMallocBytes(int n, char *msg);
extern void *stgMallocWords(int n, char *msg);
extern void *stgReallocBytes(void *p, int n, char *msg);
extern void *stgReallocWords(void *p, int n, char *msg);
extern void barf(char *s, ...) __attribute__((__noreturn__)) ;
extern void belch(char *s, ...);

extern void _stgAssert (char *filename, unsigned int linenum);

extern StgStablePtr errorHandler;
extern void raiseError( StgStablePtr handler );

extern void stackOverflow(nat stk_size);
extern void heapOverflow(void);

extern nat stg_strlen(char *str);

/*Defined in Main.c, but made visible here*/
extern void stg_exit(I_ n) __attribute__((noreturn));

char * time_str(void);

char *ullong_format_string(ullong, char *, rtsBool);

