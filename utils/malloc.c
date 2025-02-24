/*
 * malloc.c --
 *
 * Memory allocator.
 *   Magic no longer contains its own version of malloc(), as all modern
 *   operating systems have implementations which are as good or better.
 *
 *   The main thing this file does is to define mallocMagic and friends.
 *   freeMagic frees the previously requested memory item, not the one
 *   passed as the argument.  This allows efficient coding of loops which
 *   run through linked lists and process and free them at the same time.
 *
 *   ALWAYS use mallocMagic() with freeMagic() and NEVER mix them with
 *   malloc() and free().
 *
 *   Malloc trace routines have been removed.  There are standard methods
 *   to trace memory allocation and magic doesn't need its own built-in
 *   method.
 *
 *   The Tcl/Tk version of magic makes use of Tcl_Alloc() and Tcl_Free()
 *   which allows the Tcl/Tk version to trace memory using Tcl's methods.
 *
 *     *********************************************************************
 *     * Copyright (C) 1985, 1990 Regents of the University of California. *
 *     * Permission to use, copy, modify, and distribute this              *
 *     * software and its documentation for any purpose and without        *
 *     * fee is hereby granted, provided that the above copyright          *
 *     * notice appear in all copies.  The University of California        *
 *     * makes no representations about the suitability of this            *
 *     * software for any purpose.  It is provided "as is" without         *
 *     * express or implied warranty.  Export of this software outside     *
 *     * of the United States of America may require an export license.    *
 *     *********************************************************************
 */

#ifndef lint
static char rcsid[] __attribute__ ((unused)) = "$Header: /usr/cvsroot/magic-8.0/utils/malloc.c,v 1.1.1.1 2008/02/03 20:43:50 tim Exp $";
#endif  /* not lint */

#include <stdio.h>
#include <stdlib.h>
#include <errno.h>
#include <string.h>

#include "tcltk/tclmagic.h"
#define _MAGIC__UTILS__MALLOC_H__NOINLINE
#include "utils/magic.h"
#include "utils/malloc.h"

/* Normally we're supposed to warn against the use of standard malloc()	*/
/* and free(), but obviously that doesn't apply to this file.		*/

#ifndef SUPPORT_DIRECT_MALLOC
/* this is needed to remove the utils/magic.h defines */
#undef malloc
#undef free
#endif

/* Imports */

extern void TxError(char *, ...);
extern char *TxGetLine();

/*
 * Magic may reference an object after it is free'ed, but only one object.
 * This is a change from previous versions of Magic, which needed to reference
 * an arbitrary number of objects before the next call to malloc.  Only then
 * would no further references would be made to free'ed storage.
 */

#ifndef SUPPORT_REMOVE_MALLOC_LEGACY
/* Delay free'ing by one call, to accommodate Magic's needs. */
static char *freeDelayedItem = NULL;

/* Local definitions */

#ifdef MAGIC_WRAPPER
#ifdef TCL_MEM_DEBUG
#define MallocRoutine(a) ckalloc(a)
#define FreeRoutine(a) ckfree(a)
#else
/* DO NOT USE:  Tcl_Alloc is defined with argument (unsigned int) NOT
 * (size_t) and therefore limits memory allocation to the size of a
 * 32-bit integer.  Just use the normal malloc() and free().  Left as-is
 * with TCL_MEM_DEBUG with the caveat that one should not use this to
 * debug a huge design.  Valgrind works better anyway.
 */
/* #define MallocRoutine(a) Tcl_Alloc(a) */
/* #define FreeRoutine(a) Tcl_Free(a) */
#define MallocRoutine(a) malloc(a)
#define FreeRoutine(a) free(a)
#endif
#else
#define MallocRoutine(a) malloc(a)
#define FreeRoutine(a) free(a)
#endif

/*
 *---------------------------------------------------------------------
 * mallocMagicLegacy() --
 *
 *	memory allocator with support for one-delayed-item free'ing
 *---------------------------------------------------------------------
 */

void *
mallocMagicLegacy(nbytes)
    size_t nbytes;
{
    void *p;

    if (freeDelayedItem)
    {
	/* fprintf(stderr, "freed 0x%x (delayed)\n", freeDelayedItem); fflush(stderr); */

	FreeRoutine(freeDelayedItem);
	freeDelayedItem=NULL;
    }

    if ((p = (void *)MallocRoutine(nbytes)) != NULL)
    {
	/* fprintf(stderr, "alloc'd %u bytes at 0x%x\n", nbytes, p); fflush(stderr); */

	return p;
    }
    else
    {
	ASSERT(FALSE, "Can't allocate any more memory.\n");
    }
    return NULL;
}

/*
 *---------------------------------------------------------------------
 * freeMagicLegacy() --
 *
 *	one-delayed-item memory deallocation
 *---------------------------------------------------------------------
 */

void
freeMagicLegacy(cp)
    void *cp;
{
    if (cp == NULL)
	TxError("freeMagic called with NULL argument.\n");
    if (freeDelayedItem)
    {
	/* fprintf(stderr, "freed 0x%x\n", freeDelayedItem); fflush(stderr); */

	FreeRoutine(freeDelayedItem);
    }
    freeDelayedItem=cp;
}

/*
 *---------------------------------------------------------------------
 * callocMagicLegacy() --
 *
 *	allocate memory and initialize it to all zero bytes.
 *---------------------------------------------------------------------
 */

void *
callocMagicLegacy(nbytes)
    size_t nbytes;
{
    void *cp;

    cp = mallocMagic(nbytes);
    bzero(cp, (size_t) nbytes);

    return (cp);
}

#endif /* SUPPORT_REMOVE_MALLOC_LEGACY */


/*
 *  NOTICE: non-inline form of emitted functions, keep in sync with malloc.h
 */
#pragma weak freeMagic1_init = freeMagic1_init_func
free_magic1_t freeMagic1_init_func() {
    return NULL;
}

#pragma weak freeMagic1 = freeMagic1_func
void freeMagic1_func(free_magic1_t* m1, void* ptr) {
    //if(*m1) /* this if() is here to help inliner remove the call to free() when it can */
    /* this is not the inline form here so if() is commented out */
    {
#if (defined(SUPPORT_DIRECT_MALLOC) || defined(SUPPORT_REMOVE_MALLOC_LEGACY))
	free(*m1); /* no need for NULL check with free() */
#else
	/* but freeMagicLegacy() does not like NULL passed, so extra if() penalty here */
	if(*m1) freeMagicLegacy(*m1);
#endif
    }
    *m1 = ptr;
}

#pragma weak freeMagic1_end = freeMagic1_end_func
void freeMagic1_end_func(free_magic1_t* m1) {
    //if(*m1) /* this if() is here to help inliner remove the call to free() when it can */
    /* this is not the inline form here so if() is commented out */
    {
#if (defined(SUPPORT_DIRECT_MALLOC) || defined(SUPPORT_REMOVE_MALLOC_LEGACY))
	free(*m1); /* no need for NULL check with free() */
#else
	/* but freeMagicLegacy() does not like NULL passed, so extra if() penalty here */
	if(*m1) freeMagicLegacy(*m1);
#endif
    }
}
