test_failure(x::Int) = sin(helper_string()) + helper_number() + x
@testset "context" begin
    @test helper_number() == twice(1)
end
