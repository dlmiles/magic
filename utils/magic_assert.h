/*
 * magic_assert.h --
 *
 * Debugging and assertions definitions for all MAGIC modules
 *
 *     *********************************************************************
 *     * Copyright (C) 2017, 2024 Regents of the University of California. *
 *     * Permission to use, copy, modify, and distribute this              *
 *     * software and its documentation for any purpose and without        *
 *     * fee is hereby granted, provided that the above copyright          *
 *     * notice appear in all copies.  The University of California        *
 *     * makes no representations about the suitability of this            *
 *     * software for any purpose.  It is provided "as is" without         *
 *     * express or implied warranty.  Export of this software outside     *
 *     * of the United States of America may require an export license.    *
 *     *********************************************************************
 *
 * rcsid="$Header"
 */

#ifndef _MAGIC__UTILS__MAGIC_ASSERT_H
#define _MAGIC__UTILS__MAGIC_ASSERT_H


/* --------------------- Debugging and assertions --------------------- */

/* To enable assertions, undefine NDEBUG in file defs.mak */

#include <assert.h>
#define	ASSERT(p, where) assert(p)	/* "where" is ignored */


#ifndef _Static_assert
 /* Pre C11, this moves the test to runtime, not trying to support 1-arg form */
 #define _Static_assert(expression, message)  ASSERT(expression, message)
#endif

#ifndef static_assert
 /* Pre C23, this moves the test to runtime, not trying to support 1-arg form */
 #define static_assert(expression, message)  ASSERT(expression, message)
#endif


#endif /* _MAGIC__UTILS__MAGIC_ASSERT_H */
