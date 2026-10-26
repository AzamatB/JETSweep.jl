# The workers run as the main process does: with --depwarn=error and its bounds checking (Base.julia_cmd forwards
# them), and with the package from the same place. runtests.jl hands each worker the main process's settings.
@testitem "workers: the main process's flags and package" begin
    @test Base.JLOptions().depwarn == 2
    @test Base.JLOptions().depwarn == Main.MAIN_DEPWARN
    @test Base.JLOptions().check_bounds == Main.MAIN_CHECK_BOUNDS
    @test pathof(JETSweep) == Main.MAIN_PATHOF
end
