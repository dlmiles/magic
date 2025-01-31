/*
 *  utils/magic_alloca.h
 *
 *  Copyright (C) 1985, 1990 Regents of the University of California.
 *
 *  Permission to use, copy, modify, and distribute this
 *  software and its documentation for any purpose and without
 *  fee is hereby granted, provided that the above copyright
 *  notice appear in all copies.  The University of California
 *  makes no representations about the suitability of this
 *  software for any purpose.  It is provided "as is" without
 *  express or implied warranty.  Export of this software outside
 *  of the United States of America may require an export license.
 *
 *  SPDX-License-Identifier: HPND-UC-export-US
 *
 *
 *  This file contains code snippets that are part of the GNU autoconf 2.69
 *  project documentation.  This project is licensed under GPLv3 with a
 *  Section 7 clause outlined in autoconf-2.69/COPYING.EXCEPTION.
 *
 *  The documentation for the autoconf project is licensed under GNU Free
 *  Documentation License Version 1.3 or any later version published by the
 *  Free Software Foundation.  The snippets in here are taken entirely from the
 *  documentation so fall under GFDL-1.3-or-later terms.
 *  The documentation published by the FSF can be seen at
 *   https://www.gnu.org/savannah-checkouts/gnu/autoconf/manual/autoconf-2.69/autoconf.html
 *  This section seeks to provide attribution by providing references to the source
 *  a link to the full license text and the required boilerplate text directly below:
 *
 *  Copyright (C) 1992-1996, 1998-2012 Free Software Foundation, Inc.
 *
 *    Permission is granted to copy, distribute and/or modify this
 *    document under the terms of the GNU Free Documentation License,
 *    Version 1.3 or any later version published by the Free Software
 *    Foundation; with no Invariant Sections, no Front-Cover texts, and
 *    no Back-Cover Texts.  A copy of the license is included in the
 *    section entitled "GNU Free Documentation License."
 *
 *  A full copy of the GNU Free Documentation License version 1.3 is available at:
 *    https://www.gnu.org/licenses/fdl-1.3.html
 *  SPDX-License-Identifier: GFDL-1.3-or-later
 *
 *
 *  All other lines in this file are licensed under the HPND-UC-export-US license
 *  at the top of this file inline with the main project licensing.
 *
 */

#ifndef _MAGIC__UTILS__MAGIC_ALLOCA_H
#define _MAGIC__UTILS__MAGIC_ALLOCA_H

/* taken from autoconf documentation:
 *    https://www.gnu.org/software/autoconf/manual/autoconf-2.69/html_node/Particular-Functions.html
 *
 * the reason this header exists is to help hide this ugliness and prevent copy-and-paste error etc..
 *
 * #include "utils/magic_alloca.h"
 */
#ifdef STDC_HEADERS
# include <stdlib.h>
# include <stddef.h>
#else
# ifdef HAVE_STDLIB_H
#  include <stdlib.h>
# endif
#endif
#ifdef HAVE_ALLOCA_H
# include <alloca.h>
#elif !defined alloca
# ifdef __GNUC__
#  define alloca __builtin_alloca
# elif defined _AIX
#  define alloca __alloca
# elif defined _MSC_VER
#  include <malloc.h>
#  define alloca _alloca
# elif !defined HAVE_ALLOCA
#  ifdef  __cplusplus
extern "C"
#  endif
void *alloca (size_t);
# endif
#endif

// FIXME need:
//// extern char *strcpy_advance_inline(char *dest, const char *src);
//// extern char *strncpy_withnul_inline(char *dest, const char *src, size_t n);
//
//  _Static_assert()

// _ATTR_ALWAYS_INLINE
inline __attribute__((always_inline)) char *
strcpy_advance_inline(char *dest, const char *src)
{
    while(*src)
        *dest++ = *src++;
    return dest;
}

/* like strncpy() but ...
 *   the 'n' count includes the NUL byte (if possible)
 *   the return value is the NUL byte position (or where it would be)
 */
inline __attribute__((always_inline)) char *
strncpy_withnul_inline(char *dest, const char *src, size_t n)
{
    while(n > 1 && *src) {
        *dest++ = *src++;
        n--;
    }
    if(n > 0)
        *dest = '\0';
    return dest;
}

/* Some useful inline macros-like-functions for convenience with automatic malloc fallback
 * for platform that may prefer not to use, or for instrumentation when debugging/bug hunting.
 */
/*
 *  idiom example:
 *
 *  void my_func(const char *s1, const char *s2) {
 *    xalloca_var(char *, s); // char* s;  equivalent
 *    xalloca_init(&s);
 *    xalloca_concat2(&s, s1, s2);
 *    for(auto item : items)
 *        if(strcmp(item->s, s) == 0) break; // use of value example
 *    xalloca_end(&s);
 *  }
 *
 * Ideally the project needs a build mode where alloca is disabled and malloc used and every
 *  allocatation is checked for matching cleanup after a code coverage test.
 *
 */
#ifdef alloca

