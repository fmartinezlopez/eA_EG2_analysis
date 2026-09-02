// eg2_main.cxx -- standalone entry point.
//
//   make && ./eg2analysis '<glob>' <target> [fsi|prefsi] [maxevents] [datadir] [outdir]
 
#include <TSystem.h>
 
#include <cstdio>
#include <cstdlib>
#include <string>
 
#include "EG2Analysis.C"
 
int main(int argc, char** argv) {
  if (argc < 3) {
    std::fprintf(stderr,
                 "usage: %s '<glob-or-comma-list>' <target> [fsi|prefsi] "
                 "[maxevents] [datadir] [outdir]\n"
                 "  target must match the CSV `target` column: D, C, Fe, Pb\n",
                 argv[0]);
    return 2;
  }
  const char* input = argv[1];
  const char* target = argv[2];
  const char* stage = (argc > 3) ? argv[3] : "fsi";
  const Long64_t nmax = (argc > 4) ? std::atoll(argv[4]) : -1;
  const char* datadir = (argc > 5) ? argv[5] : "../data";
  const char* outdir = (argc > 6) ? argv[6] : "out";
 
  EG2Analysis(input, target, stage, nmax, datadir, outdir);
  return 0;
}