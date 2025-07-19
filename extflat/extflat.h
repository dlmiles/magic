/*
 * extflat.h --
 *
 * Internal definitions for the procedures to flatten hierarchical
 * (.ext) circuit extraction files.
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
 * rcsid $Header: /usr/cvsroot/magic-8.0/extflat/extflat.h,v 1.2 2008/12/03 14:12:09 tim Exp $
 */

#ifndef _EXTFLAT_H
#define _EXTFLAT_H

#include "utils/magic.h"

#include "extflat/EFtypes.h" /* EFCapValue, HierName, EFPerimArea, EFNode */
#include "extflat/EFint.h" /* Def, HierContext, Connection, Distance, CallArg */


extern float EFScale;		/* Scale factor to multiply all coords by */
extern char *EFTech;		/* Technology of extracted circuit */
extern char *EFStyle;           /* Extraction style of extracted circuit */
extern char *EFSearchPath;	/* Path to search for .ext files */
extern char *EFLibPath;		/* Library search path */
extern char *EFVersion;		/* Version of extractor we work with */
extern char *EFArgTech;		/* Tech file given as command line argument */
extern bool  EFCompat;		/* Subtrate backwards-compatibility mode */

    /*
     * Thresholds used by various extflat clients to filter out
     * unwanted resistors and capacitors.  Resistance is in milliohms,
     * capacitance in attofarads.
     */
extern int EFResistThreshold;
extern EFCapValue EFCapThreshold;

    /* Table of transistor types */
extern char *EFDevTypes[];
extern int EFDevNumTypes;

    /* Table of Magic layers */
extern char *EFLayerNames[];
extern int EFLayerNumNames;

    /* Output control flags */
extern int EFOutputFlags;

    /* Behavior regarding disjoint node segments */
extern bool EFSaveLocs;

/* -------------------------- Exported procedures --------------------- */

typedef bool (*cb_extflat_args_t)(int *pargc, char ***pargv, ClientData cdata);
extern char *EFArgs(int argc, char *argv[], bool *err_result, const cb_extflat_args_t argsProc, ClientData cdata);

    /* HierName manipulation */
extern HashEntry *EFHNLook(HierName *prefix, char *suffixStr, char *errorStr);
extern HashEntry *EFHNConcatLook(HierName *prefix, HierName *suffix, char *errorStr);
extern HierName *EFHNConcat(HierName *prefix, HierName *suffix);
extern HierName *EFStrToHN(HierName *prefix, char *suffixStr);
extern char *EFHNToStr(HierName *hierName);
extern int EFGetPortMax(Def *def);

/* C99 compat */
extern void EFHNFree(HierName *hierName, HierName *prefix, int type);
extern bool EFHNIsGlob(HierName *hierName);
extern int EFNodeResist(EFNode *node);
extern void efAdjustSubCap(Def *def, char *nodeName, double nodeCapAdjust);
extern int efBuildAddStr(char *table[], int *pMax, int size, char *str);
extern void efBuildAttr(Def *def, char *nodeName, Rect *r, char *layerName, char *text);
extern int efBuildDevice(Def *def, char class, char *type, Rect *r, int argc, char *argv[]);
extern void efBuildDeviceParams(char *name, int argc, char *argv[]);
extern void efBuildDist(Def *def, char *driver, char *receiver, int min, int max);
extern void efBuildEquiv(Def *def, char *nodeName1, char *nodeName2, bool resist, bool isspice);
extern void efBuildKill(Def *def, char *name);
extern void efBuildPortNode(Def *def, char *name, int idx, int x, int y, char *layername, bool toplevel);
extern void efBuildUse(Def *def, char *subDefName, char *subUseId,
                       int ta, int tb, int tc, int td, int te, int tf);
extern int efFlatCaps(HierContext *hc);
extern int efFlatDists(HierContext *hc);
extern int efFlatKills(HierContext *hc);
extern int efFlatNodes(HierContext *hc, ClientData clientData);
extern int efFlatNodesStdCell(HierContext *hc);
extern void efFreeConn(Connection *conn);
extern void efFreeDevTable(HashTable *table);
typedef int (*cb_extflat_free_t)(ClientData cdata);
extern void efFreeNodeList(EFNode *head, const cb_extflat_free_t func);
extern void efFreeNodeTable(HashTable *table);
extern void efFreeUseTable(HashTable *table);
extern void efHNBuildDistKey(HierName *prefix, Distance *dist, Distance *distKey);
extern int efHNLexOrder(HierName *hierName1, HierName *hierName2);
extern void efHNPrintSizes(char *when);
extern void efHNRecord(int size, int type);
typedef int (*cb_extflat_hiersrarray_t)(HierContext *hc, const char *name1, const char *name2, Connection *conn, ClientData cdata);
extern int efHierSrArray(HierContext *hc, Connection *conn, const cb_extflat_hiersrarray_t proc, ClientData cdata);
extern int efHierSrUses(HierContext *hc, int (*func)(), ClientData cdata);
extern int efHierVisitDevs(HierContext *hc, CallArg *ca);
extern EFNode *efNodeMerge(EFNode **node1ptr, EFNode **node2ptr);
extern void efReadError(const char *fmt, ...) ATTR_FORMAT_PRINTF_1;
extern int efReadLine(char **lineptr, int *sizeptr, FILE *file, char *argv[]);
extern bool efSymAdd(char *str);
extern bool efSymAddFile(char *name);
extern void efSymInit(void);
extern void EFDone(const cb_extflat_free_t func);
extern void EFFlatBuild(char *name, int flags);
extern void EFFlatDone(const cb_extflat_free_t func);
extern bool EFHNIsGND(HierName *hierName);
extern void EFInit(void);
extern bool EFReadFile(char *name, bool dosubckt, bool resist, bool noscale, bool isspice);
extern int EFVisitDevs(int (*devProc)(), ClientData cdata);
extern int efVisitDevs(HierContext *hc, CallArg *ca);
extern bool efSymLook(char *name, int *pValue);
extern int efVisitResists(HierContext *hc, CallArg *ca);
extern int EFVisitResists(int (*resProc)(), ClientData cdata);
typedef int (*cb_extflat_visitnodes_t)(EFNode *node, int res, double cap, ClientData cdata);
extern int EFVisitNodes(const cb_extflat_visitnodes_t nodeProc, ClientData cdata);
extern int EFVisitCaps(int (*capProc)(), ClientData cdata);
extern void EFGetLengthAndWidth(Dev *dev, int *lptr, int *wptr);
extern void EFHNOut(HierName *hierName, FILE *outf);
extern int EFHierSrDefs(HierContext *hc, int (*func)(), ClientData cdata);
extern int EFVisitSubcircuits(int (*subProc)(), ClientData cdata);
extern int EFHierVisitSubcircuits(HierContext *hc, int (*subProc)(), ClientData cdata);
extern int EFHierVisitDevs(HierContext *hc, int (*devProc)(), ClientData cdata);
extern int EFHierVisitResists(HierContext *hc, int (*resProc)(), ClientData cdata);
extern int EFHierVisitCaps(HierContext *hc, int (*capProc)(), ClientData cdata);
extern int EFHierVisitNodes(HierContext *hc, int (*nodeProc)(), ClientData cdata);

#endif /* _EXTFLAT_H */
