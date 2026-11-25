# The items that start analysis or preparation workers wait until runtests.jl has precompiled what those workers load,
# the analyzer and JETSweep itself, the way they load it (it makes the file Main.ANALYZER_READY then, whose path every
# worker gets).
@testsetup module Analyzer
timedwait(() -> isfile(Main.ANALYZER_READY), 3000.0; pollint=1.0) === :ok ||
    error("the analyzer's precompile did not finish")
end