/* Why does this xalloca_xyzxyz() API looks like this ?
 *
 * It allows an alternative macro implementation to be provided that can instrument
 * the usages such that if you hit code-coverage (or at least one API call inside a
 * method where any APIs are used) you can report on certain kinds of misuses of
 * this API, which might only show up in some configuration scenarios.
 *
 * This means it is possible to audit and report problems when looking.
 *
 * It allows simple basic usage with asserts removed (as per build options) to end up
 * at their most simplist form.  Such as direct linkage to symbols unencumbered by the
 * checking.
 *
 * The _Static_assert() is trying to prove an address-of was provided and not the
 * value of the variable.
 */

#define xalloca_var(defn, name)  defn name

#define xalloca_init(res) do { /* NOOP */ } while(0);

#define xalloca_malloc(res, size) do { \
  _Static_assert(res != NULL, "res"); \
  ASSERT((ssize_t)size >= 0, "size"); \
  *(res) = alloca(size); \
 } while(0)

#define xalloca_calloc(res, nmembs, size) do { \
  _Static_assert(res != NULL, "res"); \
  ASSERT((ssize_t)nmembs >= 0, "nmembs"); \
  ASSERT((ssize_t)size >= 0, "size"); \
  size_t len = (nmembs) * (size); \
  char *m = alloca(len); \
  memset(m, 0, len); \
  *(res) = m; \
 } while(0)

#define xalloca_strdup(res, s) do { \
  _Static_assert(res != NULL, "res"); \
  const char *ss = s; \
  ASSERT(ss, "s"); \
  size_t len = strlen(ss) + 1; \
  char *m = alloca(len); \
  strcpy(m, ss); \
  *(res) = m; \
 } while(0)

#define xalloca_strndup(res, s, n) do { \
  _Static_assert(res != NULL, "res"); \
  const char *ss = s; \
  ASSERT(ss, "s"); \
  const size_t nn = n; \
  size_t len = strnlen(ss, nn) + 1; \
  char *m = alloca(len); \
  strncpy_withnul(m, ss, len); \
  *(res) = m; \
 } while(0)

#define xalloca_concat2(res, a, b) do { \
  _Static_assert(res != NULL, "res"); \
  const char *aa = a; \
  ASSERT(aa, "a"); \
  const char *bb = b; \
  ASSERT(bb, "b"); \
  size_t len = strlen(aa) + strlen(bb) + 1; \
  char *m = alloca(len); \
  char *p = strcpy_advance(m, aa); \
  strcpy(p, bb); \
  *(res) = m; \
 } while(0)

#define xalloca_concat3(res, a, b, c) do { \
  _Static_assert(res != NULL, "res"); \
  const char *aa = a; \
  ASSERT(aa, "a"); \
  const char *bb = b; \
  ASSERT(bb, "b"); \
  const char *cc = c; \
  ASSERT(cc, "c"); \
  size_t len = strlen(aa) + strlen(bb) + strlen(cc) + 1; \
  char *m = alloca(len); \
  char *p = strcpy_advance(m, aa); \
  p = strcpy_advance(p, bb); \
  strcpy(p, cc); \
  *(res) = m; \
 } while(0)

#define xalloca_end(res) do { /* NOOP */ } while(0);

#else /* defined(alloca) */

#define xalloca_init(res) do { (res) = NULL; } while(0);

#define xalloca_strdup(res, s) do { \
  _Static_assert(res != NULL, "res"); \
  const char *ss = s; \
  ASSERT(ss, "s"); \
  size_t len = strlen(aa) + 1; \
  char *m = malloc(len); \
  strcpy(m, aa); \
  *(res) = m; \
 } while(0)

#define xalloca_strndup(res, s, n) do { \
  _Static_assert(res != NULL, "res"); \
  const char *ss = s; \
  ASSERT(ss, "s"); \
  const size_t nn = n; \
  size_t len = strnlen(aa, nn) + 1; \
  char *m = malloc(len); \
  strncpy_withnul(m, aa, len); \
  *(res) = m; \
 } while(0)

#define xalloca_concat2(res, a, b) do { \
  _Static_assert(res != NULL, "res"); \
  const char *aa = a; \
  ASSERT(aa, "a"); \
  const char *bb = b; \
  ASSERT(bb, "b"); \
  size_t len = strlen(aa) + strlen(bb) + 1; \
  char *m = malloc(len); \
  char *p = strcpy_advance(m, aa); \
  strcpy(p, bb); \
  *(res) = m; \
 } while(0)

#define xalloca_concat3(res, a, b, c) do { \
  _Static_assert(res != NULL, "res"); \
  const char *aa = a; \
  ASSERT(aa, "a"); \
  const char *bb = b; \
  ASSERT(bb, "b"); \
  const char *cc = c; \
  ASSERT(cc, "c"); \
  size_t len = strlen(aa) + strlen(bb) + strlen(cc) + 1; \
  char *m = malloc(len); \
  char *p = strcpy_advance(m, aa); \
  p = strcpy_advance(p, bb); \
  strcpy(p, cc); \
  *(res) = m; \
 } while(0)

#define xalloca_end(res) do { if(res) free(res); } while(0);

#endif /* defined(alloca) */

#endif /* _MAGIC__UTILS__MAGIC_ALLOCA_H */
