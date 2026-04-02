# 
#
#

.PHONY: debug compile sim clear

RUN_DIR := $(shell dirname $(realpath $(lastword $(MAKEFILE_LIST))))
#PRJ_ROOT := ${RUN_DIR}/../..
#DUT_DIR := ${PRJ_ROOT}/design
#DV_DIR := ${PRJ_ROOT}/verify


TESTNAME ?= 
TOOL_VAL ?= xrun 
TOOL_OPTION = -tool xrun 
SIM_VAL ?= cr
GUI_VAL ?= gui 

PRE_RUN_OPTIONS = -test ${TESTNAME} 
PRE_RUN_OPTIONS += -gui gui 

RUN_OPTIONs := run 
RUN_OPTIONs += ${PRE_RUN_OPTIONS} 
RUN_OPTIONs += ${TOOL_OPTION} 

compile: 
	run -sim ro &

sim: 
	./run_test -sim rc -gui gui &
	#./run_test -test ${TESTNAME} -sim rc -gui gui &


clear: 
	rm -rf __pycache__ 
	rm -rf xcelium


debug: 
	@echo "RUN_DIR location: "${RUN_DIR}
	@echo "PRJ_ROOT location: "${PRJ_ROOT}
	@echo "DUT_DIR location: "${DUT_DIR}
	@echo "DV_DIR location: "${DV_DIR}
	@echo "PRE_RUN_OPTIONS : "${PRE_RUN_OPTIONS}
	@echo "TOOL_OPTION : "${TOOL_OPTION}
	@echo "RUN_OPTIONs : "${RUN_OPTIONs}

