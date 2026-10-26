# The workers run as the main process does: with --depwarn=error and its bounds checking (Base.julia_cmd forwards
# them), and with the package from the same place, unchecked (JETSweep's suite makes no checked run). runtests.jl hands
# each worker the main process's settings, and its WORKER_CHECKS repeat the flag and package checks after every item,
# in every worker; this item is their record under a name.
@testitem "workers: the main process's flags and package" begin
    @test Base.JLOptions().depwarn == 2
    @test Base.JLOptions().depwarn == Main.MAIN_DEPWARN
    @test Base.JLOptions().check_bounds == 1   # --check-bounds=yes, which Pkg.test passes
    @test Base.JLOptions().check_bounds == Main.MAIN_CHECK_BOUNDS
    @test pathof(JETSweep) == Main.MAIN_PATHOF
    @test get(ENV, "DISPATCH_CHECKUP", "") == Main.MAIN_DISPATCH_CHECKUP
    @test isdefined(JETSweep, Symbol("#DispatchCheckup")) == (Main.MAIN_DISPATCH_CHECKUP == "checked")
end
