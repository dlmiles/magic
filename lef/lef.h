/*
 * lef.h --
 *
 * Contains definitions for things that are exported by the
 * lef module.
 *
 */

#ifndef _MAGIC__LEF__LEF_H
#define _MAGIC__LEF__LEF_H

#include "utils/magic.h"

/* Procedures for reading the technology file: */

extern void LefTechInit();
extern bool LefTechLine();
extern void LefTechScale();
extern void LefTechSetDefaults();

/* Initialization: */

extern void LefInit();

#endif /* _MAGIC__LEF__LEF_H */
