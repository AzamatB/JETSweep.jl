test_failure(x::Int) = sin(helper_string()) + helper_number() + x

@testset "dynamic" begin
    @test twice(helper_number()) == 4
end
