/* utils/magic_fork.h --
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
 *
 */

#ifndef _MAGIC__UTILS__MAGIC_FORK_H
#define _MAGIC__UTILS__MAGIC_FORK_H

#include <unistd.h>

#include "utils/magic.h"

#define FORK_f(pid) do { pid = fork(); if (pid > 0) ForkChildAdd (pid); } while (0)
#define FORK_vf(pid) do { pid = vfork(); if (pid > 0) ForkChildAdd (pid); } while (0)

//#ifdef HAVE_WORKING_VFORK

//#define FORK(pid) FORK_vf(pid)

//#else

#define FORK(pid) FORK_f(pid)

//#endif

#endif /* _MAGIC__UTILS__MAGIC_FORK_H */
