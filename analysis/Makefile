#
#   make          -> ./eg2analysis
#   make clean
#
 
ROOTCFLAGS := $(shell root-config --cflags)
ROOTLIBS   := $(shell root-config --libs)
 
CXX      ?= g++
CXXFLAGS := -std=c++17 -O2 -Wall -Wextra $(ROOTCFLAGS)
HEADERS  := EG2Kinematics.h EG2Selections.h EG2Binning.h EG2Fill.h
 
all: eg2analysis
 
eg2analysis: eg2_main.cxx EG2Analysis.C $(HEADERS)
	$(CXX) $(CXXFLAGS) eg2_main.cxx -o $@ $(ROOTLIBS)
 
clean:
	rm -f eg2analysis *_C.so *_C.d *_C_ACLiC_dict* *.pcm
 
.PHONY: all test clean