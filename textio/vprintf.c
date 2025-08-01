/*
 * textio/vprintf.c --
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

#include "utils/magic.h"

#if (!defined(HAVE_VPRINTF) && defined(HAVE_DOPRNT))

#if (defined(MIPSEB) && defined(SYSTYPE_BSD43))
 #define CAST_UNSIGNED_CHAR (unsigned char)
#else
 #define CAST_UNSIGNED_CHAR /* noop */
#endif

int
vfprintf(FILE *iop, const char *fmt, va_list args_in)
{
    va_list ap;
    int len;
    char localbuf[BUFSIZ];

    va_copy(ap, args_in);
    if (iop->_flag & _IONBF) {
	iop->_flag &= ~_IONBF;
	iop->_ptr = iop->_base = CAST_UNSIGNED_CHAR localbuf;
	len = _doprnt(fmt, ap, iop);
	(void) fflush(iop);
	iop->_flag |= _IONBF;
	iop->_base = NULL;
	iop->_bufsiz = 0;
	iop->_cnt = 0;
    } else
	len = _doprnt(fmt, ap, iop);

    va_end(ap);
    return (ferror(iop) ? EOF : len);
}
#endif  /* !HAVE_VPRINTF && HAVE_DOPRNT */
