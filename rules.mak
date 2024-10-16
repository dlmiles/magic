# You shouldn't need to edit this file, see the defs.mak file

module: lib${MODULE}.o

depend: ${DEPEND_FILE}

# New Depend file generating line (Tim Edwards, 1/25/06).  This gets around
# problems with gcc.  The purpose of "make depend" is to generate a list of
# all local dependencies, but gcc insists that anything that is in, for
# example, the /usr/X11R6 path should also be included.  The sed scripts
# (respectively) do:  1) remove comment lines generated by gcc, 2) remove
# any header (.h) files with an absolute path (beginning with "/"), and
# 3) remove isolated backslash-returns just to clean things up a bit.

# The $$PPID allows this to be run on the same dir in parallel without
# corrupting the output, the final MV is transactional. If that is needed
# it indicates a missing dependency somewhere in a upstream/parent Makefile.
${DEPEND_FILE}: ${DEPSRCS}
	${CC} ${CFLAGS} ${CPPFLAGS} ${DFLAGS} ${DEPEND_FLAG} ${DEPSRCS} > ${DEPEND_FILE}$$PPID.tmp
	${SED} -e "/#/D" -e "/ \//s/ \/.*\.h//" -e "/  \\\/D" -i ${DEPEND_FILE}$$PPID.tmp
	${MV} -f ${DEPEND_FILE}$$PPID.tmp ${DEPEND_FILE}

# Original Depend file generating line:
#	${CC} ${CFLAGS} ${CPPFLAGS} ${DFLAGS} ${DEPEND_FLAG} ${SRCS} > ${DEPEND_FILE}

%.o: %.c
	@echo --- compiling ${MODULE}/$*.o
	${RM} $*.o
	${CC} ${CFLAGS} ${CPPFLAGS} ${DFLAGS}  -c $*.c

lib${MODULE}.o: ${OBJS}
	@echo --- linking lib${MODULE}.o
	${RM} lib${MODULE}.o
	${LINK} ${OBJS} -o lib${MODULE}.o ${EXTERN_LIBS}

lib: lib${MODULE}.a

lib${MODULE}.a: ${OBJS} ${LIB_OBJS}
	@echo --- archiving lib${MODULE}.a
	${RM} lib${MODULE}.a
	${AR} ${ARFLAGS} lib${MODULE}.a ${OBJS} ${LIB_OBJS}
	${RANLIB} lib${MODULE}.a

${MODULE}: lib${MODULE}.o ${EXTRA_LIBS}
	@echo --- building main ${MODULE}
	${RM} ${MODULE}
	${CC} ${CFLAGS} ${CPPFLAGS} ${DFLAGS} lib${MODULE}.o ${EXTRA_LIBS} -o ${MODULE} ${LIBS}

${DESTDIR}${BINDIR}/${MODULE}${EXEEXT}: ${MODULE}${EXEEXT}
	${RM} ${DESTDIR}${BINDIR}/${MODULE}${EXEEXT}
	${CP} ${MODULE}${EXEEXT} ${DESTDIR}${BINDIR}

.PHONY: clean
clean:
	${RM} ${CLEANS}

tags: ${SRCS} ${LIB_SRCS}
	ctags ${SRCS} ${LIB_SRCS}

# Depends are a somewhat optional part of the build process that are only useful when incremental
# building.  If the file is here it's here, if not continue with build optimistically
ifneq (,$(wildcard ${DEPEND_FILE}))
include ${DEPEND_FILE}
endif
